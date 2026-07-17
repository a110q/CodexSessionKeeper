import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite("SessionDeletionPlan")
struct SessionDeletionPlanTests {
    @Test
    func removesOnlyExactIndexesAndNeverUsesAnExternalRawPath() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = "11111111-2222-3333-4444-555555555555"
        let outside = fixture.parent.appendingPathComponent("outside-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: outside) }
        try fixture.writeRollout(id: target, to: outside)
        try fixture.writeJSON([
            ["session_id": target, "first_text": "remove"],
            ["session_id": "safe", "first_text": "mentions \(target)"]
        ], to: fixture.root.appendingPathComponent("history.jsonl"))

        let plan = try SessionDeletionPlan.preflight(sessionIDs: [target], codexRoot: fixture.root)
        let warning = try plan.commit()

        #expect(warning?.contains("仅清理索引") == true)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        let document = try SessionJSONLValidator.parse(
            fixture.root.appendingPathComponent("history.jsonl"),
            kind: .history
        )
        #expect(document.records.map(\.sessionID) == ["safe"])
    }

    @Test
    func oneMalformedJSONLStopsPreflightBeforeAnyDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = "11111111-2222-3333-4444-555555555555"
        let rollout = fixture.root.appendingPathComponent("sessions/valid.jsonl")
        try fixture.writeRollout(id: target, to: rollout)
        try Data("{\"session_id\":\"\(target)\"}\n\n".utf8).write(
            to: fixture.root.appendingPathComponent("history.jsonl")
        )

        #expect(throws: SessionJSONLValidationError.self) {
            try SessionDeletionPlan.preflight(sessionIDs: [target], codexRoot: fixture.root)
        }
        #expect(FileManager.default.fileExists(atPath: rollout.path))
    }

    private struct Fixture {
        let root: URL
        let parent = FileManager.default.temporaryDirectory

        init() throws {
            root = parent.appendingPathComponent("session-delete-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func writeRollout(id: String, to url: URL) throws {
            try writeJSON([["type": "session_meta", "payload": ["id": id]]], to: url)
        }

        func writeJSON(_ objects: [[String: Any]], to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for object in objects {
                data.append(try JSONSerialization.data(withJSONObject: object))
                data.append(0x0A)
            }
            try data.write(to: url)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
