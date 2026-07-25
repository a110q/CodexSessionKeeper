@MainActor
public final class UpdateTerminationApprovalGate {
    private var approved = false

    public init() {}

    public func approve() {
        approved = true
    }

    public func consume() -> Bool {
        guard approved else { return false }
        approved = false
        return true
    }

    public func revoke() {
        approved = false
    }
}
