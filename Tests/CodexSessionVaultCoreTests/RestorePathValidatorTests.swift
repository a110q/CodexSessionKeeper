import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite("RestorePathValidator")
struct RestorePathValidatorTests {
    private let sourceRoot = URL(fileURLWithPath: "/vault/snapshots/snapshot-1/data", isDirectory: true)
    private let destinationRoot = URL(fileURLWithPath: "/Users/alice/.codex", isDirectory: true)

    @Test
    func acceptsTopLevelAndNestedRelativePaths() throws {
        let paths = try RestorePathValidator.validate(
            ["state_5.sqlite", "sessions/recovered/session-1.jsonl"],
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot
        )

        #expect(paths.map(\.relativePath) == [
            "state_5.sqlite",
            "sessions/recovered/session-1.jsonl"
        ])
        #expect(paths[0].sourceURL.path == "/vault/snapshots/snapshot-1/data/state_5.sqlite")
        #expect(paths[1].destinationURL.path == "/Users/alice/.codex/sessions/recovered/session-1.jsonl")
    }

    @Test(arguments: [
        "",
        ".",
        "sessions/./session-1.jsonl",
        "sessions//session-1.jsonl",
        "../../outside.txt",
        "sessions/../../../outside.txt",
        #"sessions\..\..\outside.txt"#,
        "/tmp/outside.txt",
        #"C:\Users\Ada\outside.txt"#,
        #"C:outside.txt"#,
        #"\\server\share\outside.txt"#,
        "sessions/\0outside.txt"
    ])
    func rejectsUnsafePaths(relativePath: String) {
        #expect(throws: RestorePathValidationError.self) {
            try RestorePathValidator.validate(
                [relativePath],
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot
            )
        }
    }

    @Test
    func rejectsTheWholeListWhenOnePathIsUnsafe() {
        #expect(throws: RestorePathValidationError.self) {
            try RestorePathValidator.validate(
                ["sessions", "../../outside.txt", "history.jsonl"],
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot
            )
        }
    }
}
