import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite("ConversationLogParser")
struct ConversationLogParserTests {
    @Test
    func streamsEventMessagesAndPrefersThemOverResponseFallback() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sessionID = "11111111-2222-3333-4444-555555555555"
        let file = fixture.sessionFile(sessionID: sessionID)
        try fixture.write([
            ["type": "session_meta", "payload": ["id": sessionID]],
            [
                "timestamp": "2026-07-17T01:02:03Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "fallback"]]
                ]
            ],
            [
                "timestamp": "2026-07-17T01:02:04.125Z",
                "type": "event_msg",
                "payload": ["type": "user_message", "message": "hello"]
            ],
            [
                "timestamp": "2026-07-17T01:02:05Z",
                "type": "event_msg",
                "payload": ["type": "agent_message", "message": "world", "phase": "final"]
            ]
        ], to: file)
        let trusted = try #require(
            TrustedSessionFileResolver.resolve(sessionIDs: [sessionID], under: fixture.root).first
        )

        let messages = try ConversationLogParser.loadMessages(from: trusted)

        #expect(messages.map(\.role) == ["用户", "助手"])
        #expect(messages.map(\.text) == ["hello", "world"])
        #expect(messages.map(\.phase) == [nil, "final"])
        #expect(messages.allSatisfy { $0.timestamp != nil })
    }

    @Test
    func parsesAcrossSeveralOneMiBReadChunksWithoutWholeFileLoading() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let file = fixture.sessionFile(sessionID: sessionID)
        try fixture.writeLargeRollout(sessionID: sessionID, to: file)
        let trusted = try #require(
            TrustedSessionFileResolver.resolve(sessionIDs: [sessionID], under: fixture.root).first
        )

        let messages = try ConversationLogParser.loadMessages(from: trusted)

        #expect(messages.map(\.text) == ["message-after-several-read-chunks"])
    }

    @Test
    func rejectsAFileChangedAfterTrustedResolution() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sessionID = "99999999-8888-7777-6666-555555555555"
        let file = fixture.sessionFile(sessionID: sessionID)
        try fixture.write([
            ["type": "session_meta", "payload": ["id": sessionID]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "before"]]
        ], to: file)
        let trusted = try #require(
            TrustedSessionFileResolver.resolve(sessionIDs: [sessionID], under: fixture.root).first
        )
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"event_msg","payload":{"type":"agent_message","message":"after"}}\n"#.utf8))
        try handle.close()

        #expect(throws: SessionJSONLValidationError.self) {
            try ConversationLogParser.loadMessages(from: trusted)
        }
    }

    @Test
    func cancellationStopsALargeStreamingParse() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sessionID = "12345678-1234-1234-1234-123456789abc"
        let file = fixture.sessionFile(sessionID: sessionID)
        try fixture.writeLargeRollout(sessionID: sessionID, to: file)
        let trusted = try #require(
            TrustedSessionFileResolver.resolve(sessionIDs: [sessionID], under: fixture.root).first
        )
        let task = Task.detached {
            try ConversationLogParser.loadMessages(from: trusted)
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("conversation-log-parser-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("sessions", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        func sessionFile(sessionID: String) -> URL {
            root.appendingPathComponent("sessions/rollout-\(sessionID).jsonl")
        }

        func write(_ objects: [[String: Any]], to file: URL) throws {
            let handle = try writableHandle(at: file)
            defer { try? handle.close() }
            for object in objects {
                try handle.write(contentsOf: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                try handle.write(contentsOf: Data([0x0A]))
            }
        }

        func writeLargeRollout(sessionID: String, to file: URL) throws {
            let handle = try writableHandle(at: file)
            defer { try? handle.close() }
            let metadata: [String: Any] = ["type": "session_meta", "payload": ["id": sessionID]]
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]))
            try handle.write(contentsOf: Data([0x0A]))
            let padding: [String: Any] = [
                "type": "turn_context",
                "payload": ["padding": String(repeating: "x", count: 192)]
            ]
            let paddingLine = try JSONSerialization.data(withJSONObject: padding, options: [.sortedKeys]) + Data([0x0A])
            for _ in 0..<14_000 {
                try handle.write(contentsOf: paddingLine)
            }
            let message: [String: Any] = [
                "type": "event_msg",
                "payload": ["type": "agent_message", "message": "message-after-several-read-chunks"]
            ]
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]))
            try handle.write(contentsOf: Data([0x0A]))
        }

        func writableHandle(at file: URL) throws -> FileHandle {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            return try FileHandle(forWritingTo: file)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
