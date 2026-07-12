import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct DurableAtomicWriterTests {
    @Test
    func writesAndAtomicallyReplacesDestination() throws {
        let root = makeDurableWriterTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("nested/manifest.json")
        let writer = DurableAtomicWriter()

        try writer.write(Data("first".utf8), to: destination, createParentDirectories: true)
        try writer.write(Data("second".utf8), to: destination, createParentDirectories: true)

        #expect(try String(contentsOf: destination, encoding: .utf8) == "second")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["manifest.json"])
    }

    @Test
    func synchronizeFailurePreservesExistingDestinationAndCleansTemporaryFile() throws {
        let root = makeDurableWriterTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("manifest.json")
        try Data("committed".utf8).write(to: destination)
        let writer = DurableAtomicWriter(synchronize: { _ in
            throw DurableAtomicWriterTestError.injectedSyncFailure
        })

        #expect(throws: DurableAtomicWriterTestError.injectedSyncFailure) {
            try writer.write(Data("uncommitted".utf8), to: destination)
        }

        #expect(try String(contentsOf: destination, encoding: .utf8) == "committed")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["manifest.json"])
    }

    @Test
    func remoteModeDoesNotCreateMissingParents() throws {
        let root = makeDurableWriterTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingParent = root.appendingPathComponent("missing/remote", isDirectory: true)
        let destination = missingParent.appendingPathComponent("status.json")

        do {
            try DurableAtomicWriter().write(
                Data("{}".utf8),
                to: destination,
                createParentDirectories: false
            )
            Issue.record("Expected missing remote parent to be rejected")
        } catch {}

        #expect(FileManager.default.fileExists(atPath: missingParent.path) == false)
    }

    @Test
    func writeIfAbsentNeverReplacesExistingDestination() throws {
        let root = makeDurableWriterTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("session.jsonl")
        try Data("live".utf8).write(to: destination)

        #expect(throws: (any Error).self) {
            try DurableAtomicWriter().writeIfAbsent(Data("backup".utf8), to: destination)
        }

        #expect(try String(contentsOf: destination, encoding: .utf8) == "live")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["session.jsonl"])
    }
}

private enum DurableAtomicWriterTestError: Error, Equatable {
    case injectedSyncFailure
}

private func makeDurableWriterTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DurableAtomicWriterTests-\(UUID().uuidString)", isDirectory: true)
}
