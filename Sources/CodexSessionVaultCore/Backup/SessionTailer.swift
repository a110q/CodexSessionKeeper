import Foundation

public struct TailReadResult: Equatable, Sendable {
    public var lines: [Data]
    public var nextOffset: Int64
    public var pendingPartialLine: Data
    public var blockedError: String?

    public init(
        lines: [Data],
        nextOffset: Int64,
        pendingPartialLine: Data,
        blockedError: String? = nil
    ) {
        self.lines = lines
        self.nextOffset = nextOffset
        self.pendingPartialLine = pendingPartialLine
        self.blockedError = blockedError
    }
}

public final class SessionTailer {
    public static let defaultMaxLineBytes = 32 * 1_024 * 1_024

    private let maxReadBytes: Int
    private let maxPendingPartialBytes: Int
    private let maxLineBytes: Int

    public init(
        maxReadBytes: Int = 1_048_576,
        maxPendingPartialBytes: Int = 65_536,
        maxLineBytes: Int = SessionTailer.defaultMaxLineBytes
    ) {
        self.maxReadBytes = max(0, maxReadBytes)
        self.maxPendingPartialBytes = max(0, maxPendingPartialBytes)
        self.maxLineBytes = max(0, maxLineBytes)
    }

    public convenience init(maxReadBytes: Int) {
        self.init(
            maxReadBytes: maxReadBytes,
            maxPendingPartialBytes: 65_536,
            maxLineBytes: Self.defaultMaxLineBytes
        )
    }

    public convenience init(maxReadBytes: Int, maxLineBytes: Int) {
        self.init(maxReadBytes: maxReadBytes, maxPendingPartialBytes: 65_536, maxLineBytes: maxLineBytes)
    }

    public func readNewCompleteLines(from fileURL: URL, offset: Int64) throws -> TailReadResult {
        let fileSize = try Self.fileSize(at: fileURL)
        let requestedOffset = max(0, offset)
        let startOffset = requestedOffset > fileSize ? 0 : requestedOffset

        guard maxReadBytes > 0 else {
            return TailReadResult(lines: [], nextOffset: startOffset, pendingPartialLine: Data())
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(startOffset))

        var lines: [Data] = []
        var currentLine = Data()
        var scannedByteCount = 0
        var consumedByteCount = 0
        var blockedError: String?

        while true {
            let data = try handle.read(upToCount: maxReadBytes) ?? Data()
            guard !data.isEmpty else {
                break
            }

            var lineStart = data.startIndex
            for index in data.indices where data[index] == Self.newlineByte {
                if lineStart < index {
                    currentLine.append(contentsOf: data[lineStart..<index])
                }
                if currentLine.count > maxLineBytes {
                    blockedError = Self.blockedErrorMessage(
                        for: fileURL,
                        maxLineBytes: maxLineBytes,
                        lineOffset: startOffset + Int64(consumedByteCount)
                    )
                    break
                }

                lines.append(currentLine)
                currentLine.removeAll(keepingCapacity: true)
                let newlineBytePosition = data.distance(from: data.startIndex, to: index) + 1
                consumedByteCount = scannedByteCount + newlineBytePosition
                lineStart = data.index(after: index)
            }

            guard blockedError == nil else {
                break
            }

            if lineStart < data.endIndex {
                currentLine.append(contentsOf: data[lineStart..<data.endIndex])
                if currentLine.count > maxLineBytes {
                    blockedError = Self.blockedErrorMessage(
                        for: fileURL,
                        maxLineBytes: maxLineBytes,
                        lineOffset: startOffset + Int64(consumedByteCount)
                    )
                    break
                }
            }

            scannedByteCount += data.count
        }

        let pendingPartialLine = if blockedError == nil,
            !currentLine.isEmpty,
            currentLine.count <= maxPendingPartialBytes {
            currentLine
        } else {
            Data()
        }

        return TailReadResult(
            lines: lines,
            nextOffset: startOffset + Int64(consumedByteCount),
            pendingPartialLine: pendingPartialLine,
            blockedError: blockedError
        )
    }

    private static let newlineByte: UInt8 = 0x0A

    private static func blockedErrorMessage(for fileURL: URL, maxLineBytes: Int, lineOffset: Int64) -> String {
        "Session JSONL line exceeds maximum JSONL line size of \(maxLineBytes) bytes at offset \(lineOffset): \(fileURL.path)"
    }

    private static func fileSize(at fileURL: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }
}
