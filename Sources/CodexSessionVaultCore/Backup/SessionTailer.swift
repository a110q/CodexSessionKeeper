import Foundation

public struct TailReadResult: Equatable, Sendable {
    public var lines: [Data]
    public var nextOffset: Int64
    public var pendingPartialLine: Data

    public init(lines: [Data], nextOffset: Int64, pendingPartialLine: Data) {
        self.lines = lines
        self.nextOffset = nextOffset
        self.pendingPartialLine = pendingPartialLine
    }
}

public final class SessionTailer {
    private let maxReadBytes: Int
    private let maxPendingPartialBytes: Int

    public init(maxReadBytes: Int = 1_048_576, maxPendingPartialBytes: Int = 65_536) {
        self.maxReadBytes = max(0, maxReadBytes)
        self.maxPendingPartialBytes = max(0, maxPendingPartialBytes)
    }

    public convenience init(maxReadBytes: Int) {
        self.init(maxReadBytes: maxReadBytes, maxPendingPartialBytes: 65_536)
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
        let data = try handle.read(upToCount: maxReadBytes) ?? Data()

        guard !data.isEmpty else {
            return TailReadResult(lines: [], nextOffset: startOffset, pendingPartialLine: Data())
        }

        var lines: [Data] = []
        var lineStart = 0
        var consumedByteCount = 0

        for index in data.indices where data[index] == Self.newlineByte {
            let line = data[lineStart..<index]
            lines.append(Data(line))
            consumedByteCount = index + 1
            lineStart = index + 1
        }

        let partialByteCount = data.count - lineStart
        let readLimitReached = data.count == maxReadBytes
        let pendingPartialLine = if lineStart < data.count,
            partialByteCount <= maxPendingPartialBytes,
            !(readLimitReached && consumedByteCount == 0) {
            Data(data[lineStart..<data.count])
        } else {
            Data()
        }

        return TailReadResult(
            lines: lines,
            nextOffset: startOffset + Int64(consumedByteCount),
            pendingPartialLine: pendingPartialLine
        )
    }

    private static let newlineByte: UInt8 = 0x0A

    private static func fileSize(at fileURL: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }
}
