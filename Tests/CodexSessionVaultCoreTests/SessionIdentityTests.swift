import Foundation
import Testing
@testable import CodexSessionVaultCore

@Test
func sessionIDExtractsStemFromCodexJSONLFile() throws {
    let url = URL(fileURLWithPath: "/Users/alice/.codex/sessions/2026/07/04/session-123.JSONL")

    #expect(SessionIdentity.sessionID(from: url) == "session-123")
}

@Test
func sessionIDReturnsNilForNonJSONLFiles() {
    let url = URL(fileURLWithPath: "/Users/alice/.codex/sessions/session-123.txt")

    #expect(SessionIdentity.sessionID(from: url) == nil)
}

@Test
func sessionIDReturnsNilForEmptyStems() {
    let url = URL(fileURLWithPath: "/Users/alice/.codex/sessions/.jsonl")

    #expect(SessionIdentity.sessionID(from: url) == nil)
}

@Test
func titleExtractsInputTextFromContentArrayUserMessage() {
    let line = """
    {"type":"message","role":"user","content":[{"type":"input_text","text":"  Plan the backup work\\n"}]}
    """

    #expect(SessionIdentity.title(fromJSONLine: line) == "Plan the backup work")
}

@Test
func titleExtractsStringContentFromUserMessage() {
    let line = #"{"role":"user","content":"Review yesterday's session"}"#

    #expect(SessionIdentity.title(fromJSONLine: line) == "Review yesterday's session")
}

@Test
func titleExtractsTextFromNestedItemUserMessage() {
    let line = #"{"item":{"role":"user","content":[{"text":"Name the manifest format"}]}}"#

    #expect(SessionIdentity.title(fromJSONLine: line) == "Name the manifest format")
}

@Test
func titleReturnsNilForAssistantRoleInvalidJSONAndWhitespaceOnlyText() {
    let assistantLine = #"{"role":"assistant","content":"Nope"}"#
    let invalidJSON = #"{"role":"user","content":"unfinished""#
    let whitespaceOnly = #"{"role":"user","content":[{"text":"   \n\t  "}]} "#

    #expect(SessionIdentity.title(fromJSONLine: assistantLine) == nil)
    #expect(SessionIdentity.title(fromJSONLine: invalidJSON) == nil)
    #expect(SessionIdentity.title(fromJSONLine: whitespaceOnly) == nil)
}

@Test
func titleTruncatesNormalizedTextTo80Characters() throws {
    let longText = String(repeating: "a", count: 100)
    let line = #"{"role":"user","content":""# + longText + #""}"#

    let title = try #require(SessionIdentity.title(fromJSONLine: line))

    #expect(title.count == 80)
    #expect(title == String(repeating: "a", count: 80))
}
