import Testing
@testable import CodexSessionVaultCore

@Suite
struct MacUpdateConsentPolicyTests {
    @Test
    func downloadRequiresTheAvailableState() {
        #expect(MacUpdateConsentPolicy.allows(
            .beginDownload,
            in: .available(version: "1.1.0", notes: [])
        ))
        for state in nonAvailableStates {
            #expect(!MacUpdateConsentPolicy.allows(.beginDownload, in: state))
        }
    }

    @Test
    func installRequiresTheReadyState() {
        #expect(MacUpdateConsentPolicy.allows(
            .restartAndInstall,
            in: .ready(version: "1.1.0")
        ))
        for state in nonReadyStates {
            #expect(!MacUpdateConsentPolicy.allows(.restartAndInstall, in: state))
        }
    }

    private var nonAvailableStates: [UpdatePresentationState] {
        [
            .idle,
            .checking,
            .downloading(version: "1.1.0", received: 1, total: 2),
            .extracting(version: "1.1.0", progress: 0.5),
            .ready(version: "1.1.0"),
            .installing(version: "1.1.0"),
            .failed(message: "failed"),
            .upToDate(version: "1.1.0"),
            .completed(version: "1.1.0"),
        ]
    }

    private var nonReadyStates: [UpdatePresentationState] {
        [
            .idle,
            .checking,
            .available(version: "1.1.0", notes: []),
            .downloading(version: "1.1.0", received: 1, total: 2),
            .extracting(version: "1.1.0", progress: 0.5),
            .installing(version: "1.1.0"),
            .failed(message: "failed"),
            .upToDate(version: "1.1.0"),
            .completed(version: "1.1.0"),
        ]
    }
}
