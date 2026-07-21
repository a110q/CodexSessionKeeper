import CryptoKit
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
        let rootPath = try #require(ProcessInfo.processInfo.environment["CODEX_REAL_LARGE_JSONL_ROOT"])
        let phase = try LargeJSONLAcceptanceSupport.validatedRealSourcePhase(
            ProcessInfo.processInfo.environment["CODEX_REAL_LARGE_JSONL_PHASE"]
        )
        try LargeJSONLAcceptanceSupport.runReal(
            source: URL(fileURLWithPath: sourcePath),
            root: URL(fileURLWithPath: rootPath, isDirectory: true),
            phase: phase
        )
    }

    @Test
    func boundedNinetySixMiBLifecycleStaysFileSizeIndependent() throws {
        guard ProcessInfo.processInfo.environment["CODEX_RUN_LARGE_JSONL_LIFECYCLE"] == "1" else {
            return
        }
        try LargeJSONLAcceptanceSupport.runBoundedLifecycle()
    }

    @Test
    func lifecycleFixtureSizeDefaultsAndAcceptsDocumentedRange() throws {
        #expect(try LargeJSONLAcceptanceSupport.validatedLifecycleTotalMiB(nil) == 96)
        #expect(try LargeJSONLAcceptanceSupport.validatedLifecycleTotalMiB("36") == 36)
        #expect(try LargeJSONLAcceptanceSupport.validatedLifecycleTotalMiB("128") == 128)
    }

    @Test(arguments: ["", "not-a-number", "35", "129", "999999999999999999999999"])
    func lifecycleFixtureSizeRejectsInvalidOrUnsafeValues(_ value: String) {
        #expect(throws: (any Error).self) {
            try LargeJSONLAcceptanceSupport.validatedLifecycleTotalMiB(value)
        }
    }

    @Test(arguments: ["prepare", "repair", "recover"])
    func realSourcePhaseAcceptsOnlyDocumentedStages(_ value: String) throws {
        #expect(try LargeJSONLAcceptanceSupport.validatedRealSourcePhase(value).rawValue == value)
    }

    @Test(arguments: [nil, "", "combined", "PREPARE"] as [String?])
    func realSourcePhaseRejectsMissingOrUnknownStages(_ value: String?) {
        #expect(throws: (any Error).self) {
            try LargeJSONLAcceptanceSupport.validatedRealSourcePhase(value)
        }
    }

    @Test
    func settlementDurationDefaultsToSixtySecondsAndRejectsUnsafeValues() throws {
        #expect(try LargeJSONLAcceptanceSupport.validatedSettlementSeconds(nil) == 60)
        #expect(try LargeJSONLAcceptanceSupport.validatedSettlementSeconds("60") == 60)
        #expect(throws: (any Error).self) {
            try LargeJSONLAcceptanceSupport.validatedSettlementSeconds("0")
        }
        #expect(throws: (any Error).self) {
            try LargeJSONLAcceptanceSupport.validatedSettlementSeconds("121")
        }
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
    static let expectedRealLineCount = 11_482
    static let expectedRealChunkCount = 77
    static let expectedRealSHA256 = "bc67fc120c874639aaa96759e6680b3afbac4cc04bce87618a13c547d78501a7"
    static let minimumLifecycleTotalMiB = 36
    static let maximumLifecycleTotalMiB = 128

    static func validatedRealSourcePhase(_ rawValue: String?) throws -> RealSourcePhase {
        guard let rawValue, let phase = RealSourcePhase(rawValue: rawValue) else {
            throw AcceptanceError.failed("real-source acceptance phase must be prepare, repair, or recover")
        }
        return phase
    }

    static func validatedSettlementSeconds(_ rawValue: String?) throws -> Int {
        guard let rawValue else { return 60 }
        guard let value = Int(rawValue), (1...120).contains(value) else {
            throw AcceptanceError.failed("settlement duration must be from 1 through 120 seconds")
        }
        return value
    }

    private static func validatedKnownSource(_ source: URL) throws -> SourceMetadata {
        let metadata = try fileMetadata(source)
        try require(metadata.size == expectedRealBytes, "known source size changed")
        try require(
            try byte(at: verifiedPrefixBytes - 1, in: source) == 0x0A,
            "verified prefix is not a line boundary"
        )
        try require(
            try byte(at: nextRecordOffset - 1, in: source) == 0x0A,
            "known large line is not newline terminated"
        )
        try require(
            nextRecordOffset - verifiedPrefixBytes - 1 == Int64(compactedLineBytes),
            "known large line length mismatch"
        )
        return metadata
    }

    private static func realSourceFixture(root: URL) -> RealSourceFixture {
        let paths = BackupPaths(
            homeDirectory: root,
            codexRoot: root.appendingPathComponent(".codex", isDirectory: true),
            backupRoot: root.appendingPathComponent("backup", isDirectory: true),
            stateRoot: root.appendingPathComponent("state", isDirectory: true)
        )
        return RealSourceFixture(
            isolatedSource: paths.codexRoot.appendingPathComponent(
                "sessions/2026/07/14/rollout-2026-07-14T10-54-29-\(sessionID).jsonl"
            ),
            paths: paths,
            recoveryRoot: root.appendingPathComponent("recovered-codex", isDirectory: true)
        )
    }

    static func runSynthetic() throws {
        try waitForStartupBaselineCapture()
        emitStage("fixture-start")
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
        emitStage("fixture-written")

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
        emitStage("legacy-scan-complete")

        let cursorStore = BackupCursorStore(databaseURL: paths.cursorDatabaseURL)
        try cursorStore.open()
        let blocked = try require(try cursorStore.cursor(sourcePath: source.path), "legacy cursor missing")
        try require(blocked.lastByteOffset == 0, "legacy scan unexpectedly committed bytes")
        try require(blocked.blockedLineLimitBytes == legacyLineBytes, "legacy line block was not persisted")
        try require(blocked.lastError?.contains("at offset 0") == true, "legacy line block offset missing")

        try BackupAgent(paths: paths, now: { now.addingTimeInterval(1) }).performOneShotScan()
        emitStage("repair-scan-complete")

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
        emitStage("backup-compared")

        let repaired = try require(try cursorStore.cursor(sourcePath: source.path), "repaired cursor missing")
        try require(repaired.lastByteOffset == sourceVerified.byteCount, "repaired cursor offset mismatch")
        try require(repaired.blockedLineLimitBytes == nil, "repaired cursor retained blocked limit")
        try require(repaired.lastError == nil, "repaired cursor retained error")

        let recoveryRoot = root.appendingPathComponent("recovered-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let restorer = IncrementalRecoveryRestorer(paths: paths)
        let plan = try restorer.preflight(sessionIDs: [sessionID], currentSessionIDs: [])
        let restored = try restorer.restore(plan, to: recoveryRoot)
        emitStage("recovery-complete")
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
        emitStage("recovery-compared")

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

    static func runReal(source: URL, root: URL, phase: RealSourcePhase) throws {
        try waitForStartupBaselineCapture()
        let originalBefore = try validatedKnownSource(source)
        var report: [String: Any]
        switch phase {
        case .prepare:
            report = try prepareRealSourceFixture(source: source, root: root)
        case .repair:
            report = try repairRealSourceFixture(source: source, root: root)
            try settleAfterCompletion()
        case .recover:
            report = try recoverRealSourceFixture(source: source, root: root)
        }
        try require(try fileMetadata(source) == originalBefore, "known source metadata changed")
        report["platform"] = "swift"
        report["mode"] = "real-source"
        report["phase"] = phase.rawValue
        report["root"] = root.path
        report["sourcePath"] = source.path
        report["sourceBytes"] = expectedRealBytes
        report["verifiedPrefixBytes"] = verifiedPrefixBytes
        report["largeLineBytes"] = compactedLineBytes
        report["nextRecordOffset"] = nextRecordOffset
        report["lineCount"] = expectedRealLineCount
        report["sha256"] = expectedRealSHA256
        report["chunkCount"] = expectedRealChunkCount
        report["sourceMetadataUnchanged"] = true
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(resultMarker + String(decoding: data, as: UTF8.self))
    }

    private static func prepareRealSourceFixture(source: URL, root: URL) throws -> [String: Any] {
        let fixture = realSourceFixture(root: root)
        try require(!FileManager.default.fileExists(atPath: fixture.isolatedSource.path), "real-source fixture already exists")
        try FileManager.default.createDirectory(
            at: fixture.isolatedSource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: fixture.paths.backupRoot, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: fixture.isolatedSource.path, contents: nil) else {
            throw AcceptanceError.failed("unable to create isolated real-source fixture")
        }
        try copyRange(
            from: source,
            to: fixture.isolatedSource,
            offset: 0,
            count: verifiedPrefixBytes,
            append: false
        )
        emitStage("prefix-copied")
        let now = Date(timeIntervalSince1970: 1_784_332_800)
        try BackupAgent(paths: fixture.paths, now: { now }).performOneShotScan()
        let cursorStore = BackupCursorStore(databaseURL: fixture.paths.cursorDatabaseURL)
        try cursorStore.open()
        let seeded = try require(
            try cursorStore.cursor(sourcePath: fixture.isolatedSource.path),
            "seeded prefix cursor missing"
        )
        try require(seeded.lastByteOffset == verifiedPrefixBytes, "verified prefix cursor mismatch")
        let seededVerification = try BackupVerificationStore(fileURL: fixture.paths.verificationURL).load()
        let seededSidecar = try require(
            seededVerification.sessions[sessionID],
            "seeded prefix verification missing"
        )
        try require(seededSidecar.byteCount == verifiedPrefixBytes, "seeded sidecar prefix mismatch")
        emitStage("prefix-backed-up")
        try copyRange(
            from: source,
            to: fixture.isolatedSource,
            offset: verifiedPrefixBytes,
            count: expectedRealBytes - verifiedPrefixBytes,
            append: true
        )
        emitStage("suffix-copied")
        try legacyAgent(paths: fixture.paths, now: now.addingTimeInterval(1)).performOneShotScan()
        let blocked = try require(
            try cursorStore.cursor(sourcePath: fixture.isolatedSource.path),
            "real-source blocked cursor missing"
        )
        try require(blocked.lastByteOffset == verifiedPrefixBytes, "real-source block advanced prefix")
        try require(blocked.blockedLineLimitBytes == legacyLineBytes, "real-source legacy block missing")
        try require(
            blocked.lastError?.contains("at offset \(verifiedPrefixBytes)") == true,
            "real-source block offset mismatch"
        )
        emitStage("legacy-blocked")
        return [
            "blockedLimitBytes": legacyLineBytes,
            "cursorOffset": blocked.lastByteOffset
        ]
    }

    private static func repairRealSourceFixture(source: URL, root: URL) throws -> [String: Any] {
        let fixture = realSourceFixture(root: root)
        try require(
            try fileMetadata(fixture.isolatedSource).size == expectedRealBytes,
            "isolated real-source size mismatch"
        )
        let cursorStore = BackupCursorStore(databaseURL: fixture.paths.cursorDatabaseURL)
        try cursorStore.open()
        let blocked = try require(
            try cursorStore.cursor(sourcePath: fixture.isolatedSource.path),
            "prepared blocked cursor missing"
        )
        try require(blocked.lastByteOffset == verifiedPrefixBytes, "prepared cursor offset mismatch")
        try require(blocked.blockedLineLimitBytes == legacyLineBytes, "prepared blocked limit mismatch")
        try BackupAgent(
            paths: fixture.paths,
            now: { Date(timeIntervalSince1970: 1_784_332_802) }
        ).performOneShotScan()
        let repaired = try require(
            try cursorStore.cursor(sourcePath: fixture.isolatedSource.path),
            "real-source repaired cursor missing"
        )
        try require(repaired.lastByteOffset == expectedRealBytes, "real-source repaired cursor offset mismatch")
        try require(repaired.blockedLineLimitBytes == nil, "real-source repaired cursor retained limit")
        try require(repaired.lastError == nil, "real-source repaired cursor retained error")
        emitStage("repair-complete")

        let manifest = try BackupManifestStore(manifestURL: fixture.paths.manifestURL).loadOrCreate(
            codexRoot: fixture.paths.codexRoot.path,
            backupRoot: fixture.paths.backupRoot.path
        )
        let record = try require(manifest.sessions[sessionID], "real-source repaired manifest missing")
        let backup = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)
        let sourceFingerprint = try fingerprint(source)
        try requireKnownFingerprint(sourceFingerprint, label: "known source")
        let backupFingerprint = try fingerprint(backup)
        try require(backupFingerprint == sourceFingerprint, "real-source backup fingerprint mismatch")
        try require(try filesEqual(source, fixture.isolatedSource), "isolated source copy mismatch")
        try require(try filesEqual(source, backup), "real-source backup differs byte-for-byte")
        emitStage("backup-compared")

        let verification = try BackupVerificationStore(fileURL: fixture.paths.verificationURL).load()
        let sidecar = try require(verification.sessions[sessionID], "real-source sidecar missing")
        try require(sidecar.byteCount == sourceFingerprint.byteCount, "real-source sidecar bytes mismatch")
        try require(sidecar.lineCount == sourceFingerprint.lineCount, "real-source sidecar lines mismatch")
        try require(sidecar.chunkHashes == sourceFingerprint.chunkHashes, "real-source sidecar chunks mismatch")
        try require(record.bytesBackedUp == sourceFingerprint.byteCount, "real-source manifest bytes mismatch")
        try require(record.lineCount == sourceFingerprint.lineCount, "real-source manifest lines mismatch")
        return [
            "blockedLimitBytes": legacyLineBytes,
            "repairedCursorOffset": repaired.lastByteOffset
        ]
    }

    private static func recoverRealSourceFixture(source: URL, root: URL) throws -> [String: Any] {
        let fixture = realSourceFixture(root: root)
        try require(
            !FileManager.default.fileExists(atPath: fixture.recoveryRoot.path),
            "real-source recovery root already exists"
        )
        try FileManager.default.createDirectory(at: fixture.recoveryRoot, withIntermediateDirectories: true)
        let restorer = IncrementalRecoveryRestorer(paths: fixture.paths)
        let plan = try restorer.preflight(sessionIDs: [sessionID], currentSessionIDs: [])
        emitStage("preflight-complete")
        let result = try restorer.restore(plan, to: fixture.recoveryRoot)
        try require(result.restoredSessionIDs == [sessionID], "real-source incremental recovery missing")
        emitStage("recovery-complete")
        let recovered = fixture.recoveryRoot.appendingPathComponent("sessions/recovered/\(sessionID).jsonl")
        let recoveredFingerprint = try fingerprint(recovered)
        try requireKnownFingerprint(recoveredFingerprint, label: "recovered source")
        try require(try filesEqual(source, recovered), "real-source recovery differs byte-for-byte")
        emitStage("recovery-compared")
        return ["restoredSessionIDs": result.restoredSessionIDs]
    }

    static func runBoundedLifecycle() throws {
        let totalMiB = try validatedLifecycleTotalMiB(
            ProcessInfo.processInfo.environment["CODEX_LIFECYCLE_TOTAL_MIB"]
        )
        try waitForStartupBaselineCapture()
        emitStage("fixture-start")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("large-jsonl-lifecycle-swift-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(".codex/sessions/\(sessionID).jsonl")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: source.path, contents: nil) else {
            throw AcceptanceError.failed("unable to create lifecycle fixture")
        }
        let output = try FileHandle(forWritingTo: source)
        let compactedPrefix = Data(#"{"timestamp":"2026-07-18T00:00:00Z","type":"compacted","payload":{"message":""#.utf8)
        let compactedSuffix = Data(#""}}"#.utf8) + Data([0x0A])
        try output.write(contentsOf: compactedPrefix)
        let compactedFill = Data(repeating: 0x78, count: 1_024 * 1_024)
        var compactedRemaining = compactedLineBytes - compactedPrefix.count - compactedSuffix.count + 1
        while compactedRemaining > 0 {
            let count = min(compactedRemaining, compactedFill.count)
            try output.write(contentsOf: compactedFill.prefix(count))
            compactedRemaining -= count
        }
        try output.write(contentsOf: compactedSuffix)

        let expectedBytes = totalMiB * 1_024 * 1_024
        try require(expectedBytes > compactedLineBytes + 1, "lifecycle fixture must exceed compacted line")
        let normalPrefix = Data(#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":""#.utf8)
        let normalSuffix = Data(#""}}"#.utf8) + Data([0x0A])
        func fixedLine(byteCount: Int) -> Data {
            normalPrefix + Data(repeating: 0x79, count: byteCount - normalPrefix.count - normalSuffix.count) + normalSuffix
        }
        let normalLine = fixedLine(byteCount: 1_024)
        var normalBlock = Data()
        normalBlock.reserveCapacity(1_024 * 1_024)
        for _ in 0..<1_024 { normalBlock.append(normalLine) }
        var remaining = expectedBytes - (compactedLineBytes + 1)
        var normalLineCount = 0
        while remaining >= normalBlock.count {
            try output.write(contentsOf: normalBlock)
            remaining -= normalBlock.count
            normalLineCount += 1_024
        }
        while remaining >= normalLine.count {
            try output.write(contentsOf: normalLine)
            remaining -= normalLine.count
            normalLineCount += 1
        }
        if remaining > 0 {
            try output.write(contentsOf: fixedLine(byteCount: remaining))
            normalLineCount += 1
        }
        let lineCount = 1 + normalLineCount
        try output.synchronize()
        try output.close()
        emitStage("fixture-written")

        let paths = BackupPaths(
            homeDirectory: root,
            codexRoot: root.appendingPathComponent(".codex", isDirectory: true),
            backupRoot: root.appendingPathComponent("backup", isDirectory: true),
            stateRoot: root.appendingPathComponent("state", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: paths.backupRoot, withIntermediateDirectories: true)
        try BackupAgent(paths: paths).performOneShotScan()
        emitStage("backup-complete")
        let manifest = try BackupManifestStore(manifestURL: paths.manifestURL).loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path
        )
        let record = try require(manifest.sessions[sessionID], "lifecycle manifest missing")
        let backup = paths.backupRoot.appendingPathComponent(record.backupPath)
        let verified = try BackupFileVerifier().verifyFull(
            backup,
            expectedByteCount: Int64(expectedBytes),
            expectedLineCount: lineCount
        )
        emitStage("backup-verified")
        try require(try filesEqual(source, backup), "lifecycle backup differs")
        emitStage("backup-compared")

        let recoveryRoot = root.appendingPathComponent("recovered-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let restorer = IncrementalRecoveryRestorer(paths: paths)
        let plan = try restorer.preflight(sessionIDs: [sessionID], currentSessionIDs: [])
        emitStage("preflight-complete")
        let result = try restorer.restore(plan, to: recoveryRoot)
        emitStage("recovery-complete")
        try require(result.restoredSessionIDs == [sessionID], "lifecycle recovery missing")
        let recovered = recoveryRoot.appendingPathComponent("sessions/recovered/\(sessionID).jsonl")
        try require(try filesEqual(source, recovered), "lifecycle recovery differs")
        emitStage("recovery-compared")

        let report: [String: Any] = [
            "platform": "swift",
            "mode": "bounded-lifecycle",
            "totalMiB": totalMiB,
            "exactCompactedLineBytes": compactedLineBytes,
            "byteCount": verified.byteCount,
            "lineCount": verified.lineCount,
            "sha256": verified.contentHash,
            "chunkCount": verified.chunkHashes.count
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(resultMarker + String(decoding: data, as: UTF8.self))
    }

    static func validatedLifecycleTotalMiB(_ rawValue: String?) throws -> Int {
        guard let rawValue else { return 96 }
        guard let value = Int(rawValue),
              (minimumLifecycleTotalMiB...maximumLifecycleTotalMiB).contains(value) else {
            throw AcceptanceError.failed(
                "CODEX_LIFECYCLE_TOTAL_MIB must be an integer from \(minimumLifecycleTotalMiB) through \(maximumLifecycleTotalMiB)"
            )
        }
        return value
    }

    private static func emitStage(_ stage: String) {
        let marker = Data("LARGE_JSONL_ACCEPTANCE_STAGE=\(stage)\n".utf8)
        FileHandle.standardError.write(marker)
        guard let stagePath = ProcessInfo.processInfo.environment["CODEX_LARGE_JSONL_STAGE_FILE"] else {
            return
        }
        if !FileManager.default.fileExists(atPath: stagePath) {
            FileManager.default.createFile(atPath: stagePath, contents: nil)
        }
        guard let stageFile = FileHandle(forWritingAtPath: stagePath) else { return }
        defer { try? stageFile.close() }
        do {
            try stageFile.seekToEnd()
            try stageFile.write(contentsOf: marker)
            try stageFile.synchronize()
        } catch {
            // The stderr marker remains available if the diagnostic side channel fails.
        }
    }

    private static func waitForStartupBaselineCapture() throws {
        emitStage("startup-ready")
        try waitForResourceAcknowledgment(
            environmentName: "CODEX_LARGE_JSONL_BASELINE_ACK_FILE",
            failureMessage: "resource guard did not capture startup-ready baseline"
        )
    }

    private static func settleAfterCompletion() throws {
        BackupMemoryPressureRelief.relieve()
        emitStage("settling")
        let seconds = try validatedSettlementSeconds(
            ProcessInfo.processInfo.environment["CODEX_LARGE_JSONL_SETTLE_SECONDS"]
        )
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
        BackupMemoryPressureRelief.relieve()
        emitStage("settled")
        try waitForResourceAcknowledgment(
            environmentName: "CODEX_LARGE_JSONL_SETTLED_ACK_FILE",
            failureMessage: "resource guard did not capture settled memory"
        )
    }

    private static func waitForResourceAcknowledgment(
        environmentName: String,
        failureMessage: String
    ) throws {
        guard let acknowledgmentPath = ProcessInfo.processInfo.environment[environmentName] else { return }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: acknowledgmentPath) {
            guard Date() < deadline else {
                throw AcceptanceError.failed(failureMessage)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
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
            let copied = try autoreleasepool { () throws -> Int in
                let chunk = try input.read(upToCount: Int(min(4 * 1_024 * 1_024, remaining))) ?? Data()
                try require(!chunk.isEmpty, "known source ended during isolated copy")
                try output.write(contentsOf: chunk)
                return chunk.count
            }
            remaining -= Int64(copied)
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

    private static func fingerprint(_ url: URL) throws -> FileFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var byteCount: Int64 = 0
        var lineCount = 0
        var chunkHashes: [String] = []
        while true {
            let didRead = try autoreleasepool { () throws -> Bool in
                guard let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty else {
                    return false
                }
                digest.update(data: chunk)
                chunkHashes.append(hexDigest(SHA256.hash(data: chunk)))
                byteCount += Int64(chunk.count)
                lineCount += chunk.reduce(into: 0) { count, byte in
                    if byte == 0x0A { count += 1 }
                }
                return true
            }
            if !didRead { break }
        }
        return FileFingerprint(
            byteCount: byteCount,
            lineCount: lineCount,
            contentHash: hexDigest(digest.finalize()),
            chunkHashes: chunkHashes
        )
    }

    private static func requireKnownFingerprint(_ fingerprint: FileFingerprint, label: String) throws {
        try require(fingerprint.byteCount == expectedRealBytes, "\(label) byte count mismatch")
        try require(fingerprint.lineCount == expectedRealLineCount, "\(label) line count mismatch")
        try require(fingerprint.contentHash == expectedRealSHA256, "\(label) SHA-256 mismatch")
        try require(fingerprint.chunkHashes.count == expectedRealChunkCount, "\(label) chunk count mismatch")
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func filesEqual(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let left = try FileHandle(forReadingFrom: lhs)
        let right = try FileHandle(forReadingFrom: rhs)
        defer { try? left.close(); try? right.close() }
        while true {
            let comparison = try autoreleasepool { () throws -> (matches: Bool, reachedEnd: Bool) in
                let leftChunk = try left.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
                let rightChunk = try right.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
                return (leftChunk == rightChunk, leftChunk.isEmpty)
            }
            if !comparison.matches { return false }
            if comparison.reachedEnd { return true }
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

private struct FileFingerprint: Equatable {
    let byteCount: Int64
    let lineCount: Int
    let contentHash: String
    let chunkHashes: [String]
}

private struct RealSourceFixture {
    let isolatedSource: URL
    let paths: BackupPaths
    let recoveryRoot: URL
}

private enum RealSourcePhase: String {
    case prepare
    case repair
    case recover
}

private enum AcceptanceError: Error {
    case failed(String)
}
