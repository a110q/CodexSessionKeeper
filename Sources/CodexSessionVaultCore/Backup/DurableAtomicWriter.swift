import Foundation

public struct DurableAtomicWriter {
    private let fileManager: FileManager
    private let synchronize: (FileHandle) throws -> Void

    public init(
        fileManager: FileManager = .default,
        synchronize: @escaping (FileHandle) throws -> Void = { try $0.synchronize() }
    ) {
        self.fileManager = fileManager
        self.synchronize = synchronize
    }

    public func write(
        _ data: Data,
        to destination: URL,
        createParentDirectories: Bool = false
    ) throws {
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        if createParentDirectories {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } else {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CocoaError(.fileNoSuchFile)
            }
        }

        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try synchronize(handle)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
