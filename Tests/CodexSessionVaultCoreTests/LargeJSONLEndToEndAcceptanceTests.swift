import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct LargeJSONLEndToEndAcceptanceTests {
    @Test
    func legitimateLargeCompactedLineRepairsAndRecoversByteForByte() throws {
        guard ProcessInfo.processInfo.environment["CODEX_RUN_LARGE_JSONL_ACCEPTANCE"] == "1" else {
            return
        }

        try LargeJSONLAcceptanceSupport.runSynthetic()
    }

    @Test
    func knownSourceVerifiedPrefixResumesWithoutMutation() throws {
        guard ProcessInfo.processInfo.environment["CODEX_RUN_REAL_LARGE_JSONL_ACCEPTANCE"] == "1" else {
            return
        }
        let sourcePath = try #require(ProcessInfo.processInfo.environment["CODEX_REAL_LARGE_JSONL_SOURCE"])
        try LargeJSONLAcceptanceSupport.runReal(source: URL(fileURLWithPath: sourcePath))
    }
}

private enum LargeJSONLAcceptanceSupport {
    static let compactedLineBytes = 35_895_162
    static let legacyLineBytes = 32 * 1_024 * 1_024
    static let sessionID = "019f5e8c-20de-71b2-bcef-ab79b0f36351"
    static let resultMarker = "LARGE_JSONL_ACCEPTANCE_RESULT="
    static let verifiedPrefixBytes: Int64 = 188_399_559
    static let expectedRealBytes: Int64 = 319_942_731
    static let nextRecordOffset: Int64 = 224_294_722

    static func runSynthetic() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("large-jsonl-swift-\(UUID().uuidString)", isDirectory: true)
        defer {
            if ProcessInfo.processInfo.environment["CODEX_LARGE_JSONL_KEEP_ROOT"] != "1" {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let source = root.appendingPathComponent(
            ".codex/sessions/2026/07/18/rollout-2026-07-18T00-00-00-\(sessionID).jsonl"
        )
        let following = Data(#"{"timestamp":"2026-07-18T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"following-record-retained"}]}}"#.utf8) + Data([0x0A])
        try writeFixture(to: source, following: following)

        let paths = BackupPaths(
            homeDirectory: root,
            codexRoot: root.appendingPathComponent(".codex", isDirectory: true),
            backupRoot: root.appendingPathComponent("backup", isDirectory: true),
            stateRoot: root.appendingPathComponent("state", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: paths.backupRoot, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_784_332_800)
        let legacyAgent = BackupAgent(
            paths: paths,
            now: { now },
            sessionBackupStreamer: SessionBackupStreamer(maxLineBytes: legacyLineBytes),
            cursorStoreFactory: { BackupCursorStore(databaseURL: $0) },
            manifestStoreFactory: { BackupManifestStore(manifestURL: $0, createParentDirectories: false) },
            instrumentation: BackupAgentInstrumentation()
        )
        try legacyAgent.performOneShotScan()

        let cursorStore = BackupCursorStore(databaseURL: paths.cursorDatabaseURL)
        try cursorStore.open()
        let blocked = try require(try cursorStore.cursor(sourcePath: source.path), "legacy cursor missing")
        try require(blocked.lastByteOffset == 0, "legacy scan unexpectedly committed bytes")
        try require(blocked.blockedLineLimitBytes == legacyLineBytes, "legacy line block was not persisted")
        try require(blocked.lastError?.contains("at offset 0") == true, "legacy line block offset missing")

        try BackupAgent(paths: paths, now: { now.addingTimeInterval(1) }).performOneShotScan()

        let manifest = try BackupManifestStore(manifestURL: paths.manifestURL).loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path
        )
        let record = try require(manifest.sessions[sessionID], "repaired manifest record missing")
        let backup = paths.backupRoot.appendingPathComponent(record.backupPath)
        let sourceVerified = try BackupFileVerifier().verifyFull(source)
        let verification = try BackupVerificationStore(fileURL: paths.verificationURL).load()
        let sidecar = try require(verification.sessions[sessionID], "verification sidecar missing")
        let backupVerified = try BackupFileVerifier().verifyFull(
            backup,
            expectedByteCount: sourceVerified.byteCount,
            expectedLineCount: 2,
            expectedContentHash: sourceVerified.contentHash,
            expectedChunkHashes: sourceVerified.chunkHashes
        )
        try require(sourceVerified == backupVerified, "backup verification differs from source")
        try require(try filesEqual(source, backup), "backup differs byte-for-byte from source")
        try require(try tail(of: backup, count: following.count) == following, "following record was not retained")
        try require(sidecar.byteCount == sourceVerified.byteCount, "sidecar byte count mismatch")
        try require(sidecar.lineCount == 2, "sidecar line count mismatch")
        try require(sidecar.chunkHashes == sourceVerified.chunkHashes, "sidecar chunk hashes mismatch")
        try require(record.bytesBackedUp == sourceVerified.byteCount, "manifest byte count mismatch")
        try require(record.lineCount == 2, "manifest line count mismatch")
        try require(sidecar.backupPath == record.backupPath, "manifest and sidecar backup paths differ")

        let repaired = try require(try cursorStore.cursor(sourcePath: source.path), "repaired cursor missing")
        try require(repaired.lastByteOffset == sourceVerified.byteCount, "repaired cursor offset mismatch")
        try require(repaired.blockedLineLimitBytes == nil, "repaired cursor retained blocked limit")
        try require(repaired.lastError == nil, "repaired cursor retained error")

        let recoveryRoot = root.appendingPathComponent("recovered-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let restorer = IncrementalRecoveryRestorer(paths: paths)
        let plan = try restorer.preflight(sessionIDs: [sessionID], currentSessionIDs: [])
        let restored = try restorer.restore(plan, to: recoveryRoot)
        try require(restored.restoredSessionIDs == [sessionID], "incremental recovery did not restore session")
        let recovered = recoveryRoot.appendingPathComponent("sessions/recovered/\(sessionID).jsonl")
        let recoveredVerified = try BackupFileVerifier().verifyFull(
            recovered,
            expectedByteCount: sourceVerified.byteCount,
            expectedLineCount: 2,
            expectedContentHash: sourceVerified.contentHash,
            expectedChunkHashes: sourceVerified.chunkHashes
        )
        try require(recoveredVerified == sourceVerified, "recovered verification differs from source")
        try require(try filesEqual(source, recovered), "recovered file differs byte-for-byte")
        try require(try tail(of: recovered, count: following.count) == following, "recovered following record missing")

        let report: [String: Any] = [
            "platform": "swift",
            "mode": "synthetic",
            "root": root.path,
            "lineBytes": compactedLineBytes,
            "byteCount": sourceVerified.byteCount,
            "lineCount": sourceVerified.lineCount,
            "sha256": sourceVerified.contentHash,
            "chunkCount": sourceVerified.chunkHashes.count,
            "blockedLimitBytes": legacyLineBytes,
            "repairedCursorOffset": repaired.lastByteOffset
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(resultMarker + String(decoding: data, as: UTF8.self))
    }

    static func runReal(source: URL) throws {
        let originalBefore = try fileMetadata(source)
        try require(originalBefore.size == expectedRealBytes, "known source size changed")
        try require(try byte(at: verifiedPrefixBytes - 1, in: source) == 0x0A, "verified prefix is not a line boundary")
        try require(try byte(at: nextRecordOffset - 1, in: source) == 0x0A, "known large line is not newline terminated")
        try require(nextRecordOffset - verifiedPrefixBytes - 1 == Int64(compactedLineBytes), "known large line length mismatch")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("large-jsonl-real-swift-\(UUID().uuidString)", isDirectory: true)
        defer {
            if ProcessInfo.processInfo.environment["CODEX_LARGE_JSONL_KEEP_ROOT"] != "1" {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let isolatedSource = root.appendingPathComponent(
            ".codex/sessions/2026/07/14/rollout-2026-07-14T10-54-29-\(sessionID).jsonl"
        )
        try FileManager.default.createDirectory(
            at: isolatedSource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: isolatedSource.path, contents: nil) else {
            throw AcceptanceError.failed("unable to create isolated real-source fixture")
        }
        try copyRange(from: source, to: isolatedSource, offset: 0, count: verifiedPrefixBytes, append: false)

        let paths = BackupPaths(
            homeDirectory: root,
            codexRoot: root.appendingPathComponent(".codex", isDirectory: true),
            backupRoot: root.appendingPathComponent("backup", isDirectory: true),
            stateRoot: root.appendingPathComponent("state", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: paths.backupRoot, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_784_332_800)
        try BackupAgent(paths: paths, now: { now }).performOneShotScan()
        let cursorStore = BackupCursorStore(databaseURL: paths.cursorDatabaseURL)
        try cursorStore.open()
        let seeded = try require(try cursorStore.cursor(sourcePath: isolatedSource.path), "seeded prefix cursor missing")
        try require(seeded.lastByteOffset == verifiedPrefixBytes, "verified prefix cursor mismatch")
        let seededVerification = try BackupVerificationStore(fileURL: paths.verificationURL).load()
        let seededSidecar = try require(seededVerification.sessions[sessionID], "seeded prefix verification missing")
        try require(seededSidecar.byteCount == verifiedPrefixBytes, "seeded sidecar prefix mismatch")

        try copyRange(
            from: source,
            to: isolatedSource,
            offset: verifiedPrefixBytes,
            count: expectedRealBytes - verifiedPrefixBytes,
            append: true
        )
        try legacyAgent(paths: paths, now: now.addingTimeInterval(1)).performOneShotScan()
        let blocked = try require(try cursorStore.cursor(sourcePath: isolatedSource.path), "real-source blocked cursor missing")
        try require(blocked.lastByteOffset == verifiedPrefixBytes, "real-source block advanced prefix")
        try require(blocked.blockedLineLimitBytes == legacyLineBytes, "real-source legacy block missing")
        try require(blocked.lastError?.contains("at offset \(verifiedPrefixBytes)") == true, "real-source block offset mismatch")

        try BackupAgent(paths: paths, now: { now.addingTimeInterval(2) }).performOneShotScan()
        let repaired = try require(try cursorStore.cursor(sourcePath: isolatedSource.path), "real-source repaired cursor missing")
        try require(repaired.lastByteOffset == expectedRealBytes, "real-source repaired cursor offset mismatch")
        try require(repaired.blockedLineLimitBytes == nil, "real-source repaired cursor retained limit")
        try require(repaired.lastError == nil, "real-source repaired cursor retained error")

        let manifest = try BackupManifestStore(manifestURL: paths.manifestURL).loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path
        )
        let record = try require(manifest.sessions[sessionID], "real-source repaired manifest missing")
        let backup = paths.backupRoot.appendingPathComponent(record.backupPath)
        let sourceVerified = try BackupFileVerifier().verifyFull(source)
        let backupVerified = try BackupFileVerifier().verifyFull(
            backup,
            expectedByteCount: sourceVerified.byteCount,
            expectedLineCount: sourceVerified.lineCount,
            expectedContentHash: sourceVerified.contentHash,
            expectedChunkHashes: sourceVerified.chunkHashes
        )
        try require(backupVerified == sourceVerified, "real-source backup verification mismatch")
        try require(try filesEqual(source, isolatedSource), "isolated source copy mismatch")
        try require(try filesEqual(source, backup), "real-source backup differs byte-for-byte")
        let verification = try BackupVerificationStore(fileURL: paths.verificationURL).load()
        let sidecar = try require(verification.sessions[sessionID], "real-source sidecar missing")
        try require(sidecar.byteCount == sourceVerified.byteCount, "real-source sidecar bytes mismatch")
        try require(sidecar.lineCount == sourceVerified.lineCount, "real-source sidecar lines mismatch")
        try require(sidecar.chunkHashes == sourceVerified.chunkHashes, "real-source sidecar chunks mismatch")
        try require(record.bytesBackedUp == sourceVerified.byteCount, "real-source manifest bytes mismatch")
        try require(record.lineCount == sourceVerified.lineCount, "real-source manifest lines mismatch")

        let recoveryRoot = root.appendingPathComponent("recovered-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let restorer = IncrementalRecoveryRestorer(paths: paths)
        let plan = try restorer.preflight(sessionIDs: [sessionID], currentSessionIDs: [])
        let result = try restorer.restore(plan, to: recoveryRoot)
        try require(result.restoredSessionIDs == [sessionID], "real-source incremental recovery missing")
        let recovered = recoveryRoot.appendingPathComponent("sessions/recovered/\(sessionID).jsonl")
        let recoveredVerified = try BackupFileVerifier().verifyFull(
            recovered,
            expectedByteCount: sourceVerified.byteCount,
            expectedLineCount: sourceVerified.lineCount,
            expectedContentHash: sourceVerified.contentHash,
            expectedChunkHashes: sourceVerified.chunkHashes
        )
        try require(recoveredVerified == sourceVerified, "real-source recovery verification mismatch")
        try require(try filesEqual(source, recovered), "real-source recovery differs byte-for-byte")

        let originalAfter = try fileMetadata(source)
        try require(originalAfter == originalBefore, "known source metadata changed")
        let report: [String: Any] = [
            "platform": "swift",
            "mode": "real-source",
            "root": root.path,
            "sourcePath": source.path,
            "sourceBytes": sourceVerified.byteCount,
            "verifiedPrefixBytes": verifiedPrefixBytes,
            "largeLineBytes": compactedLineBytes,
            "nextRecordOffset": nextRecordOffset,
            "lineCount": sourceVerified.lineCount,
            "sha256": sourceVerified.contentHash,
            "chunkCount": sourceVerified.chunkHashes.count,
            "blockedLimitBytes": legacyLineBytes,
            "repairedCursorOffset": repaired.lastByteOffset,
            "sourceMetadataUnchanged": true
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(resultMarker + String(decoding: data, as: UTF8.self))
    }

    private static func legacyAgent(paths: BackupPaths, now: Date) -> BackupAgent {
        BackupAgent(
            paths: paths,
            now: { now },
            sessionBackupStreamer: SessionBackupStreamer(maxLineBytes: legacyLineBytes),
            cursorStoreFactory: { BackupCursorStore(databaseURL: $0) },
            manifestStoreFactory: { BackupManifestStore(manifestURL: $0, createParentDirectories: false) },
            instrumentation: BackupAgentInstrumentation()
        )
    }

    private static func writeFixture(to url: URL, following: Data) throws {
        let prefix = Data(#"{"timestamp":"2026-07-18T00:00:00Z","type":"compacted","payload":{"message":""#.utf8)
        let suffix = Data(#""}}"#.utf8)
        let fillCount = compactedLineBytes - prefix.count - suffix.count
        try require(fillCount > 0, "invalid compacted line layout")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AcceptanceError.failed("unable to create fixture")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: prefix)
        let chunk = Data(repeating: 0x78, count: 1_024 * 1_024)
        var remaining = fillCount
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            try handle.write(contentsOf: count == chunk.count ? chunk : chunk.prefix(count))
            remaining -= count
        }
        try handle.write(contentsOf: suffix)
        try handle.write(contentsOf: Data([0x0A]))
        try handle.write(contentsOf: following)
        try handle.synchronize()
    }

    private static func copyRange(
        from source: URL,
        to destination: URL,
        offset: Int64,
        count: Int64,
        append: Bool
    ) throws {
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        try input.seek(toOffset: UInt64(offset))
        if append { _ = try output.seekToEnd() } else { try output.seek(toOffset: 0) }
        var remaining = count
        while remaining > 0 {
            let chunk = try input.read(upToCount: Int(min(4 * 1_024 * 1_024, remaining))) ?? Data()
            try require(!chunk.isEmpty, "known source ended during isolated copy")
            try output.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
        try output.synchronize()
    }

    private static func byte(at offset: Int64, in source: URL) throws -> UInt8 {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try require(try handle.read(upToCount: 1)?.first, "known source byte missing")
    }

    private static func fileMetadata(_ url: URL) throws -> SourceMetadata {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return SourceMetadata(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? -1,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            modifiedAt: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        )
    }

    private static func filesEqual(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let left = try FileHandle(forReadingFrom: lhs)
        let right = try FileHandle(forReadingFrom: rhs)
        defer { try? left.close(); try? right.close() }
        while true {
            let leftChunk = try left.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            let rightChunk = try right.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if leftChunk != rightChunk { return false }
            if leftChunk.isEmpty { return true }
        }
    }

    private static func tail(of url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size - UInt64(count))
        return try handle.readToEnd() ?? Data()
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw AcceptanceError.failed(message) }
        return value
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw AcceptanceError.failed(message) }
    }
}

private struct SourceMetadata: Equatable {
    let size: Int64
    let inode: UInt64
    let modifiedAt: TimeInterval
}

private enum AcceptanceError: Error {
    case failed(String)
}
