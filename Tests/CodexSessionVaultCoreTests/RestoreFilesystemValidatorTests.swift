import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite("RestoreFilesystemValidator")
struct RestoreFilesystemValidatorTests {
    @Test
    func acceptsRegularSourceTreesAndDestinations() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.sourceRoot.appendingPathComponent("sessions", isDirectory: true)
        let destination = fixture.destinationRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: source.appendingPathComponent("session.jsonl"))

        #expect(throws: Never.self) {
            try RestoreFilesystemValidator.validate(
                [ValidatedRestorePath(relativePath: "sessions", sourceURL: source, destinationURL: destination)],
                sourceRoot: fixture.sourceRoot,
                destinationRoot: fixture.destinationRoot
            )
        }
    }

    @Test
    func rejectsSourceFileAndDirectorySymlinks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let outsideDirectory = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideFile = outsideDirectory.appendingPathComponent("secret.jsonl")
        try Data("secret\n".utf8).write(to: outsideFile)

        for (name, target) in [("file-link.jsonl", outsideFile), ("directory-link", outsideDirectory)] {
            let source = fixture.sourceRoot.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
            #expect(throws: RestoreFilesystemValidationError.self) {
                try RestoreFilesystemValidator.validate(
                    [ValidatedRestorePath(
                        relativePath: name,
                        sourceURL: source,
                        destinationURL: fixture.destinationRoot.appendingPathComponent(name)
                    )],
                    sourceRoot: fixture.sourceRoot,
                    destinationRoot: fixture.destinationRoot
                )
            }
        }
    }

    @Test
    func rejectsContainedAndDanglingSourceSymlinks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let containedTarget = fixture.sourceRoot.appendingPathComponent("target.jsonl")
        try Data("target\n".utf8).write(to: containedTarget)

        for (name, target) in [
            ("contained-link.jsonl", containedTarget),
            ("dangling-link.jsonl", fixture.sourceRoot.appendingPathComponent("missing.jsonl"))
        ] {
            let source = fixture.sourceRoot.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
            #expect(throws: RestoreFilesystemValidationError.self) {
                try RestoreFilesystemValidator.validate(
                    [ValidatedRestorePath(
                        relativePath: name,
                        sourceURL: source,
                        destinationURL: fixture.destinationRoot.appendingPathComponent(name)
                    )],
                    sourceRoot: fixture.sourceRoot,
                    destinationRoot: fixture.destinationRoot
                )
            }
        }
    }

    @Test
    func rejectsSymbolicLinkTrustRoots() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let linkedSourceRoot = fixture.root.appendingPathComponent("linked-source", isDirectory: true)
        let linkedDestinationRoot = fixture.root.appendingPathComponent("linked-destination", isDirectory: true)
        try Data("{}\n".utf8).write(to: fixture.sourceRoot.appendingPathComponent("session.jsonl"))
        try FileManager.default.createSymbolicLink(at: linkedSourceRoot, withDestinationURL: fixture.sourceRoot)
        try FileManager.default.createSymbolicLink(at: linkedDestinationRoot, withDestinationURL: fixture.destinationRoot)

        #expect(throws: RestoreFilesystemValidationError.self) {
            try RestoreFilesystemValidator.validate(
                [ValidatedRestorePath(
                    relativePath: "session.jsonl",
                    sourceURL: linkedSourceRoot.appendingPathComponent("session.jsonl"),
                    destinationURL: fixture.destinationRoot.appendingPathComponent("session.jsonl")
                )],
                sourceRoot: linkedSourceRoot,
                destinationRoot: fixture.destinationRoot
            )
        }

        #expect(throws: RestoreFilesystemValidationError.self) {
            try RestoreFilesystemValidator.validate(
                [ValidatedRestorePath(
                    relativePath: "session.jsonl",
                    sourceURL: fixture.sourceRoot.appendingPathComponent("session.jsonl"),
                    destinationURL: linkedDestinationRoot.appendingPathComponent("session.jsonl")
                )],
                sourceRoot: fixture.sourceRoot,
                destinationRoot: linkedDestinationRoot
            )
        }
    }

    @Test
    func rejectsDestinationDirectorySymlinks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.sourceRoot.appendingPathComponent("sessions", isDirectory: true)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let destination = fixture.destinationRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)

        #expect(throws: RestoreFilesystemValidationError.self) {
            try RestoreFilesystemValidator.validate(
                [ValidatedRestorePath(relativePath: "sessions", sourceURL: source, destinationURL: destination)],
                sourceRoot: fixture.sourceRoot,
                destinationRoot: fixture.destinationRoot
            )
        }
    }

    private struct Fixture {
        let root: URL
        let sourceRoot: URL
        let destinationRoot: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("restore-filesystem-\(UUID().uuidString)", isDirectory: true)
            sourceRoot = root.appendingPathComponent("snapshot/data", isDirectory: true)
            destinationRoot = root.appendingPathComponent("codex", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
