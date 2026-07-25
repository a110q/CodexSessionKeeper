@MainActor
public final class UpdateAttemptGate<Choice> {
    private var requestInFlight = false
    private var readyReply: ((Choice) -> Void)?

    public init() {}

    public var hasRequestInFlight: Bool {
        requestInFlight
    }

    public var hasPendingReply: Bool {
        readyReply != nil
    }

    public var isBusy: Bool {
        requestInFlight || readyReply != nil
    }

    @discardableResult
    public func beginRequest() -> Bool {
        guard !isBusy else { return false }
        requestInFlight = true
        return true
    }

    public func endRequest() {
        requestInFlight = false
    }

    public func holdReadyReply(
        _ reply: @escaping (Choice) -> Void,
        resolvingPreviousWith replacementChoice: Choice
    ) {
        endRequest()
        _ = resolveReadyReply(replacementChoice)
        readyReply = reply
    }

    @discardableResult
    public func resolveReadyReply(_ choice: Choice) -> Bool {
        guard let reply = readyReply else { return false }
        readyReply = nil
        reply(choice)
        return true
    }

    public func discardReadyReply() {
        readyReply = nil
    }
}
