import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
@MainActor
struct UpdateAttemptGateTests {
    @Test
    func pendingReplyResolvesExactlyOnceAndAllowsTheNextAttempt() {
        let gate = UpdateAttemptGate<String>()
        var replies: [String] = []

        #expect(gate.beginRequest())
        #expect(!gate.beginRequest())
        gate.holdReadyReply(
            { replies.append($0) },
            resolvingPreviousWith: "dismiss-old"
        )
        #expect(gate.hasPendingReply)
        #expect(!gate.beginRequest())

        #expect(gate.resolveReadyReply("dismiss"))
        #expect(!gate.resolveReadyReply("install"))
        #expect(replies == ["dismiss"])
        #expect(gate.beginRequest())
    }

    @Test
    func replacingAReadyReplyDismissesThePreviousReply() {
        let gate = UpdateAttemptGate<String>()
        var replies: [String] = []
        gate.holdReadyReply(
            { replies.append("first:\($0)") },
            resolvingPreviousWith: "unused"
        )

        gate.holdReadyReply(
            { replies.append("second:\($0)") },
            resolvingPreviousWith: "replaced"
        )

        #expect(replies == ["first:replaced"])
        #expect(gate.resolveReadyReply("install"))
        #expect(replies == ["first:replaced", "second:install"])
    }

    @Test
    func discardingAReplyClearsBusyStateWithoutInvokingIt() {
        let gate = UpdateAttemptGate<String>()
        var replyCount = 0
        gate.holdReadyReply(
            { _ in replyCount += 1 },
            resolvingPreviousWith: "unused"
        )

        gate.discardReadyReply()

        #expect(replyCount == 0)
        #expect(!gate.isBusy)
    }

    @Test
    func blockedInstallSkipsTheReadyReplyAndRequiresANewAttempt() {
        let gate = UpdateAttemptGate<String>()
        var replies: [String] = []
        #expect(gate.beginRequest())
        gate.holdReadyReply(
            { replies.append($0) },
            resolvingPreviousWith: "unused"
        )

        #expect(gate.cancelPendingSession(with: "skip"))

        #expect(replies == ["skip"])
        #expect(!gate.hasPendingReply)
        #expect(!gate.isBusy)
        #expect(gate.beginRequest())
    }
}
