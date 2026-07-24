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

    @Test
    @MainActor
    func cancelledDownloadConfirmationCannotRunTheDownloadAction() {
        var operationCount = 0

        let performed = MacUpdateConsentPolicy.perform(
            .beginDownload,
            in: .available(version: "1.1.0", notes: []),
            confirmation: { false },
            operation: { operationCount += 1 }
        )

        #expect(!performed)
        #expect(operationCount == 0)
    }

    @Test
    @MainActor
    func cancelledInstallConfirmationCannotRunTheInstallAction() async {
        var operationCount = 0

        let performed = await MacUpdateConsentPolicy.performAsync(
            .restartAndInstall,
            in: .ready(version: "1.1.0"),
            confirmation: { false },
            operation: { operationCount += 1 }
        )

        #expect(!performed)
        #expect(operationCount == 0)
    }

    @Test
    @MainActor
    func confirmedActionsRunExactlyOnce() async {
        var downloadCount = 0
        var installCount = 0

        let downloaded = MacUpdateConsentPolicy.perform(
            .beginDownload,
            in: .available(version: "1.1.0", notes: []),
            confirmation: { true },
            operation: { downloadCount += 1 }
        )
        let installed = await MacUpdateConsentPolicy.performAsync(
            .restartAndInstall,
            in: .ready(version: "1.1.0"),
            confirmation: { true },
            operation: { installCount += 1 }
        )

        #expect(downloaded)
        #expect(installed)
        #expect(downloadCount == 1)
        #expect(installCount == 1)
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
