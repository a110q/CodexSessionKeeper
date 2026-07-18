import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite("SessionJSONLValidator")
struct SessionJSONLValidatorTests {
    @Test
    func usesOnlyTheSchemaIdentityAndNormalizesUUIDCase() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = "11111111-2222-3333-4444-555555555555"
        let other = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let file = fixture.root.appendingPathComponent("history.jsonl")
        try fixture.write([
            ["session_id": target.uppercased(), "first_text": "selected"],
            ["session_id": other, "first_text": "mentions \(target)"],
            ["session_id": "CaseSensitive", "first_text": "exact"],
            ["session_id": "casesensitive", "first_text": "different"]
        ], to: file)

        let document = try SessionJSONLValidator.parse(file, kind: .history)

        #expect(document.records.map(\.sessionID) == [
            target,
            other.lowercased(),
            "CaseSensitive",
            "casesensitive"
        ])
    }

    @Test
    func rejectsInternalBlankInvalidMissingAndConflictingIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("history.jsonl")
        try Data(#"{"session_id":"target"}"#.utf8).write(to: file)
        try FileHandle(forWritingTo: file).apply {
            try $0.seekToEnd()
            try $0.write(contentsOf: Data("\n\nnot-json\n".utf8))
        }

        do {
            _ = try SessionJSONLValidator.parse(file, kind: .history)
            Issue.record("expected invalid JSONL")
        } catch let error as SessionJSONLValidationError {
            #expect(error.code == "INVALID_SESSION_JSONL")
            #expect(error.lineNumber == 2)
        }

        try fixture.write([["session_id": "target", "id": "other"]], to: file)
        #expect(throws: SessionJSONLValidationError.self) {
            try SessionJSONLValidator.parse(file, kind: .history)
        }

        try fixture.write([["first_text": "missing"]], to: file)
        #expect(throws: SessionJSONLValidationError.self) {
            try SessionJSONLValidator.parse(file, kind: .history)
        }

        try fixture.write([["SESSION_ID": "target"]], to: file)
        #expect(throws: SessionJSONLValidationError.self) {
            try SessionJSONLValidator.parse(file, kind: .history)
        }

        try fixture.write([["session_id": "   "]], to: file)
        #expect(throws: SessionJSONLValidationError.self) {
            try SessionJSONLValidator.parse(file, kind: .history)
        }
    }

    @Test
    func resolvesOnlyFilesWhoseFirstRecordAuthenticatesTheSession() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sessions = fixture.root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let target = "11111111-2222-3333-4444-555555555555"
        let nested = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let valid = sessions.appendingPathComponent("unrelated-name.jsonl")
        try fixture.write([
            ["type": "session_meta", "payload": ["id": target]],
            ["type": "session_meta", "payload": ["id": nested]]
        ], to: valid)
        try fixture.write([
            ["type": "event_msg", "payload": ["id": target]]
        ], to: sessions.appendingPathComponent("rollout-\(target).jsonl"))

        let files = try TrustedSessionFileResolver.resolve(sessionIDs: [target], under: fixture.root)

        #expect(files.map { $0.fileURL.resolvingSymlinksInPath() } == [valid.resolvingSymlinksInPath()])
        #expect(files.first?.sessionID == target)
    }

    @Test
    func discoveryAcceptsExactMaximumFirstLineAndRejectsMaximumPlusOneAcrossChunks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sessions = fixture.root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let exactID = "11111111-2222-3333-4444-555555555555"
        let oversizedID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        try fixture.writeRollout(
            sessionID: exactID,
            lineBytes: SessionJSONLPolicy.maximumLineBytes,
            to: sessions.appendingPathComponent("exact.jsonl")
        )
        try fixture.writeRollout(
            sessionID: oversizedID,
            lineBytes: SessionJSONLPolicy.maximumLineBytes + 1,
            to: sessions.appendingPathComponent("oversized.jsonl")
        )

        let discovered = try TrustedSessionFileResolver.discover(under: fixture.root)

        #expect(discovered.map(\.sessionID) == [exactID])
    }

    @Test
    func buildsOneTrustedIndexForAnEmployeeScaleSessionCatalog() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sessions = fixture.root.appendingPathComponent("sessions/2026/07", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionCount = 565
        for index in 0..<sessionCount {
            let sessionID = String(format: "session-%03d", index)
            try fixture.write(
                [["type": "session_meta", "payload": ["id": sessionID]]],
                to: sessions.appendingPathComponent("rollout-\(index).jsonl")
            )
        }

        let trustedIndex = try TrustedSessionFileResolver.index(under: fixture.root)

        #expect(trustedIndex.count == sessionCount)
        #expect(trustedIndex.values.allSatisfy { $0.count == 1 })
    }

    @Test
    func rejectsSymlinkedRolloutFilesAndKeepsExternalTargetsOutOfTheResult() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sessions = fixture.root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let target = "11111111-2222-3333-4444-555555555555"
        let outside = fixture.parent.appendingPathComponent("outside-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: outside) }
        try fixture.write([["type": "session_meta", "payload": ["id": target]]], to: outside)
        try FileManager.default.createSymbolicLink(
            at: sessions.appendingPathComponent("linked.jsonl"),
            withDestinationURL: outside
        )

        let files = try TrustedSessionFileResolver.resolve(sessionIDs: [target], under: fixture.root)
        #expect(files.isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test
    func exactValidationRejectsAJsonlOutsideSessionDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let rootLevel = fixture.root.appendingPathComponent("not-a-rollout.jsonl")
        try fixture.write([[
            "type": "session_meta",
            "payload": ["id": "session-a"]
        ]], to: rootLevel)

        #expect(throws: Error.self) {
            try TrustedSessionFileResolver.validate(
                rootLevel,
                expectedSessionID: "session-a",
                under: fixture.root
            )
        }
    }

    @Test
    func missingFileExpectationRejectsAFileCreatedAfterPreflight() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let destination = fixture.root.appendingPathComponent("history.jsonl")
        let expectation = try SessionFileAbsenceExpectation.requireMissing(destination)

        #expect(throws: Never.self) {
            try expectation.validateCurrent()
        }

        try fixture.write([["session_id": "new-session"]], to: destination)
        #expect(throws: SessionJSONLValidationError.self) {
            try expectation.validateCurrent()
        }
    }

    @Test
    func relocatedFingerprintRequiresTheSameFileIdentityAndContent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = fixture.root.appendingPathComponent("sessions/original.jsonl")
        let relocated = fixture.root.appendingPathComponent("sessions/relocated.jsonl")
        let copied = fixture.root.appendingPathComponent("sessions/copied.jsonl")
        try fixture.write([["type": "session_meta", "payload": ["id": "session-a"]]], to: original)
        let fingerprint = try TrustedSessionFileResolver.validate(
            original,
            expectedSessionID: "session-a",
            under: fixture.root
        )

        try FileManager.default.copyItem(at: original, to: copied)
        try FileManager.default.moveItem(at: original, to: relocated)

        #expect(throws: Never.self) {
            try fingerprint.validateRelocated(at: relocated)
        }
        #expect(throws: SessionJSONLValidationError.self) {
            try fingerprint.validateRelocated(at: copied)
        }
    }

    @Test
    func frozenRestoreOutputUsesExactSchemaIdentitiesAndMode() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source-history.jsonl")
        let destination = fixture.root.appendingPathComponent("destination-history.jsonl")
        try fixture.write([
            ["session_id": "target", "text": "selected"],
            ["session_id": "other", "text": "mentions target"]
        ], to: source)
        try fixture.write([
            ["session_id": "other", "text": "existing"]
        ], to: destination)
        let sourceDocument = try SessionJSONLValidator.parse(source, kind: .history)
        let destinationDocument = try SessionJSONLValidator.parse(destination, kind: .history)

        let merged = SessionJSONLRestoreOutput.build(
            source: sourceDocument.records,
            destination: destinationDocument.records,
            sessionIDs: ["target"],
            uniqueBySessionID: false,
            replace: false
        )
        let replaced = SessionJSONLRestoreOutput.build(
            source: sourceDocument.records,
            destination: destinationDocument.records,
            sessionIDs: ["target"],
            uniqueBySessionID: false,
            replace: true
        )

        #expect(String(decoding: merged, as: UTF8.self).contains("existing"))
        #expect(String(decoding: merged, as: UTF8.self).contains("selected"))
        #expect(String(decoding: merged, as: UTF8.self).contains("mentions target") == false)
        #expect(String(decoding: replaced, as: UTF8.self).contains("existing") == false)
        #expect(String(decoding: replaced, as: UTF8.self).contains("selected"))
    }

    private struct Fixture {
        let root: URL
        let parent: URL

        init() throws {
            parent = FileManager.default.temporaryDirectory
            root = parent.appendingPathComponent("session-jsonl-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func write(_ objects: [[String: Any]], to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for object in objects {
                data.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                data.append(0x0A)
            }
            try data.write(to: url)
        }

        func writeRollout(sessionID: String, lineBytes: Int, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let prefix = Data(#"{"payload":{"id":""#.utf8)
            let middle = Data(sessionID.utf8)
            let paddingPrefix = Data(#"","padding":""#.utf8)
            let suffix = Data(#""},"type":"session_meta"}"#.utf8)
            let fixedBytes = prefix.count + middle.count + paddingPrefix.count + suffix.count
            #expect(lineBytes >= fixedBytes)
            var line = Data(capacity: lineBytes + 1)
            line.append(prefix)
            line.append(middle)
            line.append(paddingPrefix)
            line.append(Data(repeating: 0x78, count: lineBytes - fixedBytes))
            line.append(suffix)
            line.append(0x0A)
            try line.write(to: url)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private extension FileHandle {
    func apply(_ operation: (FileHandle) throws -> Void) throws {
        defer { try? close() }
        try operation(self)
    }
}
