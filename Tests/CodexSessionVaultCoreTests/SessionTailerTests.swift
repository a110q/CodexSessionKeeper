import Foundation
import Testing
@testable import CodexSessionVaultCore

@Test
func tailerReadsCompleteLinesFromStartAndKeepsPendingPartialLine() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let fileURL = tempDirectory.appendingPathComponent("session.jsonl")
    try Data("first\n\nsecond\npartial".utf8).write(to: fileURL)
    let tailer = SessionTailer()

    let result = try tailer.readNewCompleteLines(from: fileURL, offset: 0)

    #expect(result.lines == [
        Data("first".utf8),
        Data(),
        Data("second".utf8)
    ])
    #expect(result.nextOffset == Int64(Data("first\n\nsecond\n".utf8).count))
    #expect(result.pendingPartialLine == Data("partial".utf8))
}

@Test
func tailerReadsFromExistingOffset() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let fileURL = tempDirectory.appendingPathComponent("session.jsonl")
    try Data("first\nsecond\nthird".utf8).write(to: fileURL)
    let tailer = SessionTailer()
    let offset = Int64(Data("first\n".utf8).count)

    let result = try tailer.readNewCompleteLines(from: fileURL, offset: offset)

    #expect(result.lines == [Data("second".utf8)])
    #expect(result.nextOffset == offset + Int64(Data("second\n".utf8).count))
    #expect(result.pendingPartialLine == Data("third".utf8))
}

@Test
func tailerRestartsAtZeroWhenOffsetIsBeyondCurrentFileSize() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let fileURL = tempDirectory.appendingPathComponent("session.jsonl")
    try Data("fresh\npartial".utf8).write(to: fileURL)
    let tailer = SessionTailer()

    let result = try tailer.readNewCompleteLines(from: fileURL, offset: 10_000)

    #expect(result.lines == [Data("fresh".utf8)])
    #expect(result.nextOffset == Int64(Data("fresh\n".utf8).count))
    #expect(result.pendingPartialLine == Data("partial".utf8))
}

@Test
func tailerDoesNotAdvanceOffsetWhenNoCompleteNewlineExists() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let fileURL = tempDirectory.appendingPathComponent("session.jsonl")
    try Data("partial only".utf8).write(to: fileURL)
    let tailer = SessionTailer()

    let result = try tailer.readNewCompleteLines(from: fileURL, offset: 0)

    #expect(result.lines.isEmpty)
    #expect(result.nextOffset == 0)
    #expect(result.pendingPartialLine == Data("partial only".utf8))
}

@Test
func tailerReturnsCurrentOffsetWhenThereIsNoNewData() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let fileURL = tempDirectory.appendingPathComponent("session.jsonl")
    try Data("complete\n".utf8).write(to: fileURL)
    let tailer = SessionTailer()
    let offset = Int64(Data("complete\n".utf8).count)

    let result = try tailer.readNewCompleteLines(from: fileURL, offset: offset)

    #expect(result.lines.isEmpty)
    #expect(result.nextOffset == offset)
    #expect(result.pendingPartialLine.isEmpty)
}

@Test
func tailerReadsAcrossChunksUntilCompleteLinesAreExhausted() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let fileURL = tempDirectory.appendingPathComponent("session.jsonl")
    try Data("first\nsecond\n".utf8).write(to: fileURL)
    let tailer = SessionTailer(maxReadBytes: 8)

    let result = try tailer.readNewCompleteLines(from: fileURL, offset: 0)

    #expect(result.lines == [Data("first".utf8), Data("second".utf8)])
    #expect(result.nextOffset == Int64(Data("first\nsecond\n".utf8).count))
    #expect(result.pendingPartialLine.isEmpty)
    #expect(result.blockedError == nil)
}

@Test
func tailerReadsCompleteLineWhenNewlineIsBeyondOneChunk() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let fileURL = tempDirectory.appendingPathComponent("session.jsonl")
    let longLine = "abcdefghij"
    try Data("\(longLine)\nnext\npartial".utf8).write(to: fileURL)
    let tailer = SessionTailer(maxReadBytes: 4)

    let result = try tailer.readNewCompleteLines(from: fileURL, offset: 0)

    #expect(result.lines == [Data(longLine.utf8), Data("next".utf8)])
    #expect(result.nextOffset == Int64(Data("\(longLine)\nnext\n".utf8).count))
    #expect(result.pendingPartialLine == Data("partial".utf8))
    #expect(result.blockedError == nil)
}

@Test
func tailerReportsBlockedErrorWhenLineExceedsMaximumLineBytes() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let fileURL = tempDirectory.appendingPathComponent("session.jsonl")
    try Data("123456789\nnext\n".utf8).write(to: fileURL)
    let tailer = SessionTailer(maxReadBytes: 4, maxLineBytes: 8)

    let result = try tailer.readNewCompleteLines(from: fileURL, offset: 0)

    #expect(result.lines.isEmpty)
    #expect(result.nextOffset == 0)
    #expect(result.pendingPartialLine.isEmpty)
    #expect(result.blockedError?.contains("exceeds maximum JSONL line size") == true)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexSessionVaultCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
