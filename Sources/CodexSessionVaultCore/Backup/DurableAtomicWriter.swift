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
        try replace(at: destination, createParentDirectories: createParentDirectories) { handle in
            try handle.write(contentsOf: data)
        }
    }

    public func writeIfAbsent(
        _ data: Data,
        to destination: URL,
        createParentDirectories: Bool = false
    ) throws {
        try commit(
            to: destination,
            permissions: nil,
            createParentDirectories: createParentDirectories,
            replaceExisting: false
        ) { handle in
            try handle.write(contentsOf: data)
        }
    }

    public func replace(
        at destination: URL,
        permissions: NSNumber? = nil,
        createParentDirectories: Bool = false,
        writer: (FileHandle) throws -> Void
    ) throws {
        try commit(
            to: destination,
            permissions: permissions,
            createParentDirectories: createParentDirectories,
            replaceExisting: true,
            writer: writer
        )
    }

    private func commit(
        to destination: URL,
        permissions: NSNumber?,
        createParentDirectories: Bool,
        replaceExisting: Bool,
        writer: (FileHandle) throws -> Void
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
                try writer(handle)
                if let permissions {
                    try fileManager.setAttributes(
                        [.posixPermissions: permissions],
                        ofItemAtPath: temporary.path
                    )
                }
                try synchronize(handle)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            if replaceExisting, fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            synchronizeParentDirectoryIfSupported(parent)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func synchronizeParentDirectoryIfSupported(_ parent: URL) {
        guard let handle = try? FileHandle(forReadingFrom: parent) else { return }
        defer { try? handle.close() }
        try? handle.synchronize()
    }
}
