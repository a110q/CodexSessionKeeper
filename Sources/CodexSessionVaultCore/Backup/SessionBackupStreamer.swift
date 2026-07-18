import CryptoKit
import Foundation

public struct StreamedBackupResult: Equatable, Sendable {
    public let committedByteCount: Int64
    public let lineCount: Int
    public let contentHash: String

    let pendingPartialLine: Data
    let blockedError: String?
    let firstTitle: String?

    init(
        committedByteCount: Int64,
        lineCount: Int,
        contentHash: String,
        pendingPartialLine: Data,
        blockedError: String?,
        firstTitle: String?
    ) {
        self.committedByteCount = committedByteCount
        self.lineCount = lineCount
        self.contentHash = contentHash
        self.pendingPartialLine = pendingPartialLine
        self.blockedError = blockedError
        self.firstTitle = firstTitle
    }
}

struct StreamedAppendResult: Equatable, Sendable {
    let committedByteCount: Int64
    let appendedByteCount: Int64
    let lineCount: Int
    let pendingPartialLine: Data
    let blockedError: String?
    let firstTitle: String?
}

struct BufferedBackupWriter {
    static let defaultCapacity = 1_048_576

    private let capacity: Int
    private let writeChunk: (Data) throws -> Void
    private var buffer: Data

    init(
        capacity: Int = Self.defaultCapacity,
        writeChunk: @escaping (Data) throws -> Void
    ) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.writeChunk = writeChunk
        self.buffer = Data()
        self.buffer.reserveCapacity(capacity)
    }

    mutating func append(_ data: Data) throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            let available = capacity - buffer.count
            let count = min(available, data.distance(from: offset, to: data.endIndex))
            let end = data.index(offset, offsetBy: count)
            buffer.append(contentsOf: data[offset..<end])
            offset = end
            if buffer.count == capacity {
                try flush()
            }
        }
    }

    mutating func append(byte: UInt8) throws {
        buffer.append(byte)
        if buffer.count == capacity {
            try flush()
        }
    }

    mutating func flush() throws {
        guard !buffer.isEmpty else { return }
        try writeChunk(buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

public struct SessionBackupStreamer: Sendable {
    private static let maximumChunkSize = 1_048_576
    // Titles are display metadata. Never materialize an arbitrarily large JSON record solely to derive one.
    static let maximumTitleRecordBytes = 256 * 1_024
    private static let newlineByte: UInt8 = 0x0A
    private static let newline = Data([newlineByte])

    private let chunkSize: Int
    let effectiveMaxLineBytes: Int
    private let maxPendingPartialBytes: Int

    public init(
        chunkSize: Int = 1_048_576,
        maxLineBytes: Int = SessionTailer.defaultMaxLineBytes,
        maxPendingPartialBytes: Int = 65_536
    ) {
        self.chunkSize = min(max(1, chunkSize), Self.maximumChunkSize)
        self.effectiveMaxLineBytes = max(0, maxLineBytes)
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
        atomicWriter: DurableAtomicWriter,
        verifyTemporary: ((URL, StreamedBackupResult) throws -> Void)? = nil
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
        var firstTitle: String?
        var lineOffset: Int64 = 0

        try atomicWriter.replace(
            at: destination,
            verifyTemporary: { temporaryURL in
                guard let verifyTemporary else { return }
                let verificationDigest = digest
                try verifyTemporary(
                    temporaryURL,
                    StreamedBackupResult(
                        committedByteCount: committedByteCount,
                        lineCount: lineCount,
                        contentHash: Self.hexDigest(verificationDigest.finalize()),
                        pendingPartialLine: self.cursorPartialLine(
                            pendingLine,
                            blockedError: blockedError
                        ),
                        blockedError: blockedError,
                        firstTitle: firstTitle
                    )
                )
            }
        ) { destinationHandle in
            var bufferedWriter = BufferedBackupWriter {
                try destinationHandle.write(contentsOf: $0)
            }
            while remaining.map({ $0 > 0 }) ?? true {
                let shouldContinue = try autoreleasepool { () throws -> Bool in
                    let requestedCount = remaining.map { Int(min($0, Int64(chunkSize))) } ?? chunkSize
                    guard requestedCount > 0,
                          let chunk = try sourceHandle.read(upToCount: requestedCount),
                          !chunk.isEmpty else {
                        return false
                    }
                    if remaining != nil {
                        remaining! -= Int64(chunk.count)
                    }

                    var segmentStart = chunk.startIndex
                    for newlineIndex in chunk.indices where chunk[newlineIndex] == Self.newlineByte {
                        if segmentStart < newlineIndex {
                            pendingLine.append(contentsOf: chunk[segmentStart..<newlineIndex])
                        }
                        guard pendingLine.count <= effectiveMaxLineBytes else {
                            blockedError = Self.blockedErrorMessage(
                                for: source,
                                maxLineBytes: effectiveMaxLineBytes,
                                lineOffset: lineOffset
                            )
                            pendingLine.removeAll(keepingCapacity: false)
                            return false
                        }
                        if firstTitle == nil {
                            firstTitle = Self.title(from: pendingLine)
                        }

                        if !pendingLine.isEmpty {
                            try bufferedWriter.append(pendingLine)
                            digest.update(data: pendingLine)
                            committedByteCount += Int64(pendingLine.count)
                        }
                        try bufferedWriter.append(byte: Self.newlineByte)
                        digest.update(data: Self.newline)
                        committedByteCount += 1
                        lineCount += 1
                        let oversizedLine = pendingLine.count > chunkSize
                        pendingLine.removeAll(keepingCapacity: !oversizedLine)
                        if oversizedLine { BackupMemoryPressureRelief.relieve() }
                        lineOffset = committedByteCount
                        segmentStart = chunk.index(after: newlineIndex)
                    }

                    if segmentStart < chunk.endIndex {
                        pendingLine.append(contentsOf: chunk[segmentStart..<chunk.endIndex])
                        guard pendingLine.count <= effectiveMaxLineBytes else {
                            blockedError = Self.blockedErrorMessage(
                                for: source,
                                maxLineBytes: effectiveMaxLineBytes,
                                lineOffset: lineOffset
                            )
                            pendingLine.removeAll(keepingCapacity: false)
                            return false
                        }
                    }
                    return true
                }
                if !shouldContinue { break }
            }
            try bufferedWriter.flush()
        }

        let partialLineForCursor = cursorPartialLine(pendingLine, blockedError: blockedError)

        return StreamedBackupResult(
            committedByteCount: committedByteCount,
            lineCount: lineCount,
            contentHash: Self.hexDigest(digest.finalize()),
            pendingPartialLine: partialLineForCursor,
            blockedError: blockedError,
            firstTitle: firstTitle
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
        var firstTitle: String?
        var bufferedWriter = BufferedBackupWriter {
            try destinationHandle.write(contentsOf: $0)
        }

        while true {
            let shouldContinue = try autoreleasepool { () throws -> Bool in
                guard let chunk = try sourceHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    return false
                }
                var segmentStart = chunk.startIndex
                for newlineIndex in chunk.indices where chunk[newlineIndex] == Self.newlineByte {
                    if segmentStart < newlineIndex {
                        pendingLine.append(contentsOf: chunk[segmentStart..<newlineIndex])
                    }
                    guard pendingLine.count <= effectiveMaxLineBytes else {
                        blockedError = Self.blockedErrorMessage(
                            for: source,
                            maxLineBytes: effectiveMaxLineBytes,
                            lineOffset: sourceOffset + appendedByteCount
                        )
                        pendingLine.removeAll(keepingCapacity: false)
                        return false
                    }
                    if firstTitle == nil {
                        firstTitle = Self.title(from: pendingLine)
                    }

                    if !pendingLine.isEmpty {
                        try bufferedWriter.append(pendingLine)
                        appendedByteCount += Int64(pendingLine.count)
                    }
                    try bufferedWriter.append(byte: Self.newlineByte)
                    appendedByteCount += 1
                    lineCount += 1
                    let oversizedLine = pendingLine.count > chunkSize
                    pendingLine.removeAll(keepingCapacity: !oversizedLine)
                    if oversizedLine { BackupMemoryPressureRelief.relieve() }
                    segmentStart = chunk.index(after: newlineIndex)
                }

                if segmentStart < chunk.endIndex {
                    pendingLine.append(contentsOf: chunk[segmentStart..<chunk.endIndex])
                    guard pendingLine.count <= effectiveMaxLineBytes else {
                        blockedError = Self.blockedErrorMessage(
                            for: source,
                            maxLineBytes: effectiveMaxLineBytes,
                            lineOffset: sourceOffset + appendedByteCount
                        )
                        pendingLine.removeAll(keepingCapacity: false)
                        return false
                    }
                }
                return true
            }
            if !shouldContinue { break }
        }

        try bufferedWriter.flush()
        if appendedByteCount > 0 {
            try synchronize(destinationHandle)
        }
        let cursorPartialLine = cursorPartialLine(pendingLine, blockedError: blockedError)
        return StreamedAppendResult(
            committedByteCount: sourceOffset + appendedByteCount,
            appendedByteCount: appendedByteCount,
            lineCount: lineCount,
            pendingPartialLine: cursorPartialLine,
            blockedError: blockedError,
            firstTitle: firstTitle
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

    private static func title(from line: Data) -> String? {
        guard line.count <= maximumTitleRecordBytes else { return nil }
        return SessionIdentity.title(fromJSONData: line)
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
