'use strict';

(function publish(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.EmployeeGuidance = api;
}(typeof globalThis === 'object' ? globalThis : this, () => {
  const CURRENT_ONBOARDING_VERSION = 1;
  const labels = Object.freeze({
    unconfigured: Object.freeze([
      '尚未选择部门和姓名',
      '连接公司 NAS 后选择部门和姓名。',
      '开始配置',
    ]),
    disconnected: Object.freeze([
      '未检测到公司 NAS',
      '请先重新连接公司共享盘。',
      '重新检测',
    ]),
    validating: Object.freeze([
      '正在验证备份目录',
      '正在确认目录和写入能力。',
      null,
    ]),
    seeding: Object.freeze([
      '正在进行首次备份',
      '请保持 NAS 连接，暂勿退出软件。',
      null,
    ]),
    verifying: Object.freeze([
      '正在确认 NAS 文件完整',
      '正在从 NAS 回读并校验备份。',
      null,
    ]),
    running: Object.freeze([
      '备份已验证',
      '会话已上传并通过回读校验。',
      null,
    ]),
    pending: Object.freeze([
      '有会话等待补传',
      '请保持 NAS 连接，软件会继续补传。',
      '立即重试',
    ]),
    error: Object.freeze([
      '备份出现异常',
      '请重新检测；仍失败时联系管理员。',
      '重新检测',
    ]),
  });

  function stateGuidance(state) {
    const [title, detail, actionTitle] = labels[state]
      || ['等待中', '等待备份状态。', null];
    return Object.freeze({ title, detail, actionTitle });
  }

  function onboardingDecision({
    setup,
    settings,
    catalogReady = false,
    selectionValid = false,
  }) {
    const configured = Boolean(setup && setup.configured);
    const state = setup?.state || 'unconfigured';
    const version = Number(settings?.onboardingVersion || 0);
    const inProgress = Boolean(settings?.onboardingInProgress);

    if (!configured || state === 'unconfigured') {
      return Object.freeze({
        step: catalogReady ? 2 : 1,
        presentSetup: true,
        preventDismissal: true,
        shouldMarkComplete: false,
        nextInProgress: true,
        canActivate: Boolean(catalogReady && selectionValid),
      });
    }

    if (state === 'running') {
      return Object.freeze({
        step: 3,
        presentSetup: false,
        preventDismissal: false,
        shouldMarkComplete: version < CURRENT_ONBOARDING_VERSION || inProgress,
        nextInProgress: false,
        canActivate: false,
      });
    }

    if (inProgress) {
      return Object.freeze({
        step: state === 'disconnected' ? 1 : 3,
        presentSetup: true,
        preventDismissal: true,
        shouldMarkComplete: false,
        nextInProgress: true,
        canActivate: false,
      });
    }

    return Object.freeze({
      step: state === 'disconnected' ? 1 : 3,
      presentSetup: false,
      preventDismissal: false,
      shouldMarkComplete: false,
      nextInProgress: false,
      canActivate: false,
    });
  }

  const helpTopics = Object.freeze([
    Object.freeze({
      id: 'install',
      title: '安装与首次启动',
      body: '安装后先连接 192.168.10.99 上的“文件中转站”，再在软件中选择部门和姓名，不需要手工选择目录。',
    }),
    Object.freeze({
      id: 'status',
      title: '备份状态说明',
      body: '只有显示“备份已验证”才表示上传和 NAS 回读校验都已完成。',
    }),
    Object.freeze({
      id: 'disconnect',
      title: 'NAS 断开与异常处理',
      body: '先重新连接公司共享盘，再点击“重新检测”。仍失败时保留错误详情并联系管理员。',
    }),
    Object.freeze({
      id: 'recovery',
      title: '会话恢复和更换电脑',
      body: '打开“快照恢复”，选择 NAS 备份设备和缺失会话。恢复前软件会再次完整校验。',
    }),
  ]);

  return Object.freeze({
    CURRENT_ONBOARDING_VERSION,
    onboardingDecision,
    stateGuidance,
    helpTopics,
  });
}));
