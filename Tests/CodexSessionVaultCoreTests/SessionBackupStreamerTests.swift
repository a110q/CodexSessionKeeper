import CryptoKit
import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct SessionBackupStreamerTests {
    private let chunkSize = 1_048_576

    @Test
    func rebuildStreamsFileLargerThanThreeChunks() throws {
        var sourceData = Data(repeating: 0x61, count: chunkSize * 3 + 17)
        sourceData.append(0x0A)
        sourceData.append(Data("two\npartial".utf8))
        let fixture = try StreamerFixture(source: sourceData, chunkSize: chunkSize)
        defer { fixture.cleanup() }

        let result = try fixture.streamer.rebuildCompleteLines(
            source: fixture.source,
            through: nil,
            destination: fixture.target
        )

        let expected = sourceData.prefix(sourceData.count - Data("partial".utf8).count)
        #expect(try Data(contentsOf: fixture.target) == expected)
        #expect(result.committedByteCount == Int64(expected.count))
        #expect(result.lineCount == 2)
        #expect(result.contentHash == sha256Hex(Data(expected)))
    }

    @Test
    func rebuildAcceptsLegalThirtyTwoMiBLineAcrossChunks() throws {
        var sourceData = Data(repeating: 0x78, count: SessionTailer.defaultMaxLineBytes)
        sourceData.append(0x0A)
        let fixture = try StreamerFixture(source: sourceData, chunkSize: chunkSize)
        defer { fixture.cleanup() }

        let result = try fixture.streamer.rebuildCompleteLines(
            source: fixture.source,
            through: nil,
            destination: fixture.target
        )

        #expect(try Data(contentsOf: fixture.target) == sourceData)
        #expect(result.committedByteCount == Int64(sourceData.count))
        #expect(result.lineCount == 1)
        #expect(result.contentHash == sha256Hex(sourceData))
    }

    @Test
    func rebuildStreamsOnlyCompleteLines() throws {
        let fixture = try StreamerFixture(source: Data("one\ntwo\npartial".utf8), chunkSize: chunkSize)
        defer { fixture.cleanup() }

        let result = try fixture.streamer.rebuildCompleteLines(
            source: fixture.source,
            through: nil,
            destination: fixture.target
        )

        let expected = Data("one\ntwo\n".utf8)
        #expect(try Data(contentsOf: fixture.target) == expected)
        #expect(result.committedByteCount == 8)
        #expect(result.lineCount == 2)
        #expect(result.contentHash == sha256Hex(expected))
    }

    @Test
    func rebuildStopsAtMaximumOffsetWithoutCommittingPartialRecord() throws {
        let fixture = try StreamerFixture(source: Data("one\ntwo\nthree\n".utf8), chunkSize: chunkSize)
        defer { fixture.cleanup() }

        let result = try fixture.streamer.rebuildCompleteLines(
            source: fixture.source,
            through: 6,
            destination: fixture.target
        )

        let expected = Data("one\n".utf8)
        #expect(try Data(contentsOf: fixture.target) == expected)
        #expect(result.committedByteCount == 4)
        #expect(result.lineCount == 1)
        #expect(result.contentHash == sha256Hex(expected))
    }

    @Test
    func rebuildEmptyFileCreatesEmptyDestinationAndHash() throws {
        let fixture = try StreamerFixture(source: Data(), chunkSize: chunkSize)
        defer { fixture.cleanup() }

        let result = try fixture.streamer.rebuildCompleteLines(
            source: fixture.source,
            through: nil,
            destination: fixture.target
        )

        #expect(try Data(contentsOf: fixture.target).isEmpty)
        #expect(result.committedByteCount == 0)
        #expect(result.lineCount == 0)
        #expect(result.contentHash == sha256Hex(Data()))
    }

    @Test
    func rangesMatchComparesOnlyRequestedRanges() throws {
        let fixture = try StreamerFixture(source: Data("prefix-SAME-suffix".utf8), chunkSize: chunkSize)
        defer { fixture.cleanup() }
        try Data("other-SAME-tail".utf8).write(to: fixture.target)

        #expect(try fixture.streamer.rangesMatch(
            source: fixture.source,
            sourceOffset: 7,
            target: fixture.target,
            targetOffset: 6,
            length: 4
        ))
        #expect(try !fixture.streamer.rangesMatch(
            source: fixture.source,
            sourceOffset: 0,
            target: fixture.target,
            targetOffset: 0,
            length: 6
        ))
    }

    @Test
    func failedStreamingReplacementPreservesExistingDestination() throws {
        let fixture = try StreamerFixture(source: Data(), chunkSize: chunkSize)
        defer { fixture.cleanup() }
        try Data("committed".utf8).write(to: fixture.target)

        #expect(throws: StreamerTestError.injectedWriteFailure) {
            try DurableAtomicWriter().replace(at: fixture.target) { handle in
                try handle.write(contentsOf: Data("uncommitted".utf8))
                throw StreamerTestError.injectedWriteFailure
            }
        }

        #expect(try String(contentsOf: fixture.target, encoding: .utf8) == "committed")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == ["source.jsonl", "target.jsonl"])
    }
}

private enum StreamerTestError: Error, Equatable {
    case injectedWriteFailure
}

private struct StreamerFixture {
    let root: URL
    let source: URL
    let target: URL
    let streamer: SessionBackupStreamer

    init(source data: Data, chunkSize: Int) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionBackupStreamerTests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source.jsonl")
        target = root.appendingPathComponent("target.jsonl")
        streamer = SessionBackupStreamer(chunkSize: chunkSize)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: source)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
