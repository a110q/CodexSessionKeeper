import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct LocalVaultPermissionHardenerTests {
    @Test
    func prepareVaultMigratesExistingDirectoriesAndFilesAndPublishesPrivateMarker() throws {
        let fixture = try LocalVaultPermissionFixture()
        defer { fixture.cleanup() }
        let nestedDirectory = fixture.root.appendingPathComponent("snapshots/old/data", isDirectory: true)
        let nestedFile = nestedDirectory.appendingPathComponent("session.jsonl")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: nestedFile)
        try fixture.setMode(0o755, at: fixture.root)
        try fixture.setMode(0o755, at: nestedDirectory)
        try fixture.setMode(0o644, at: nestedFile)

        try LocalVaultPermissionHardener().prepareVault(at: fixture.root)

        #expect(try fixture.mode(of: fixture.root) == 0o700)
        #expect(try fixture.mode(of: nestedDirectory) == 0o700)
        #expect(try fixture.mode(of: nestedFile) == 0o600)
        #expect(try fixture.mode(of: fixture.markerURL) == 0o600)
    }

    @Test
    func prepareVaultCreatesMissingRootWithPrivatePermissions() throws {
        let fixture = try LocalVaultPermissionFixture(createRoot: false)
        defer { fixture.cleanup() }

        try LocalVaultPermissionHardener().prepareVault(at: fixture.root)

        #expect(try fixture.mode(of: fixture.root) == 0o700)
        #expect(try fixture.mode(of: fixture.markerURL) == 0o600)
    }

    @Test
    func damagedMarkerForcesHistoricalTreeMigration() throws {
        let fixture = try LocalVaultPermissionFixture()
        defer { fixture.cleanup() }
        let history = fixture.root.appendingPathComponent("snapshots/old.json")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: history)
        try LocalVaultPermissionHardener().prepareVault(at: fixture.root)
        try fixture.setMode(0o644, at: history)
        try Data("damaged".utf8).write(to: fixture.markerURL)

        try LocalVaultPermissionHardener().prepareVault(at: fixture.root)

        #expect(try fixture.mode(of: history) == 0o600)
        #expect(try fixture.mode(of: fixture.markerURL) == 0o600)
    }

    @Test
    func rootPermissionDriftForcesHistoricalTreeMigration() throws {
        let fixture = try LocalVaultPermissionFixture()
        defer { fixture.cleanup() }
        let history = fixture.root.appendingPathComponent("snapshots/old.json")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: history)
        try LocalVaultPermissionHardener().prepareVault(at: fixture.root)
        try fixture.setMode(0o644, at: history)
        try fixture.setMode(0o755, at: fixture.root)

        try LocalVaultPermissionHardener().prepareVault(at: fixture.root)

        #expect(try fixture.mode(of: fixture.root) == 0o700)
        #expect(try fixture.mode(of: history) == 0o600)
    }

    @Test
    func validMarkerAndPrivateRootSkipHistoricalRescan() throws {
        let fixture = try LocalVaultPermissionFixture()
        defer { fixture.cleanup() }
        let history = fixture.root.appendingPathComponent("snapshots/old.json")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: history)
        try LocalVaultPermissionHardener().prepareVault(at: fixture.root)
        try fixture.setMode(0o644, at: history)

        try LocalVaultPermissionHardener().prepareVault(at: fixture.root)

        #expect(try fixture.mode(of: history) == 0o644)
    }

    @Test
    func prepareVaultRejectsRootSymlink() throws {
        let fixture = try LocalVaultPermissionFixture(createRoot: false)
        defer { fixture.cleanup() }
        let realRoot = fixture.container.appendingPathComponent("real-vault", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: realRoot)

        #expect(throws: (any Error).self) {
            try LocalVaultPermissionHardener().prepareVault(at: fixture.root)
        }
    }

    @Test
    func prepareVaultRejectsRootThatIsARegularFile() throws {
        let fixture = try LocalVaultPermissionFixture(createRoot: false)
        defer { fixture.cleanup() }
        try Data("not-a-directory".utf8).write(to: fixture.root)

        #expect(throws: LocalVaultPermissionHardeningError.rootIsNotDirectory(fixture.root.path)) {
            try LocalVaultPermissionHardener().prepareVault(at: fixture.root)
        }
    }

    @Test
    func nestedSymlinkIsNotFollowedAndExternalTargetModeIsUnchanged() throws {
        let fixture = try LocalVaultPermissionFixture()
        defer { fixture.cleanup() }
        let outside = fixture.container.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try fixture.setMode(0o644, at: outside)
        let link = fixture.root.appendingPathComponent("snapshots/external-link")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        try LocalVaultPermissionHardener().prepareVault(at: fixture.root)

        #expect(try fixture.mode(of: outside) == 0o644)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
    }

    @Test
    func chmodFailureLeavesMigrationMarkerAbsent() throws {
        let fixture = try LocalVaultPermissionFixture()
        defer { fixture.cleanup() }
        let blockedFile = fixture.root.appendingPathComponent("blocked.json")
        try Data("blocked".utf8).write(to: blockedFile)
        let hardener = LocalVaultPermissionHardener(setPermissions: { url, permissions in
            if url.standardizedFileURL == blockedFile.standardizedFileURL {
                throw LocalVaultPermissionTestError.injectedChmodFailure
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        })

        #expect(throws: LocalVaultPermissionTestError.injectedChmodFailure) {
            try hardener.prepareVault(at: fixture.root)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.markerURL.path) == false)
    }

    @Test
    func failedRemigrationRemovesPreviouslyValidMarker() throws {
        let fixture = try LocalVaultPermissionFixture()
        defer { fixture.cleanup() }
        let blockedFile = fixture.root.appendingPathComponent("blocked.json")
        try Data("blocked".utf8).write(to: blockedFile)
        try LocalVaultPermissionHardener().prepareVault(at: fixture.root)
        try fixture.setMode(0o755, at: fixture.root)
        let hardener = LocalVaultPermissionHardener(setPermissions: { url, permissions in
            if url.standardizedFileURL == blockedFile.standardizedFileURL {
                throw LocalVaultPermissionTestError.injectedChmodFailure
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        })

        #expect(throws: LocalVaultPermissionTestError.injectedChmodFailure) {
            try hardener.prepareVault(at: fixture.root)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.markerURL.path) == false)
    }

    @Test
    func rootPermissionChmodFailureRemovesPreviouslyValidMarker() throws {
        let fixture = try LocalVaultPermissionFixture()
        defer { fixture.cleanup() }
        try LocalVaultPermissionHardener().prepareVault(at: fixture.root)
        try fixture.setMode(0o755, at: fixture.root)
        let hardener = LocalVaultPermissionHardener(setPermissions: { url, permissions in
            if url.standardizedFileURL == fixture.root.standardizedFileURL {
                throw LocalVaultPermissionTestError.injectedChmodFailure
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        })

        #expect(throws: LocalVaultPermissionTestError.injectedChmodFailure) {
            try hardener.prepareVault(at: fixture.root)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.markerURL.path) == false)
    }

    @Test
    func hardenTreeAppliesPrivateModesWithoutPublishingVaultMarker() throws {
        let fixture = try LocalVaultPermissionFixture()
        defer { fixture.cleanup() }
        let snapshot = fixture.root.appendingPathComponent("snapshots/new", isDirectory: true)
        let data = snapshot.appendingPathComponent("data/session.jsonl")
        try FileManager.default.createDirectory(at: data.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("snapshot".utf8).write(to: data)

        try LocalVaultPermissionHardener().hardenTree(at: snapshot)

        #expect(try fixture.mode(of: snapshot) == 0o700)
        #expect(try fixture.mode(of: data.deletingLastPathComponent()) == 0o700)
        #expect(try fixture.mode(of: data) == 0o600)
        #expect(FileManager.default.fileExists(atPath: fixture.markerURL.path) == false)
    }
}

private enum LocalVaultPermissionTestError: Error, Equatable {
    case injectedChmodFailure
}

private final class LocalVaultPermissionFixture {
    let container: URL
    let root: URL

    var markerURL: URL {
        root.appendingPathComponent(".local-permissions-v1")
    }

    init(createRoot: Bool = true) throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalVaultPermissionHardenerTests-\(UUID().uuidString)", isDirectory: true)
        root = container.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        if createRoot {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: container)
    }

    func setMode(_ mode: NSNumber, at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
    }
}
