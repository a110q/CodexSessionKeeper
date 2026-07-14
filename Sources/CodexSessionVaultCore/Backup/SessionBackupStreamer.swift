import CryptoKit
import Foundation

public struct StreamedBackupResult: Equatable, Sendable {
    public let committedByteCount: Int64
    public let lineCount: Int
    public let contentHash: String

    let pendingPartialLine: Data
    let blockedError: String?

    init(
        committedByteCount: Int64,
        lineCount: Int,
        contentHash: String,
        pendingPartialLine: Data,
        blockedError: String?
    ) {
        self.committedByteCount = committedByteCount
        self.lineCount = lineCount
        self.contentHash = contentHash
        self.pendingPartialLine = pendingPartialLine
        self.blockedError = blockedError
    }
}

struct StreamedAppendResult: Equatable, Sendable {
    let committedByteCount: Int64
    let appendedByteCount: Int64
    let lineCount: Int
    let pendingPartialLine: Data
    let blockedError: String?
}

public struct SessionBackupStreamer: Sendable {
    private static let maximumChunkSize = 1_048_576
    private static let newlineByte: UInt8 = 0x0A

    private let chunkSize: Int
    private let maxLineBytes: Int
    private let maxPendingPartialBytes: Int

    public init(
        chunkSize: Int = 1_048_576,
        maxLineBytes: Int = SessionTailer.defaultMaxLineBytes,
        maxPendingPartialBytes: Int = 65_536
    ) {
        self.chunkSize = min(max(1, chunkSize), Self.maximumChunkSize)
        self.maxLineBytes = max(0, maxLineBytes)
        self.maxPendingPartialBytes = max(0, maxPendingPartialBytes)
    }

    public func rebuildCompleteLines(
        source: URL,
        through maximumOffset: Int64?,
        destination: URL
    ) throws -> StreamedBackupResult {
        try rebuildCompleteLines(
            source: source,
            through: maximumOffset,
            destination: destination,
            atomicWriter: DurableAtomicWriter()
        )
    }

    func rebuildCompleteLines(
        source: URL,
        through maximumOffset: Int64?,
        destination: URL,
        atomicWriter: DurableAtomicWriter
    ) throws -> StreamedBackupResult {
        if let maximumOffset, maximumOffset < 0 {
            throw CocoaError(.fileReadCorruptFile)
        }

        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { try? sourceHandle.close() }
        var remaining = maximumOffset
        var committedByteCount: Int64 = 0
        var lineCount = 0
        var digest = SHA256()
        var pendingLine = Data()
        var blockedError: String?
        var lineOffset: Int64 = 0

        try atomicWriter.replace(at: destination) { destinationHandle in
            readLoop: while remaining.map({ $0 > 0 }) ?? true {
                let requestedCount = remaining.map { Int(min($0, Int64(chunkSize))) } ?? chunkSize
                guard requestedCount > 0,
                      let chunk = try sourceHandle.read(upToCount: requestedCount),
                      !chunk.isEmpty else {
                    break
                }
                if remaining != nil {
                    remaining! -= Int64(chunk.count)
                }

                var segmentStart = chunk.startIndex
                for newlineIndex in chunk.indices where chunk[newlineIndex] == Self.newlineByte {
                    if segmentStart < newlineIndex {
                        pendingLine.append(contentsOf: chunk[segmentStart..<newlineIndex])
                    }
                    guard pendingLine.count <= maxLineBytes else {
                        blockedError = Self.blockedErrorMessage(
                            for: source,
                            maxLineBytes: maxLineBytes,
                            lineOffset: lineOffset
                        )
                        pendingLine.removeAll(keepingCapacity: false)
                        break readLoop
                    }

                    if !pendingLine.isEmpty {
                        try destinationHandle.write(contentsOf: pendingLine)
                        digest.update(data: pendingLine)
                        committedByteCount += Int64(pendingLine.count)
                    }
                    let newline = Data([Self.newlineByte])
                    try destinationHandle.write(contentsOf: newline)
                    digest.update(data: newline)
                    committedByteCount += 1
                    lineCount += 1
                    pendingLine.removeAll(keepingCapacity: true)
                    lineOffset = committedByteCount
                    segmentStart = chunk.index(after: newlineIndex)
                }

                if segmentStart < chunk.endIndex {
                    pendingLine.append(contentsOf: chunk[segmentStart..<chunk.endIndex])
                    guard pendingLine.count <= maxLineBytes else {
                        blockedError = Self.blockedErrorMessage(
                            for: source,
                            maxLineBytes: maxLineBytes,
                            lineOffset: lineOffset
                        )
                        pendingLine.removeAll(keepingCapacity: false)
                        break
                    }
                }
            }
        }

        let cursorPartialLine: Data
        if blockedError != nil || pendingLine.isEmpty {
            cursorPartialLine = Data()
        } else if pendingLine.count <= maxPendingPartialBytes {
            cursorPartialLine = pendingLine
        } else {
            cursorPartialLine = Data([0])
        }

        return StreamedBackupResult(
            committedByteCount: committedByteCount,
            lineCount: lineCount,
            contentHash: Self.hexDigest(digest.finalize()),
            pendingPartialLine: cursorPartialLine,
            blockedError: blockedError
        )
    }

    func appendCompleteLines(
        source: URL,
        from sourceOffset: Int64,
        destination: URL,
        synchronize: (FileHandle) throws -> Void
    ) throws -> StreamedAppendResult {
        guard sourceOffset >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let sourceHandle = try FileHandle(forReadingFrom: source)
        let destinationHandle = try FileHandle(forWritingTo: destination)
        defer {
            try? sourceHandle.close()
            try? destinationHandle.close()
        }
        try sourceHandle.seek(toOffset: UInt64(sourceOffset))
        let targetOffset = try destinationHandle.seekToEnd()
        guard targetOffset == UInt64(sourceOffset) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var appendedByteCount: Int64 = 0
        var lineCount = 0
        var pendingLine = Data()
        var blockedError: String?

        readLoop: while true {
            guard let chunk = try sourceHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            var segmentStart = chunk.startIndex
            for newlineIndex in chunk.indices where chunk[newlineIndex] == Self.newlineByte {
                if segmentStart < newlineIndex {
                    pendingLine.append(contentsOf: chunk[segmentStart..<newlineIndex])
                }
                guard pendingLine.count <= maxLineBytes else {
                    blockedError = Self.blockedErrorMessage(
                        for: source,
                        maxLineBytes: maxLineBytes,
                        lineOffset: sourceOffset + appendedByteCount
                    )
                    pendingLine.removeAll(keepingCapacity: false)
                    break readLoop
                }

                if !pendingLine.isEmpty {
                    try destinationHandle.write(contentsOf: pendingLine)
                    appendedByteCount += Int64(pendingLine.count)
                }
                try destinationHandle.write(contentsOf: Data([Self.newlineByte]))
                appendedByteCount += 1
                lineCount += 1
                pendingLine.removeAll(keepingCapacity: true)
                segmentStart = chunk.index(after: newlineIndex)
            }

            if segmentStart < chunk.endIndex {
                pendingLine.append(contentsOf: chunk[segmentStart..<chunk.endIndex])
                guard pendingLine.count <= maxLineBytes else {
                    blockedError = Self.blockedErrorMessage(
                        for: source,
                        maxLineBytes: maxLineBytes,
                        lineOffset: sourceOffset + appendedByteCount
                    )
                    pendingLine.removeAll(keepingCapacity: false)
                    break
                }
            }
        }

        if appendedByteCount > 0 {
            try synchronize(destinationHandle)
        }
        let cursorPartialLine = cursorPartialLine(pendingLine, blockedError: blockedError)
        return StreamedAppendResult(
            committedByteCount: sourceOffset + appendedByteCount,
            appendedByteCount: appendedByteCount,
            lineCount: lineCount,
            pendingPartialLine: cursorPartialLine,
            blockedError: blockedError
        )
    }

    public func rangesMatch(
        source: URL,
        sourceOffset: Int64,
        target: URL,
        targetOffset: Int64,
        length: Int64
    ) throws -> Bool {
        guard sourceOffset >= 0, targetOffset >= 0, length >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let sourceHandle = try FileHandle(forReadingFrom: source)
        let targetHandle = try FileHandle(forReadingFrom: target)
        defer {
            try? sourceHandle.close()
            try? targetHandle.close()
        }
        try sourceHandle.seek(toOffset: UInt64(sourceOffset))
        try targetHandle.seek(toOffset: UInt64(targetOffset))

        var remaining = length
        while remaining > 0 {
            let count = Int(min(remaining, Int64(chunkSize)))
            let sourceData = try sourceHandle.read(upToCount: count) ?? Data()
            let targetData = try targetHandle.read(upToCount: count) ?? Data()
            guard !sourceData.isEmpty,
                  sourceData.count == targetData.count,
                  sourceData == targetData else {
                return false
            }
            remaining -= Int64(sourceData.count)
        }
        return true
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func cursorPartialLine(_ pendingLine: Data, blockedError: String?) -> Data {
        if blockedError != nil || pendingLine.isEmpty {
            return Data()
        }
        if pendingLine.count <= maxPendingPartialBytes {
            return pendingLine
        }
        return Data([0])
    }

    private static func blockedErrorMessage(for fileURL: URL, maxLineBytes: Int, lineOffset: Int64) -> String {
        "Session JSONL line exceeds maximum JSONL line size of \(maxLineBytes) bytes at offset \(lineOffset): \(fileURL.path)"
    }
}
