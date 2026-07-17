import CryptoKit
import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct BackupVerificationTests {
    @Test
    func storeRoundTripsVerificationDocument() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("verification.json")
        let verifiedAt = Date(timeIntervalSince1970: 1_784_044_800)
        let record = BackupSessionVerification(
            backupPath: "sessions/2026/07/session.jsonl",
            byteCount: 12,
            lineCount: 2,
            chunkHashes: [sha256(Data("first\nsecond\n".utf8))],
            verifiedAt: verifiedAt
        )
        let document = BackupVerificationDocument(sessions: ["session": record])
        let store = BackupVerificationStore(fileURL: fileURL)

        try store.save(document)

        #expect(try store.load() == document)
    }

    @Test
    func missingStoreLoadsEmptyVersionedDocument() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackupVerificationStore(fileURL: root.appendingPathComponent("verification.json"))

        #expect(try store.load() == BackupVerificationDocument())
    }

    @Test
    func fullVerificationChecksJSONLAndFixedChunks() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("session.jsonl")
        let data = Data("{\"a\":1}\n{\"b\":2}\n".utf8)
        try data.write(to: fileURL)
        let verifier = BackupFileVerifier(chunkSize: 8, maxLineBytes: 64)

        let result = try verifier.verifyFull(
            fileURL,
            expectedByteCount: Int64(data.count),
            expectedLineCount: 2,
            expectedContentHash: sha256(data)
        )

        #expect(result.byteCount == Int64(data.count))
        #expect(result.lineCount == 2)
        #expect(result.contentHash == sha256(data))
        #expect(result.chunkHashes == [sha256(data.subdata(in: 0..<8)), sha256(data.subdata(in: 8..<16))])
    }

    @Test
    func fullVerificationRejectsSameSizeCorruptionAndInvalidJSONL() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("session.jsonl")
        let valid = Data("{\"a\":1}\n".utf8)
        try Data("{\"a\":2}\n".utf8).write(to: fileURL)
        let verifier = BackupFileVerifier(chunkSize: 4, maxLineBytes: 64)

        #expect(throws: BackupFileVerificationError.self) {
            try verifier.verifyFull(
                fileURL,
                expectedByteCount: Int64(valid.count),
                expectedLineCount: 1,
                expectedContentHash: sha256(valid)
            )
        }

        try Data("{not-json}\n".utf8).write(to: fileURL)
        #expect(throws: BackupFileVerificationError.self) {
            try verifier.verifyFull(fileURL)
        }

        try Data("{\"a\":1}".utf8).write(to: fileURL)
        #expect(throws: BackupFileVerificationError.self) {
            try verifier.verifyFull(fileURL)
        }
    }

    @Test
    func changedChunkVerificationRehashesOnlyAffectedChunkWindow() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.jsonl")
        let target = root.appendingPathComponent("target.jsonl")
        let original = Data("{\"a\":1}\n".utf8)
        let appended = Data("{\"b\":2}\n".utf8)
        let complete = original + appended
        try complete.write(to: source)
        try complete.write(to: target)
        let verifier = BackupFileVerifier(chunkSize: 8, maxLineBytes: 64)
        let previous = BackupSessionVerification(
            backupPath: "sessions/session.jsonl",
            byteCount: Int64(original.count),
            lineCount: 1,
            chunkHashes: [sha256(original.prefix(8))],
            verifiedAt: Date(timeIntervalSince1970: 1)
        )

        let updated = try verifier.verifyChangedChunks(
            source: source,
            target: target,
            previous: previous,
            backupPath: previous.backupPath,
            committedByteCount: Int64(complete.count),
            lineCount: 2,
            verifiedAt: Date(timeIntervalSince1970: 2)
        )

        #expect(updated.byteCount == Int64(complete.count))
        #expect(updated.lineCount == 2)
        #expect(updated.chunkHashes == [sha256(complete.subdata(in: 0..<8)), sha256(complete.subdata(in: 8..<16))])

        var corrupt = complete
        corrupt[corrupt.index(before: corrupt.endIndex)] = 0x20
        try corrupt.write(to: target)
        #expect(throws: BackupFileVerificationError.self) {
            try verifier.verifyChangedChunks(
                source: source,
                target: target,
                previous: previous,
                backupPath: previous.backupPath,
                committedByteCount: Int64(complete.count),
                lineCount: 2,
                verifiedAt: Date(timeIntervalSince1970: 2)
            )
        }
    }

    @Test
    func appendAnchorsReadFirstMiddleAndLastOldChunksWithPartialTail() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.jsonl")
        let previousBytes = Data("abcdefghijklmnopqr".utf8)
        try (previousBytes + Data("new bytes".utf8)).write(to: source)
        let verifier = BackupFileVerifier(chunkSize: 4)
        let previous = BackupSessionVerification(
            backupPath: "sessions/source.jsonl",
            byteCount: Int64(previousBytes.count),
            lineCount: 0,
            chunkHashes: stride(from: 0, to: previousBytes.count, by: 4).map { offset in
                sha256(previousBytes.subdata(in: offset..<min(offset + 4, previousBytes.count)))
            },
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
        var reads: [Range<Int64>] = []

        let matches = try verifier.verifyAppendAnchors(
            source: source,
            previous: previous,
            onRead: { reads.append($0) }
        )

        #expect(matches)
        #expect(reads == [0..<4, 8..<12, 16..<18])
    }

    @Test
    func appendAnchorsReadAtMostTwelveMiB() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("large-source.jsonl")
        let chunkSize = BackupVerificationDocument.defaultChunkSize
        var previousBytes = Data()
        var chunkHashes: [String] = []
        for byte in UInt8(0)..<UInt8(5) {
            let chunk = Data(repeating: byte, count: chunkSize)
            previousBytes.append(chunk)
            chunkHashes.append(sha256(chunk))
        }
        try (previousBytes + Data("growth".utf8)).write(to: source)
        let previous = BackupSessionVerification(
            backupPath: "sessions/large-source.jsonl",
            byteCount: Int64(previousBytes.count),
            lineCount: 0,
            chunkHashes: chunkHashes,
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
        var reads: [Range<Int64>] = []

        let matches = try BackupFileVerifier().verifyAppendAnchors(
            source: source,
            previous: previous,
            onRead: { reads.append($0) }
        )

        #expect(matches)
        #expect(reads.count == 3)
        #expect(reads.reduce(Int64(0)) { $0 + $1.upperBound - $1.lowerBound } == 12 * 1_024 * 1_024)
    }

    @Test
    func emptyAppendVerificationSucceedsWithoutReadingSource() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("empty.jsonl")
        try Data().write(to: source)
        let previous = BackupSessionVerification(
            backupPath: "sessions/empty.jsonl",
            byteCount: 0,
            lineCount: 0,
            chunkHashes: [],
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
        var reads: [Range<Int64>] = []

        let matches = try BackupFileVerifier().verifyAppendAnchors(
            source: source,
            previous: previous,
            onRead: { reads.append($0) }
        )

        #expect(matches)
        #expect(reads.isEmpty)
    }

    @Test
    func appendAnchorsRejectInvalidByteCountsAndMissingHashesWithoutReading() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.jsonl")
        try Data("x".utf8).write(to: source)
        let invalidPreviousValues = [
            BackupSessionVerification(
                backupPath: "sessions/source.jsonl",
                byteCount: 1,
                lineCount: 0,
                chunkHashes: [],
                verifiedAt: Date(timeIntervalSince1970: 1)
            ),
            BackupSessionVerification(
                backupPath: "sessions/source.jsonl",
                byteCount: -1,
                lineCount: 0,
                chunkHashes: [],
                verifiedAt: Date(timeIntervalSince1970: 1)
            ),
            BackupSessionVerification(
                backupPath: "sessions/source.jsonl",
                byteCount: -1,
                lineCount: 0,
                chunkHashes: [sha256(Data())],
                verifiedAt: Date(timeIntervalSince1970: 1)
            ),
        ]
        var reads: [Range<Int64>] = []

        for previous in invalidPreviousValues {
            #expect(try !BackupFileVerifier().verifyAppendAnchors(
                source: source,
                previous: previous,
                onRead: { reads.append($0) }
            ))
        }
        #expect(reads.isEmpty)
    }

    @Test
    func emptyAndExactFourMiBBoundaryFilesProduceCanonicalChunks() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let empty = root.appendingPathComponent("empty.jsonl")
        try Data().write(to: empty)
        let verifier = BackupFileVerifier()

        let emptyResult = try verifier.verifyFull(empty, expectedByteCount: 0, expectedLineCount: 0)
        #expect(emptyResult.chunkHashes.isEmpty)
        #expect(emptyResult.contentHash == sha256(Data()))

        let source = root.appendingPathComponent("source.jsonl")
        let target = root.appendingPathComponent("target.jsonl")
        let chunkSize = BackupVerificationDocument.defaultChunkSize
        var boundary = Data([0x22])
        boundary.append(Data(repeating: 0x61, count: chunkSize - 3))
        boundary.append(contentsOf: [0x22, 0x0A])
        try boundary.write(to: source)
        try boundary.write(to: target)
        let initial = try verifier.verifyFull(source, expectedByteCount: Int64(chunkSize), expectedLineCount: 1)
        #expect(initial.chunkHashes == [sha256(boundary)])

        let appended = Data("{}\n".utf8)
        let sourceHandle = try FileHandle(forWritingTo: source)
        let targetHandle = try FileHandle(forWritingTo: target)
        try sourceHandle.seekToEnd()
        try targetHandle.seekToEnd()
        try sourceHandle.write(contentsOf: appended)
        try targetHandle.write(contentsOf: appended)
        try sourceHandle.close()
        try targetHandle.close()
        let previous = BackupSessionVerification(
            backupPath: "sessions/boundary.jsonl",
            byteCount: Int64(chunkSize),
            lineCount: 1,
            chunkHashes: initial.chunkHashes,
            verifiedAt: Date(timeIntervalSince1970: 1)
        )

        let updated = try verifier.verifyChangedChunks(
            source: source,
            target: target,
            previous: previous,
            backupPath: previous.backupPath,
            committedByteCount: Int64(chunkSize + appended.count),
            lineCount: 2,
            verifiedAt: Date(timeIntervalSince1970: 2)
        )

        #expect(updated.chunkHashes == [sha256(boundary), sha256(appended)])
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("BackupVerificationTests-\(UUID().uuidString)", isDirectory: true)
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
