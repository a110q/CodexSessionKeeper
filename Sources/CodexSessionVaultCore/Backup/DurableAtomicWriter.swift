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
        permissions: NSNumber? = nil,
        parentDirectoryPermissions: NSNumber? = nil,
        createParentDirectories: Bool = false
    ) throws {
        try replace(
            at: destination,
            permissions: permissions,
            parentDirectoryPermissions: parentDirectoryPermissions,
            createParentDirectories: createParentDirectories
        ) { handle in
            try handle.write(contentsOf: data)
        }
    }

    public func writeIfAbsent(
        _ data: Data,
        to destination: URL,
        permissions: NSNumber? = nil,
        parentDirectoryPermissions: NSNumber? = nil,
        createParentDirectories: Bool = false
    ) throws {
        try commit(
            to: destination,
            permissions: permissions,
            parentDirectoryPermissions: parentDirectoryPermissions,
            createParentDirectories: createParentDirectories,
            replaceExisting: false
        ) { handle in
            try handle.write(contentsOf: data)
        }
    }

    public func writeIfAbsent(
        at destination: URL,
        permissions: NSNumber? = nil,
        parentDirectoryPermissions: NSNumber? = nil,
        createParentDirectories: Bool = false,
        verifyTemporary: ((URL) throws -> Void)? = nil,
        writer: (FileHandle) throws -> Void
    ) throws {
        try commit(
            to: destination,
            permissions: permissions,
            parentDirectoryPermissions: parentDirectoryPermissions,
            createParentDirectories: createParentDirectories,
            replaceExisting: false,
            verifyTemporary: verifyTemporary,
            writer: writer
        )
    }

    public func replace(
        at destination: URL,
        permissions: NSNumber? = nil,
        parentDirectoryPermissions: NSNumber? = nil,
        createParentDirectories: Bool = false,
        verifyTemporary: ((URL) throws -> Void)? = nil,
        writer: (FileHandle) throws -> Void
    ) throws {
        try commit(
            to: destination,
            permissions: permissions,
            parentDirectoryPermissions: parentDirectoryPermissions,
            createParentDirectories: createParentDirectories,
            replaceExisting: true,
            verifyTemporary: verifyTemporary,
            writer: writer
        )
    }

    private func commit(
        to destination: URL,
        permissions: NSNumber?,
        parentDirectoryPermissions: NSNumber?,
        createParentDirectories: Bool,
        replaceExisting: Bool,
        verifyTemporary: ((URL) throws -> Void)? = nil,
        writer: (FileHandle) throws -> Void
    ) throws {
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        if createParentDirectories {
            let attributes: [FileAttributeKey: Any]? = parentDirectoryPermissions.map {
                [.posixPermissions: $0]
            }
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: attributes
            )
        } else {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CocoaError(.fileNoSuchFile)
            }
        }
        if let parentDirectoryPermissions {
            if (try? fileManager.destinationOfSymbolicLink(atPath: parent.path)) != nil {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileManager.setAttributes(
                [.posixPermissions: parentDirectoryPermissions],
                ofItemAtPath: parent.path
            )
        }

        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        let temporaryAttributes: [FileAttributeKey: Any]? = permissions.map {
            [.posixPermissions: $0]
        }
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: temporaryAttributes
        ) else {
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

            try verifyTemporary?(temporary)

            if replaceExisting, fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            if let permissions {
                try fileManager.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: destination.path
                )
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
