import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
@MainActor
struct UpdateTerminationApprovalGateTests {
    @Test
    func approvalIsConsumedExactlyOnce() {
        let gate = UpdateTerminationApprovalGate()

        #expect(!gate.consume())
        gate.approve()
        #expect(gate.consume())
        #expect(!gate.consume())
    }

    @Test
    func revocationRemovesUnusedApproval() {
        let gate = UpdateTerminationApprovalGate()

        gate.approve()
        gate.revoke()

        #expect(!gate.consume())
    }
}
