import XCTest
@testable import CodexSessionVaultCore

final class BackupPathsTests: XCTestCase {
    func testDefaultLayoutUsesVaultIncrementalBackups() {
        let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
        let paths = BackupPaths(homeDirectory: home)

        XCTAssertEqual(paths.codexRoot.path, "/Users/alice/.codex")
        XCTAssertEqual(paths.backupRoot.path, "/Users/alice/.codex-session-vault/incremental-backups")
        XCTAssertEqual(paths.manifestURL.path, "/Users/alice/.codex-session-vault/incremental-backups/manifest.json")
        XCTAssertEqual(paths.cursorDatabaseURL.path, "/Users/alice/.codex-session-vault/incremental-backups/cursors.sqlite")
        XCTAssertEqual(paths.statusURL.path, "/Users/alice/.codex-session-vault/incremental-backups/status.json")
        XCTAssertEqual(paths.logURL.path, "/Users/alice/.codex-session-vault/incremental-backups/logs/backup-agent.log")
    }

    func testBackupFilePathUsesFirstSeenDateDirectoriesAndSessionIdFileName() {
        let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
        let paths = BackupPaths(homeDirectory: home)
        let date = ISO8601DateFormatter().date(from: "2026-07-04T10:12:00Z")!

        let url = paths.backupFileURL(sessionID: "session-123", firstSeenAt: date)

        XCTAssertEqual(
            url.path,
            "/Users/alice/.codex-session-vault/incremental-backups/sessions/2026/07/04/session-123.jsonl"
        )
    }

    func testRelativeBackupPathIsManifestFriendly() {
        let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
        let paths = BackupPaths(homeDirectory: home)
        let file = URL(fileURLWithPath: "/Users/alice/.codex-session-vault/incremental-backups/sessions/2026/07/04/session-123.jsonl")

        XCTAssertEqual(paths.relativeBackupPath(for: file), "sessions/2026/07/04/session-123.jsonl")
    }
}
