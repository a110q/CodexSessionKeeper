import Foundation
import Testing
@testable import CodexSessionVaultCore

@Test
func sessionIDExtractsStemFromCodexJSONLFile() throws {
    let url = URL(fileURLWithPath: "/Users/alice/.codex/sessions/2026/07/04/session-123.JSONL")

    #expect(SessionIdentity.sessionID(from: url) == "session-123")
}

@Test
func sessionIDExtractsEmbeddedUUIDFromCodexRolloutFilename() {
    let url = URL(
        fileURLWithPath: "/Users/alice/.codex/sessions/rollout-0197A4B0-8B8F-7C20-A9D1-2F3C8A9E12AB-2026.jsonl"
    )

    #expect(SessionIdentity.sessionID(from: url) == "0197a4b0-8b8f-7c20-a9d1-2f3c8a9e12ab")
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
func titleExtractsPayloadMessageFromTopLevelUserMessageEvent() {
    let line = #"{"type":"user_message","payload":{"message":"  Plan\nbackup work  "}}"#

    #expect(SessionIdentity.title(fromJSONLine: line) == "Plan backup work")
}

@Test
func titleExtractsPayloadContentWhenPayloadTypeIsUserMessage() {
    let line = #"{"type":"event","payload":{"type":"user_message","content":[{"text":"First part"},{"text":"Second part"}]}}"#

    #expect(SessionIdentity.title(fromJSONLine: line) == "First part Second part")
}

@Test
func titleExtractsPayloadContentWhenPayloadRoleIsUser() {
    let line = #"{"type":"response","payload":{"role":"user","content":[{"text":"Payload role text"}]}}"#

    #expect(SessionIdentity.title(fromJSONLine: line) == "Payload role text")
}

@Test
func titleJoinsAndCollapsesMultipartContentText() {
    let line = #"{"role":"user","content":[{"text":"  First\npart  "},{"text":"Second\t\tpart"},{"text":"   "}]} "#

    #expect(SessionIdentity.title(fromJSONLine: line) == "First part Second part")
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
func titlePreservesEscapedUserRoleFallback() {
    let escapedUserRole = #"{"role":"\u0075ser","content":"Escaped role"}"#

    #expect(SessionIdentity.title(fromJSONLine: escapedUserRole) == "Escaped role")
}

@Test
func titleTruncatesNormalizedTextTo80Characters() throws {
    let longText = String(repeating: "a", count: 100)
    let line = #"{"role":"user","content":""# + longText + #""}"#

    let title = try #require(SessionIdentity.title(fromJSONLine: line))

    #expect(title.count == 80)
    #expect(title == String(repeating: "a", count: 80))
}
