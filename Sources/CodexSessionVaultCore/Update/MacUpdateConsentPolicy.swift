public enum MacUpdateUserAction: Equatable, Sendable {
    case beginDownload
    case restartAndInstall
}

public enum MacUpdateConsentPolicy {
    public static func allows(
        _ action: MacUpdateUserAction,
        in state: UpdatePresentationState
    ) -> Bool {
        switch (action, state) {
        case (.beginDownload, .available):
            return true
        case (.restartAndInstall, .ready):
            return true
        default:
            return false
        }
    }
}
