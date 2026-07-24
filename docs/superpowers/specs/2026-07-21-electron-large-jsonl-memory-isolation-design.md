# Electron 大 JSONL 内存隔离设计

## 背景与证据

最新版 Swift/macOS 备份链路已经通过真实 319,942,731 字节会话的三阶段验收，但 Electron 路径仍不满足常驻内存门槛。隔离验收中，Electron 修复阶段的峰值 `total footprint` 约为 597 MiB；完成 60 秒后仍约为 249 MiB，相比约 15 MiB 的启动基线增长约 234 MiB。

诊断显示，大记录完成后 JS 实际 `heapUsed` 已回落到约 6 MiB，但主进程 V8 堆曾因 35,895,162 字节记录的 `JSON.parse` 扩展到约 140 MiB，并保留已提交页面。显式 GC 可以将仍登记的 ArrayBuffer 从约 46 MiB 降到几十 KiB，却不能可靠收缩主进程已经扩展的 V8 堆。强制 GC 因此既不是确定性释放机制，也不是可接受的产品修复。

macOS `footprint` 的 `Swapped` 是 `total footprint` 的子集，不能再次与总量相加。验收采用以下口径：

- 峰值 `total footprint` 小于 600 MiB；
- 完成 60 秒后 `total footprint` 相对启动基线的净增长不超过 16 MiB；
- Swap 单独记录用于诊断，不重复计入总量；
- 任一进程树达到 1 GiB 时立即终止验收。

## 目标

1. 大 JSONL 记录不得扩张长期运行的 Electron 主进程 V8 堆。
2. 主进程备份扫描、复制和哈希过程保持固定上限内存，不缓存完整大记录。
3. 继续执行完整 JSON、UTF-8、行长度、SHA-256、分块哈希和行数校验。
4. 保持 NAS 目录、manifest、cursor、verification、IPC、UI 和恢复流程不变。
5. 验证失败继续 fail-closed：旧正式备份和元数据保持不变。

## 方案比较

### 方案 A：两遍流式主链路 + 短生命周期 Worker（采用）

主进程先以固定缓冲扫描完整行边界，再以固定缓冲复制已确认的完整字节范围。超过阈值的文件或变更范围交给 Worker 完成 JSON 校验；Worker 返回小型摘要后退出，由操作系统确定性回收其 V8 堆。

优点是内存边界明确，不依赖 GC，不改变数据格式。代价是大文件多一次本地顺序读取，并增加一个小型 Worker 协议。

### 方案 B：每个大会话启动独立子进程

隔离最彻底，但 Electron 打包环境下需要处理 `ELECTRON_RUN_AS_NODE`、进程路径、退出和信号转发，Windows 安装包兼容面更大，启动成本也高于 Worker。

### 方案 C：备份后主动触发 V8 GC

改动最少，但需要暴露 GC，且诊断已经证明 GC 不能保证收缩已扩展的堆页面，因此不采用。

## 架构

### 1. 主进程两遍流式备份

`session-backup-streamer.js` 将当前“缓存完整记录后写入”改为两个顺序阶段：

1. 边界扫描：使用不超过 1 MiB 的读取缓冲，只记录当前行长度、已提交字节数、行数、阻塞错误和最多 64 KiB 的 partial line。标题仅在现有 64 KiB 单条、256 KiB 总量、256 条记录范围内缓存并解析。
2. 范围复制：再次打开本机源文件，只复制第一阶段确认的完整字节范围；继续使用现有 1 MiB 写缓冲，并在这一遍计算内容 SHA-256。

大记录在第一遍只增加整数计数，不进入主进程的连续大 Buffer。第二遍按块复制，因此单条 35.9 MiB 或接近 64 MiB 的记录不会整体进入内存。

重建仍写同目录临时文件，通过回读验证后原子发布。增量追加先完成边界扫描，再写入确认范围；写入、同步、源文件复核或验证失败时，仍截断回旧 cursor offset。尾部不完整记录不复制、不推进 cursor，语义保持不变。

### 2. 大文件验证 Worker

新增无 Electron API 依赖的验证 Worker。主进程公开接口保持原样：

- `verifyFullBackupFile(...)`
- `verifyChangedBackupChunks(...)`

当完整文件或本次待验证范围大于等于 8 MiB 时，公开函数在 Worker 中调用对应的 in-process 实现。小于 8 MiB 的工作继续在主进程执行，避免数百个小会话反复创建 Worker。

Worker 只获得只读路径、数值边界和预期摘要，不执行写入。返回值仅包含字节数、行数、全文哈希和分块哈希。成功、验证失败、I/O 错误和父任务取消后都必须关闭并等待 Worker 退出；Worker 异常统一映射回现有 `BackupFileVerificationError` 语义。

Worker 内继续使用现有 64 MiB 单行上限和完整 `JSON.parse`。其堆可以为合法大记录临时扩展，但 Worker 退出后由操作系统回收，不进入常驻主进程基线。

### 3. 恢复链路

恢复前预检和 staging 后复核继续调用 `verifyFullBackupFile(...)`，因此大 NAS 文件也自动使用隔离 Worker。文件复制本身继续使用固定块流式复制。任一 Worker 校验失败时，不创建或发布恢复文件，不修改索引。

### 4. 生命周期与并发

- 每次验证最多创建一个 Worker；当前 BackupAgent 逐会话处理，因此不会因首次备份同时创建数百个 Worker。
- Worker 不复用，避免上一个大记录扩展的堆进入下一轮常驻状态。
- BackupAgent 为每次扫描创建内部 `AbortController`；`stop()` 中止当前扫描。验证函数接收可选 `signal`，中止时终止当前 Worker，Promise 只在 Worker 完全退出后结束。现有不传 `signal` 的调用保持兼容。
- 1 GiB 保护覆盖父进程及其 Worker 线程所在进程的总 footprint；达到门槛立即终止隔离验收。

## 内部接口

- `scanCompleteRecordBoundaries(options)` 返回冻结的完整字节数、行数、partial line、阻塞错误和标题，不返回完整记录内容。
- `copyCompleteByteRange(options)` 以固定缓冲复制已确认范围，并返回内容 SHA-256。
- `verifyFullBackupFile(options)` 与 `verifyChangedBackupChunks(options)` 增加可选 `signal`，现有返回结构不变。
- `runIsolatedBackupVerification({ operation, payload, signal })` 负责 Worker 创建、消息校验、错误映射和确定性退出。
- Worker 协议只允许固定的 `verifyFull`、`verifyChangedChunks` 操作；未知操作和非预期返回结构一律失败。
- 不新增 renderer/preload 接口，不修改 Electron IPC。

## 错误与数据一致性

- 边界扫描发现超过 64 MiB、文件读取异常或源文件变化时，不执行发布。
- Worker 返回非法 JSON、非法 UTF-8、行数、长度或哈希不一致时，沿用现有一次自动重试；第二次失败保留旧正式 NAS 文件、manifest、cursor 和 verification。
- Worker 启动、消息协议或异常退出均视为验证失败，不回退到主进程解析大文件。
- 增量追加失败继续截断到旧偏移；重建失败只删除临时文件。
- 不加入“忽略校验继续”或强制 GC 降级路径。

## 测试与验收

### 自动化测试

1. 边界扫描覆盖空文件、跨块记录、35,895,162 字节合法记录、64 MiB 边界、超限行和不完整尾行。
2. 物理写入保持最多 1 MiB，输出字节、行数和 SHA-256 与旧语义一致。
3. 8 MiB 阈值两侧分别验证主进程和 Worker 路径。
4. Worker 成功、非法 JSON、I/O 错误、异常退出和取消均释放 Worker，且无部分元数据推进。
5. 完整恢复与增量恢复对大记录保持逐字节一致。
6. 执行完整 `npm test`、JavaScript 语法检查、Swift 测试和 release build。

### 真实文件门槛

使用只读真实源文件，在全新临时根目录中分别启动 prepare、repair、recover 进程：

- 文件大小 319,942,731 字节；
- 11,482 行；
- 77 个 4 MiB 分块；
- SHA-256 为 `bc67fc120c874639aaa96759e6680b3afbac4cc04bce87618a13c547d78501a7`；
- 源文件 inode、大小和 mtime 全程不变；
- repair 与 Electron 常驻 recover 均观察完成后 60 秒；
- 峰值小于 600 MiB，60 秒后 footprint 净增长不超过 16 MiB，1 GiB 自动终止。

macOS 上的 Electron 代码路径通过后，还必须在 Windows 10 实机按总工作集口径复测；macOS 结果不能替代 Windows 实机结论。

## 非目标

- 不修改 Swift/macOS 生产备份实现。
- 不调整 30 秒扫描、每日审计、NAS 路径或首次配置流程。
- 不修改 UI、IPC、manifest、cursor、verification 或恢复结果格式。
- 不引入第三方 JSON 解析依赖，不发布未通过真实文件门槛的安装包。
