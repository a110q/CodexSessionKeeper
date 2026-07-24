import CryptoKit
import Darwin
import Foundation

public enum BackupTargetValidationError: Error, Equatable, Sendable {
    case targetUnavailable(String)
    case unsafeTarget(String)
}

extension BackupTargetValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .targetUnavailable(path):
            return "NAS 备份目录不可用：\(path)"
        case let .unsafeTarget(path):
            return "NAS 备份目录不是可信的真实目录：\(path)"
        }
    }
}

public struct BackupTargetValidator {
    private let validation: () throws -> Void

    public init(backupRoot: URL, fileManager: FileManager = .default) {
        self.validation = {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: backupRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw BackupTargetValidationError.targetUnavailable(backupRoot.path)
            }
            let values = try backupRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw BackupTargetValidationError.unsafeTarget(backupRoot.path)
            }
        }
    }

    public init(_ validation: @escaping () throws -> Void) {
        self.validation = validation
    }

    public func validateTarget() throws {
        try validation()
    }
}

public struct BackupFileStats: Equatable, Sendable {
    public let byteCount: Int64
    public let lineCount: Int

    public init(byteCount: Int64, lineCount: Int) {
        self.byteCount = byteCount
        self.lineCount = lineCount
    }
}

public struct BackupSourceMetadata: Sendable {
    public let byteCount: Int64
    public let modifiedAt: TimeInterval
    public let fileIdentity: String?

    public init(
        byteCount: Int64,
        modifiedAt: TimeInterval,
        fileIdentity: String? = nil
    ) {
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.fileIdentity = fileIdentity
    }
}

public struct BackupTargetState: Sendable {
    public let exists: Bool
    public let byteCount: Int64
}

public enum BackupReconciliation: Equatable, Sendable {
    case new
    case append(readOffset: Int64)
    case rebuild
}

public final class BackupFileCommitter {
    private static let newline = Data([0x0A])
    private static let newlineByte: UInt8 = 0x0A

    private let fileManager: FileManager
    private let synchronize: (FileHandle) throws -> Void

    public init(
        fileManager: FileManager = .default,
        synchronize: @escaping (FileHandle) throws -> Void = { try $0.synchronize() }
    ) {
        self.fileManager = fileManager
        self.synchronize = synchronize
    }

    public func commitInitial(lines: [Data], to target: URL, under backupRoot: URL) throws -> BackupFileStats {
        guard !lines.isEmpty else {
            return BackupFileStats(byteCount: 0, lineCount: 0)
        }
        try ensureParent(of: target, under: backupRoot)
        let payload = serialized(lines)
        try DurableAtomicWriter(fileManager: fileManager, synchronize: synchronize).write(
            payload,
            to: target,
            createParentDirectories: false
        )
        return BackupFileStats(byteCount: Int64(payload.count), lineCount: lines.count)
    }

    public func appendAndSynchronize(
        lines: [Data],
        to target: URL,
        under backupRoot: URL,
        knownTargetByteCount: Int64? = nil
    ) throws -> BackupFileStats {
        let targetState = if let knownTargetByteCount {
            BackupTargetState(exists: true, byteCount: knownTargetByteCount)
        } else {
            try inspectTarget(target)
        }
        guard !lines.isEmpty else {
            return BackupFileStats(byteCount: targetState.byteCount, lineCount: 0)
        }
        try ensureParent(of: target, under: backupRoot)
        guard fileManager.fileExists(atPath: target.path) else {
            return try commitInitial(lines: lines, to: target, under: backupRoot)
        }
        let handle = try FileHandle(forWritingTo: target)
        do {
            try handle.seekToEnd()
            var bufferedWriter = BufferedBackupWriter {
                try handle.write(contentsOf: $0)
            }
            for line in lines {
                try bufferedWriter.append(line)
                try bufferedWriter.append(byte: Self.newlineByte)
            }
            try bufferedWriter.flush()
            try synchronize(handle)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let appendedBytes = lines.reduce(Int64(0)) { $0 + Int64($1.count + 1) }
        return BackupFileStats(
            byteCount: targetState.byteCount + appendedBytes,
            lineCount: lines.count
        )
    }

    public func inspectSource(_ source: URL) throws -> BackupSourceMetadata {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BackupPathsError.unsafeSource(source.path)
        }
        var sourceStat = stat()
        guard lstat(source.path, &sourceStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard sourceStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw BackupPathsError.unsafeSource(source.path)
        }
        return BackupSourceMetadata(
            byteCount: Int64(sourceStat.st_size),
            modifiedAt: TimeInterval(sourceStat.st_mtimespec.tv_sec)
                + TimeInterval(sourceStat.st_mtimespec.tv_nsec) / 1_000_000_000,
            fileIdentity: "\(sourceStat.st_dev):\(sourceStat.st_ino)"
        )
    }

    public func inspectTarget(_ target: URL) throws -> BackupTargetState {
        guard fileManager.fileExists(atPath: target.path) else {
            return BackupTargetState(exists: false, byteCount: 0)
        }
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BackupTargetValidationError.unsafeTarget(target.path)
        }
        return BackupTargetState(exists: true, byteCount: Int64(values.fileSize ?? 0))
    }

    public func rebuildCompleteLines(
        lines: [Data],
        at target: URL,
        under backupRoot: URL
    ) throws -> BackupFileStats {
        try ensureParent(of: target, under: backupRoot)
        let payload = serialized(lines)
        try DurableAtomicWriter(fileManager: fileManager, synchronize: synchronize).write(
            payload,
            to: target,
            createParentDirectories: false
        )
        return BackupFileStats(byteCount: Int64(payload.count), lineCount: lines.count)
    }

    public func rebuildCompleteLines(
        from source: URL,
        through maximumOffset: Int64? = nil,
        at target: URL,
        under backupRoot: URL,
        using streamer: SessionBackupStreamer = SessionBackupStreamer(),
        verifyTemporary: ((URL, StreamedBackupResult) throws -> Void)? = nil
    ) throws -> StreamedBackupResult {
        try ensureParent(of: target, under: backupRoot)
        return try streamer.rebuildCompleteLines(
            source: source,
            through: maximumOffset,
            destination: target,
            atomicWriter: DurableAtomicWriter(
                fileManager: fileManager,
                synchronize: synchronize
            ),
            verifyTemporary: verifyTemporary
        )
    }

    func truncateTarget(
        _ target: URL,
        to byteCount: Int64,
        under backupRoot: URL
    ) throws {
        guard byteCount >= 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        try ensureParent(of: target, under: backupRoot)
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BackupTargetValidationError.unsafeTarget(target.path)
        }
        let handle = try FileHandle(forWritingTo: target)
        do {
            try handle.truncate(atOffset: UInt64(byteCount))
            try synchronize(handle)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    func appendCompleteLines(
        from source: URL,
        offset: Int64,
        to target: URL,
        under backupRoot: URL,
        using streamer: SessionBackupStreamer
    ) throws -> StreamedAppendResult {
        try ensureParent(of: target, under: backupRoot)
        return try streamer.appendCompleteLines(
            source: source,
            from: offset,
            destination: target,
            synchronize: synchronize
        )
    }

    public func stats(at target: URL) throws -> BackupFileStats {
        let targetState = try inspectTarget(target)
        guard targetState.exists else {
            return BackupFileStats(byteCount: 0, lineCount: 0)
        }
        let handle = try FileHandle(forReadingFrom: target)
        defer { try? handle.close() }
        var lineCount = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            lineCount += chunk.reduce(0) { $0 + ($1 == Self.newlineByte ? 1 : 0) }
        }
        return BackupFileStats(
            byteCount: targetState.byteCount,
            lineCount: lineCount
        )
    }

    public func targetIsCompletePrefix(_ target: URL, of source: URL) throws -> Bool {
        let targetStats = try stats(at: target)
        let sourceSize = try fileSize(source)
        guard targetStats.byteCount <= sourceSize else {
            return false
        }
        if targetStats.byteCount > 0 {
            let handle = try FileHandle(forReadingFrom: target)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(targetStats.byteCount - 1))
            guard try handle.read(upToCount: 1)?.first == Self.newlineByte else {
                return false
            }
        }
        return try filesMatchPrefix(lhs: target, rhs: source, byteCount: targetStats.byteCount)
    }

    public func targetMatchesBoundedFingerprint(
        _ target: URL,
        source: URL,
        byteCount: Int64,
        windowBytes: Int = 4_096
    ) throws -> Bool {
        guard byteCount >= 0, windowBytes > 0 else { return byteCount == 0 }
        guard try inspectTarget(target).byteCount == byteCount else { return false }
        guard byteCount > 0 else { return true }

        let targetHandle = try FileHandle(forReadingFrom: target)
        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer {
            try? targetHandle.close()
            try? sourceHandle.close()
        }
        let headCount = Int(min(byteCount, Int64(windowBytes)))
        guard try targetHandle.read(upToCount: headCount) == sourceHandle.read(upToCount: headCount) else {
            return false
        }
        guard byteCount > Int64(headCount) else { return true }
        let tailCount = Int(min(byteCount - Int64(headCount), Int64(windowBytes)))
        let tailOffset = UInt64(byteCount - Int64(tailCount))
        try targetHandle.seek(toOffset: tailOffset)
        try sourceHandle.seek(toOffset: tailOffset)
        return try targetHandle.read(upToCount: tailCount) == sourceHandle.read(upToCount: tailCount)
    }

    public func hashPrefix(of source: URL, byteCount: Int64) throws -> String {
        guard byteCount >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var remaining = byteCount
        var digest = SHA256()
        while remaining > 0 {
            let count = Int(min(remaining, 1_048_576))
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                throw CocoaError(.fileReadTooLarge)
            }
            digest.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func filesMatchPrefix(lhs: URL, rhs: URL, byteCount: Int64) throws -> Bool {
        let lhsHandle = try FileHandle(forReadingFrom: lhs)
        let rhsHandle = try FileHandle(forReadingFrom: rhs)
        defer {
            try? lhsHandle.close()
            try? rhsHandle.close()
        }
        var remaining = byteCount
        while remaining > 0 {
            let count = Int(min(remaining, 1_048_576))
            let lhsData = try lhsHandle.read(upToCount: count) ?? Data()
            let rhsData = try rhsHandle.read(upToCount: count) ?? Data()
            guard lhsData == rhsData, !lhsData.isEmpty else {
                return false
            }
            remaining -= Int64(lhsData.count)
        }
        return true
    }

    private func ensureParent(of target: URL, under backupRoot: URL) throws {
        let root = backupRoot.standardizedFileURL
        let parent = target.deletingLastPathComponent().standardizedFileURL
        let rootComponents = root.pathComponents
        let parentComponents = parent.pathComponents
        guard parentComponents.starts(with: rootComponents) else {
            throw BackupTargetValidationError.unsafeTarget(target.path)
        }

        var current = root
        for component in parentComponents.dropFirst(rootComponents.count) {
            let next = current.appendingPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: next.path, isDirectory: &isDirectory) {
                let values = try next.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
                    throw BackupTargetValidationError.unsafeTarget(next.path)
                }
            } else {
                try fileManager.createDirectory(at: next, withIntermediateDirectories: false)
            }
            let resolvedCurrent = current.resolvingSymlinksInPath().standardizedFileURL
            let resolvedNext = next.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedNext.deletingLastPathComponent() == resolvedCurrent else {
                throw BackupTargetValidationError.unsafeTarget(next.path)
            }
            current = next
        }
    }

    private func serialized(_ lines: [Data]) -> Data {
        var data = Data()
        for line in lines {
            data.append(line)
            data.append(Self.newline)
        }
        return data
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
