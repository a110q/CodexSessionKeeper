import Testing
@testable import CodexSessionVaultCore

@Suite
struct UpdatePresentationStateTests {
    @Test
    func reducerTracksDownloadAndInstallProgress() {
        var machine = UpdatePresentationMachine()
        machine.apply(.checkStarted)
        #expect(machine.state == .checking)

        machine.apply(.found(version: "1.1.0", notes: ["新功能"]))
        #expect(machine.state == .available(version: "1.1.0", notes: ["新功能"]))

        machine.apply(.downloadStarted(version: "1.1.0"))
        #expect(machine.state == .downloading(version: "1.1.0", received: 0, total: nil))

        machine.apply(.downloadProgress(version: "1.1.0", received: 5, total: 10))
        #expect(machine.state == .downloading(version: "1.1.0", received: 5, total: 10))

        machine.apply(.extractionProgress(version: "1.1.0", progress: 1.5))
        #expect(machine.state == .extracting(version: "1.1.0", progress: 1))

        machine.apply(.downloadReady(version: "1.1.0"))
        #expect(machine.state == .ready(version: "1.1.0"))

        machine.apply(.installStarted(version: "1.1.0"))
        #expect(machine.state == .installing(version: "1.1.0"))
    }

    @Test
    func reducerTracksTerminalAndDismissedStates() {
        var machine = UpdatePresentationMachine()
        machine.apply(.failed(message: "失败"))
        #expect(machine.state == .failed(message: "失败"))
        machine.apply(.dismiss)
        #expect(machine.state == .idle)
        machine.apply(.upToDate(version: "1.1.0"))
        #expect(machine.state == .upToDate(version: "1.1.0"))
        machine.apply(.completed(version: "1.1.1"))
        #expect(machine.state == .completed(version: "1.1.1"))
    }
}
