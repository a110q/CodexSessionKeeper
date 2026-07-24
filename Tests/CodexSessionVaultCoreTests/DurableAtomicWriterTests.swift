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

    @Test
    func streamingWriteIfAbsentPreservesDestinationCreatedDuringStaging() throws {
        let root = makeDurableWriterTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("session.jsonl")

        #expect(throws: (any Error).self) {
            try DurableAtomicWriter().writeIfAbsent(at: destination) { handle in
                try handle.write(contentsOf: Data("backup".utf8))
                try Data("live".utf8).write(to: destination)
            }
        }

        #expect(try String(contentsOf: destination, encoding: .utf8) == "live")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["session.jsonl"])
    }

    @Test
    func privateWriteCreatesPrivateParentAndFile() throws {
        let root = makeDurableWriterTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("private/status.json")

        try DurableAtomicWriter().write(
            Data("{}".utf8),
            to: destination,
            permissions: 0o600,
            parentDirectoryPermissions: 0o700,
            createParentDirectories: true
        )

        #expect(try posixMode(destination) == 0o600)
        #expect(try posixMode(destination.deletingLastPathComponent()) == 0o700)
    }

    @Test
    func temporaryFileIsPrivateBeforeWriterReceivesItsHandle() throws {
        let root = makeDurableWriterTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("private/status.json")
        var observedTemporaryMode: Int?

        try DurableAtomicWriter().replace(
            at: destination,
            permissions: 0o600,
            parentDirectoryPermissions: 0o700,
            createParentDirectories: true
        ) { handle in
            let parent = destination.deletingLastPathComponent()
            let temporary = try #require(
                FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix(".status.json.tmp-") }
            )
            observedTemporaryMode = try posixMode(temporary)
            try handle.write(contentsOf: Data("{}".utf8))
        }

        #expect(observedTemporaryMode == 0o600)
        #expect(try posixMode(destination) == 0o600)
    }

    @Test
    func defaultRemoteWriteDoesNotChangeExistingParentPermissions() throws {
        let root = makeDurableWriterTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let remoteParent = root.appendingPathComponent("mounted-nas", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteParent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: remoteParent.path)

        try DurableAtomicWriter().write(Data("{}".utf8), to: remoteParent.appendingPathComponent("status.json"))

        #expect(try posixMode(remoteParent) == 0o755)
    }
}

private enum DurableAtomicWriterTestError: Error, Equatable {
    case injectedSyncFailure
}

private func makeDurableWriterTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DurableAtomicWriterTests-\(UUID().uuidString)", isDirectory: true)
}

private func posixMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
}
