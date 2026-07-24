import Darwin
import Foundation

enum ProcessMemoryTestSupport {
    static let mebibyte: UInt64 = 1_024 * 1_024

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CODEX_RUN_MEMORY_REGRESSION"] == "1"
    }

    static func physicalFootprintBytes() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw ProcessMemoryTestError.taskInfoFailed(result)
        }
        return info.phys_footprint
    }

    static func releaseUnusedMallocPages() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    static func growth(from before: UInt64, to after: UInt64) -> UInt64 {
        after > before ? after - before : 0
    }

    static func median(_ values: [UInt64]) -> UInt64? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return sorted[middle - 1] / 2 + sorted[middle] / 2
        }
        return sorted[middle]
    }

    static func nestedJSONLine() -> Data {
        let items = (0..<16).map { index in
            #"{"index":\#(index),"text":"\#(String(repeating: "x", count: 48))","flags":[true,false,null],"meta":{"source":"memory-test"}}"#
        }.joined(separator: ",")
        return Data(
            #"{"type":"response_item","payload":{"items":[\#(items)],"metadata":{"provider":"openai","model":"test"}}}"#.utf8
        ) + Data([0x0A])
    }

    static func writeRepeatedLine(_ line: Data, count: Int, to fileURL: URL) throws {
        _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1_048_576 + line.count)
        for _ in 0..<count {
            buffer.append(line)
            if buffer.count >= 1_048_576 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        try handle.synchronize()
    }

    static func repeatedLineData(_ line: Data, count: Int) -> Data {
        var result = Data()
        result.reserveCapacity(line.count * count)
        for _ in 0..<count {
            result.append(line)
        }
        return result
    }
}

enum ProcessMemoryTestError: Error {
    case taskInfoFailed(kern_return_t)
}
