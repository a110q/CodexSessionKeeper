import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite("SessionProtectionSnapshotPlan")
struct SessionProtectionSnapshotPlanTests {
    @Test
    func copiesOnlyFrozenTrustedRolloutsAndExactLineIdentities() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = "11111111-2222-3333-4444-555555555555"
        let other = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let trusted = fixture.root.appendingPathComponent("sessions/unrelated-name.jsonl")
        let misleading = fixture.root.appendingPathComponent("sessions/rollout-\(target).jsonl")
        try fixture.writeRollout(id: target, to: trusted)
        try fixture.writeRollout(id: other, to: misleading)
        try fixture.writeJSON([
            ["session_id": target, "first_text": "selected"],
            ["session_id": other, "first_text": "mentions \(target)"]
        ], to: fixture.root.appendingPathComponent("history.jsonl"))

        let plan = try SessionProtectionSnapshotPlan.preflight(
            sessionIDs: [target],
            codexRoot: fixture.root,
            destinationRoot: fixture.destination
        )
        let included = try plan.materialize()

        #expect(included.contains("sessions"))
        #expect(included.contains("history.jsonl"))
        #expect(FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("sessions/unrelated-name.jsonl").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("sessions/rollout-\(target).jsonl").path
        ))
        let history = try SessionJSONLValidator.parse(
            fixture.destination.appendingPathComponent("history.jsonl"),
            kind: .history
        )
        #expect(history.records.map(\.sessionID) == [target])
    }

    @Test
    func rejectsSourceChangedAfterPreflightBeforeCreatingSnapshotFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = "11111111-2222-3333-4444-555555555555"
        let rollout = fixture.root.appendingPathComponent("sessions/session.jsonl")
        try fixture.writeRollout(id: target, to: rollout)
        let plan = try SessionProtectionSnapshotPlan.preflight(
            sessionIDs: [target],
            codexRoot: fixture.root,
            destinationRoot: fixture.destination
        )
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{}}\n".utf8))
        try handle.close()

        #expect(throws: SessionJSONLValidationError.self) {
            try plan.materialize()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    private struct Fixture {
        let parent: URL
        let root: URL
        let destination: URL

        init() throws {
            parent = FileManager.default.temporaryDirectory.appendingPathComponent(
                "session-protection-\(UUID().uuidString)",
                isDirectory: true
            )
            root = parent.appendingPathComponent("codex", isDirectory: true)
            destination = parent.appendingPathComponent("snapshot/data", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func writeRollout(id: String, to url: URL) throws {
            try writeJSON([["type": "session_meta", "payload": ["id": id]]], to: url)
        }

        func writeJSON(_ objects: [[String: Any]], to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var data = Data()
            for object in objects {
                data.append(try JSONSerialization.data(withJSONObject: object))
                data.append(0x0A)
            }
            try data.write(to: url)
        }

        func cleanup() { try? FileManager.default.removeItem(at: parent) }
    }
}
