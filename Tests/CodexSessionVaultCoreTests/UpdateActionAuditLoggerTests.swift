import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite
struct UpdateActionAuditLoggerTests {
    @Test
    func writesOneBoundedJSONLinePerUpdateEvent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "update-audit-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("update-audit.jsonl")
        let now = Date(timeIntervalSince1970: 1_753_248_000)
        let logger = UpdateActionAuditLogger(
            url: logURL,
            platform: "macos-arm64",
            now: { now }
        )

        try logger.record(.downloadConfirmationRequested, version: "1.1.0")
        try logger.record(.downloadConfirmed, version: "1.1.0")

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try lines.map {
            try decoder.decode(UpdateActionAuditEntry.self, from: Data($0.utf8))
        }
        #expect(entries.map(\.event) == [
            .downloadConfirmationRequested,
            .downloadConfirmed,
        ])
        #expect(entries.allSatisfy { $0.schemaVersion == 1 })
        #expect(entries.allSatisfy { $0.platform == "macos-arm64" })
        #expect(entries.allSatisfy { $0.version == "1.1.0" })
        #expect(entries.allSatisfy { $0.timestamp == now })
    }
}
