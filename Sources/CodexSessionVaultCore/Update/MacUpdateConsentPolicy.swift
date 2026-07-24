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

    @MainActor
    @discardableResult
    public static func perform(
        _ action: MacUpdateUserAction,
        in state: UpdatePresentationState,
        confirmation: () -> Bool,
        operation: () -> Void
    ) -> Bool {
        guard allows(action, in: state), confirmation() else {
            return false
        }
        operation()
        return true
    }

    @MainActor
    @discardableResult
    public static func performAsync(
        _ action: MacUpdateUserAction,
        in state: UpdatePresentationState,
        confirmation: () -> Bool,
        operation: () async -> Void
    ) async -> Bool {
        guard allows(action, in: state), confirmation() else {
            return false
        }
        await operation()
        return true
    }
}
