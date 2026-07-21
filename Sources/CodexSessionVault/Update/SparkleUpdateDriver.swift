import AppKit
import Sparkle

@MainActor
protocol SparkleUpdateDriverDelegate: AnyObject {
    func sparkleCheckStarted(cancellation: @escaping () -> Void)
    func acceptSparkleItem(
        displayVersion: String,
        buildVersion: String,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    )
    func sparkleUpdateNotFound()
    func sparkleUpdaterFailed()
    func sparkleDownloadStarted(cancellation: @escaping () -> Void)
    func setDownloadTotal(_ total: UInt64)
    func addDownloadedBytes(_ length: UInt64)
    func sparkleExtractionStarted()
    func setExtractionProgress(_ progress: Double)
    func holdReadyReply(_ reply: @escaping (SPUUserUpdateChoice) -> Void)
    func sparkleInstallStarted(
        applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    )
    func sparkleInstallCompleted()
    func sparkleDismissed()
    func revealUpdateInFocus()
}

@MainActor
final class SparkleUpdateDriver: NSObject, SPUUserDriver {
    weak var delegate: (any SparkleUpdateDriverDelegate)?

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        delegate?.sparkleCheckStarted(cancellation: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        delegate?.acceptSparkleItem(
            displayVersion: appcastItem.displayVersionString,
            buildVersion: appcastItem.versionString,
            reply: reply
        )
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        delegate?.sparkleUpdateNotFound()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        delegate?.sparkleUpdaterFailed()
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        delegate?.sparkleDownloadStarted(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        delegate?.setDownloadTotal(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        delegate?.addDownloadedBytes(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        delegate?.sparkleExtractionStarted()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        delegate?.setExtractionProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        delegate?.holdReadyReply(reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        delegate?.sparkleInstallStarted(
            applicationTerminated: applicationTerminated,
            retryTerminatingApplication: retryTerminatingApplication
        )
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        delegate?.sparkleInstallCompleted()
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        delegate?.sparkleDismissed()
    }

    func showUpdateInFocus() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        delegate?.revealUpdateInFocus()
    }
}
