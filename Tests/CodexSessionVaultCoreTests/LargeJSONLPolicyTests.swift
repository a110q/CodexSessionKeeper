import Foundation
import Testing
@testable import CodexSessionVaultCore

@Test
func swiftJSONLConsumersShareThe64MiBLimit() {
    #expect(SessionJSONLPolicy.maximumLineBytes == 67_108_864)
    #expect(35_895_162 < SessionJSONLPolicy.maximumLineBytes)
    #expect(SessionTailer.defaultMaxLineBytes == SessionJSONLPolicy.maximumLineBytes)
    #expect(SessionJSONLScanner.maximumLineBytes == SessionJSONLPolicy.maximumLineBytes)
    #expect(SessionBackupStreamer().effectiveMaxLineBytes == SessionJSONLPolicy.maximumLineBytes)
    #expect(BackupFileVerifier().maxLineBytes == SessionJSONLPolicy.maximumLineBytes)
}

@Test
func onboardingProgressSummaryUsesTruthfulChineseCounts() {
    let healthy = NASSetupSnapshot(
        state: .running,
        pendingCount: 1,
        completedCount: 2,
        totalCount: 3,
        failedCount: 0
    )
    let failed = NASSetupSnapshot(
        state: .error,
        pendingCount: 1,
        completedCount: 2,
        totalCount: 3,
        failedCount: 1
    )

    #expect(healthy.progressSummary == "已发现 3 · 已检查 2 · 待处理 1")
    #expect(failed.progressSummary == "已发现 3 · 成功 1 · 异常 1 · 待处理 1")
}

@Test
func olderNASSetupSnapshotPayloadDefaultsFailedCountToZero() throws {
    let snapshot = try JSONDecoder().decode(
        NASSetupSnapshot.self,
        from: Data(#"{"state":"running","pendingCount":0,"completedCount":2,"totalCount":2}"#.utf8)
    )

    #expect(snapshot.failedCount == 0)
}
