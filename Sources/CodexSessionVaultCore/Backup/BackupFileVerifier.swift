import CryptoKit
import Foundation

public struct BackupFileVerificationResult: Equatable, Sendable {
    public let byteCount: Int64
    public let lineCount: Int
    public let contentHash: String
    public let chunkHashes: [String]
}

public enum BackupFileVerificationError: Error, LocalizedError, Equatable, Sendable {
    case invalidFile(String)
    case byteCountMismatch(expected: Int64, actual: Int64)
    case lineCountMismatch(expected: Int, actual: Int)
    case contentHashMismatch
    case chunkHashMismatch(Int)
    case incompleteJSONL
    case invalidJSONL(Int)
    case lineTooLong(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidFile(path):
            return "备份不是可信的普通文件：\(path)"
        case let .byteCountMismatch(expected, actual):
            return "备份长度不一致：预期 \(expected)，实际 \(actual)。"
        case let .lineCountMismatch(expected, actual):
            return "备份 JSONL 行数不一致：预期 \(expected)，实际 \(actual)。"
        case .contentHashMismatch:
            return "备份 SHA-256 不一致。"
        case let .chunkHashMismatch(index):
            return "备份分块 SHA-256 不一致：第 \(index + 1) 块。"
        case .incompleteJSONL:
            return "备份包含未完成的 JSONL 尾行。"
        case let .invalidJSONL(line):
            return "备份包含无效 JSONL：第 \(line) 行。"
        case let .lineTooLong(limit):
            return "备份 JSONL 单行超过 \(limit) 字节限制。"
        }
    }
}

public struct BackupFileVerifier: Sendable {
    public let chunkSize: Int
    public let maxLineBytes: Int

    public init(
        chunkSize: Int = BackupVerificationDocument.defaultChunkSize,
        maxLineBytes: Int = SessionTailer.defaultMaxLineBytes
    ) {
        self.chunkSize = max(1, chunkSize)
        self.maxLineBytes = max(0, maxLineBytes)
    }

    public func verifyFull(
        _ fileURL: URL,
        expectedByteCount: Int64? = nil,
        expectedLineCount: Int? = nil,
        expectedContentHash: String? = nil,
        expectedChunkHashes: [String]? = nil
    ) throws -> BackupFileVerificationResult {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BackupFileVerificationError.invalidFile(fileURL.path)
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let size = try checkedFileSize(handle)
        if let expectedByteCount, size != expectedByteCount {
            throw BackupFileVerificationError.byteCountMismatch(expected: expectedByteCount, actual: size)
        }

        var digest = SHA256()
        var chunkHashes: [String] = []
        var jsonl = JSONLValidator(maxLineBytes: maxLineBytes)
        var remaining = size
        while remaining > 0 {
            let count = Int(min(Int64(chunkSize), remaining))
            let chunk = try readExactly(handle, count: count)
            guard chunk.count == count else {
                throw BackupFileVerificationError.byteCountMismatch(expected: size, actual: size - remaining + Int64(chunk.count))
            }
            digest.update(data: chunk)
            chunkHashes.append(Self.sha256(chunk))
            try jsonl.consume(chunk)
            remaining -= Int64(chunk.count)
        }
        try jsonl.finish(byteCount: size)
        let contentHash = Self.hexDigest(digest.finalize())
        if let expectedLineCount, jsonl.lineCount != expectedLineCount {
            throw BackupFileVerificationError.lineCountMismatch(expected: expectedLineCount, actual: jsonl.lineCount)
        }
        if let expectedContentHash,
           contentHash.caseInsensitiveCompare(expectedContentHash) != .orderedSame {
            throw BackupFileVerificationError.contentHashMismatch
        }
        if let expectedChunkHashes {
            guard expectedChunkHashes.count == chunkHashes.count else {
                throw BackupFileVerificationError.chunkHashMismatch(min(expectedChunkHashes.count, chunkHashes.count))
            }
            for (index, pair) in zip(expectedChunkHashes, chunkHashes).enumerated()
                where pair.0.caseInsensitiveCompare(pair.1) != .orderedSame {
                throw BackupFileVerificationError.chunkHashMismatch(index)
            }
        }
        return BackupFileVerificationResult(
            byteCount: size,
            lineCount: jsonl.lineCount,
            contentHash: contentHash,
            chunkHashes: chunkHashes
        )
    }

    public func verifyChangedChunks(
        source: URL,
        target: URL,
        previous: BackupSessionVerification,
        backupPath: String,
        committedByteCount: Int64,
        lineCount: Int,
        verifiedAt: Date
    ) throws -> BackupSessionVerification {
        guard previous.byteCount >= 0,
              committedByteCount >= previous.byteCount,
              previous.lineCount <= lineCount else {
            throw BackupFileVerificationError.invalidFile(target.path)
        }
        let expectedPreviousChunks = Int((previous.byteCount + Int64(chunkSize) - 1) / Int64(chunkSize))
        guard previous.chunkHashes.count == expectedPreviousChunks else {
            throw BackupFileVerificationError.invalidFile(target.path)
        }
        let sourceHandle = try FileHandle(forReadingFrom: source)
        let targetHandle = try FileHandle(forReadingFrom: target)
        defer {
            try? sourceHandle.close()
            try? targetHandle.close()
        }
        let sourceSize = try checkedFileSize(sourceHandle)
        let targetSize = try checkedFileSize(targetHandle)
        guard sourceSize >= committedByteCount else {
            throw BackupFileVerificationError.byteCountMismatch(expected: committedByteCount, actual: sourceSize)
        }
        guard targetSize == committedByteCount else {
            throw BackupFileVerificationError.byteCountMismatch(expected: committedByteCount, actual: targetSize)
        }

        let chunkSize64 = Int64(chunkSize)
        let firstChangedChunk = Int(previous.byteCount / chunkSize64)
        let startOffset = Int64(firstChangedChunk) * chunkSize64
        try sourceHandle.seek(toOffset: UInt64(startOffset))
        try targetHandle.seek(toOffset: UInt64(startOffset))
        var hashes = Array(previous.chunkHashes.prefix(firstChangedChunk))
        var position = startOffset
        var appendedJSONL = JSONLValidator(maxLineBytes: maxLineBytes)
        while position < committedByteCount {
            let count = Int(min(chunkSize64, committedByteCount - position))
            let sourceChunk = try readExactly(sourceHandle, count: count)
            let targetChunk = try readExactly(targetHandle, count: count)
            guard sourceChunk.count == count, targetChunk.count == count, sourceChunk == targetChunk else {
                throw BackupFileVerificationError.chunkHashMismatch(hashes.count)
            }
            hashes.append(Self.sha256(targetChunk))
            let appendedStart = max(previous.byteCount, position)
            if appendedStart < position + Int64(count) {
                let lower = Int(appendedStart - position)
                try appendedJSONL.consume(targetChunk.subdata(in: lower..<targetChunk.count))
            }
            position += Int64(count)
        }
        try appendedJSONL.finish(byteCount: committedByteCount - previous.byteCount)
        let actualLineCount = previous.lineCount + appendedJSONL.lineCount
        guard actualLineCount == lineCount else {
            throw BackupFileVerificationError.lineCountMismatch(expected: lineCount, actual: actualLineCount)
        }
        return BackupSessionVerification(
            backupPath: backupPath,
            byteCount: committedByteCount,
            lineCount: lineCount,
            chunkHashes: hashes,
            verifiedAt: verifiedAt
        )
    }

    public func verifyAppendAnchors(
        source: URL,
        previous: BackupSessionVerification,
        onRead: (Range<Int64>) -> Void
    ) throws -> Bool {
        guard previous.byteCount >= 0 else { return false }
        guard !previous.chunkHashes.isEmpty else { return previous.byteCount == 0 }
        guard previous.byteCount > 0 else { return false }
        let chunkSize64 = Int64(chunkSize)
        let expectedChunkCount = Int((previous.byteCount - 1) / chunkSize64 + 1)
        guard previous.chunkHashes.count == expectedChunkCount else { return false }

        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BackupFileVerificationError.invalidFile(source.path)
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        guard try checkedFileSize(handle) >= previous.byteCount else { return false }

        let lastIndex = previous.chunkHashes.count - 1
        let indices = Set([0, lastIndex / 2, lastIndex]).sorted()
        for index in indices {
            let lowerBound = Int64(index) * chunkSize64
            let upperBound = min(previous.byteCount, lowerBound + chunkSize64)
            let count = Int(upperBound - lowerBound)
            try handle.seek(toOffset: UInt64(lowerBound))
            let data = try readExactly(handle, count: count)
            onRead(lowerBound..<(lowerBound + Int64(data.count)))
            guard data.count == count,
                  Self.sha256(data).caseInsensitiveCompare(previous.chunkHashes[index]) == .orderedSame else {
                return false
            }
        }
        return true
    }

    private func checkedFileSize(_ handle: FileHandle) throws -> Int64 {
        let offset = try handle.seekToEnd()
        guard offset <= UInt64(Int64.max) else {
            throw BackupFileVerificationError.invalidFile("file-too-large")
        }
        try handle.seek(toOffset: 0)
        return Int64(offset)
    }

    private func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        hexDigest(SHA256.hash(data: data))
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct JSONLValidator {
    let maxLineBytes: Int
    private(set) var lineCount = 0
    private var pending = Data()

    init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    mutating func consume(_ data: Data) throws {
        var segmentStart = data.startIndex
        for newlineIndex in data.indices where data[newlineIndex] == 0x0A {
            if segmentStart < newlineIndex {
                pending.append(contentsOf: data[segmentStart..<newlineIndex])
            }
            try validatePendingLine()
            lineCount += 1
            pending.removeAll(keepingCapacity: true)
            segmentStart = data.index(after: newlineIndex)
        }
        if segmentStart < data.endIndex {
            pending.append(contentsOf: data[segmentStart..<data.endIndex])
            guard pending.count <= maxLineBytes else {
                throw BackupFileVerificationError.lineTooLong(maxLineBytes)
            }
        }
    }

    mutating func finish(byteCount: Int64) throws {
        if byteCount > 0, !pending.isEmpty {
            throw BackupFileVerificationError.incompleteJSONL
        }
    }

    private func validatePendingLine() throws {
        guard pending.count <= maxLineBytes else {
            throw BackupFileVerificationError.lineTooLong(maxLineBytes)
        }
        guard !pending.isEmpty else { return }
        do {
            _ = try JSONSerialization.jsonObject(with: pending, options: [.fragmentsAllowed])
        } catch {
            throw BackupFileVerificationError.invalidJSONL(lineCount + 1)
        }
    }
}
