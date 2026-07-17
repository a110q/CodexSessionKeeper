import Foundation

public struct SessionDeletionPlan {
    public let sessionIDs: Set<String>
    public let trustedSessionFiles: [TrustedSessionFile]
    public let missingSessionIDs: [String]

    private let mutations: [JSONLMutation]
    private let fileManager: FileManager

    public static func preflight(
        sessionIDs: Set<String>,
        codexRoot: URL,
        fileManager: FileManager = .default
    ) throws -> SessionDeletionPlan {
        let normalized = Set(sessionIDs.compactMap(SessionJSONLValidator.normalizeSessionID))
        let trusted = try TrustedSessionFileResolver.resolve(
            sessionIDs: normalized,
            under: codexRoot,
            fileManager: fileManager
        )
        let found = Set(trusted.map(\.sessionID))
        let missing = normalized.subtracting(found).sorted()
        var mutations: [JSONLMutation] = []

        for (name, kind) in [
            ("history.jsonl", SessionJSONLKind.history),
            ("history.jsonl.bak", SessionJSONLKind.historyBackup),
            ("session_index.jsonl", SessionJSONLKind.sessionIndex)
        ] {
            let fileURL = codexRoot.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            let document = try SessionJSONLValidator.parse(fileURL, kind: kind)
            let remaining = document.records.filter { !normalized.contains($0.sessionID) }
            var output = Data()
            for record in remaining {
                output.append(record.rawData)
                output.append(0x0A)
            }
            mutations.append(JSONLMutation(
                fileURL: fileURL,
                output: output,
                fingerprint: document.fingerprint
            ))
        }

        return SessionDeletionPlan(
            sessionIDs: normalized,
            trustedSessionFiles: trusted,
            missingSessionIDs: missing,
            mutations: mutations,
            fileManager: fileManager
        )
    }

    public static func preflight(
        sessionIDs: [String],
        codexRoot: URL,
        fileManager: FileManager = .default
    ) throws -> SessionDeletionPlan {
        try preflight(sessionIDs: Set(sessionIDs), codexRoot: codexRoot, fileManager: fileManager)
    }

    @discardableResult
    public func commit(writer: DurableAtomicWriter = DurableAtomicWriter()) throws -> String? {
        try validateCurrent()
        let transactionID = UUID().uuidString
        var indexBackups: [(original: URL, backup: URL)] = []
        var quarantined: [(original: URL, quarantine: URL)] = []

        do {
            for mutation in mutations {
                let backup = mutation.fileURL.deletingLastPathComponent().appendingPathComponent(
                    ".\(mutation.fileURL.lastPathComponent).delete-backup-\(transactionID)"
                )
                try fileManager.linkItem(at: mutation.fileURL, to: backup)
                indexBackups.append((mutation.fileURL, backup))
            }

            for trusted in trustedSessionFiles {
                let quarantine = trusted.fileURL.deletingLastPathComponent().appendingPathComponent(
                    ".\(trusted.fileURL.lastPathComponent).delete-\(transactionID)"
                )
                try fileManager.moveItem(at: trusted.fileURL, to: quarantine)
                quarantined.append((trusted.fileURL, quarantine))
                try trusted.fingerprint.validateRelocated(at: quarantine)
            }

            for mutation in mutations {
                try writer.write(
                    mutation.output,
                    to: mutation.fileURL,
                    permissions: 0o600,
                    createParentDirectories: false
                )
            }
        } catch {
            rollbackIndexFiles(indexBackups)
            rollbackQuarantinedFiles(quarantined)
            throw error
        }

        for item in indexBackups { try? fileManager.removeItem(at: item.backup) }
        for item in quarantined { try? fileManager.removeItem(at: item.quarantine) }
        guard !missingSessionIDs.isEmpty else { return nil }
        return "会话文件不存在或未删除，仅清理索引：\(missingSessionIDs.joined(separator: ", "))"
    }

    public func validateCurrent() throws {
        for file in trustedSessionFiles { try file.fingerprint.validateCurrent() }
        for mutation in mutations { try mutation.fingerprint.validateCurrent() }
    }

    private func rollbackIndexFiles(_ backups: [(original: URL, backup: URL)]) {
        for item in backups.reversed() where fileManager.fileExists(atPath: item.backup.path) {
            try? fileManager.removeItem(at: item.original)
            try? fileManager.moveItem(at: item.backup, to: item.original)
        }
    }

    private func rollbackQuarantinedFiles(_ files: [(original: URL, quarantine: URL)]) {
        for item in files.reversed() where fileManager.fileExists(atPath: item.quarantine.path) {
            try? fileManager.moveItem(at: item.quarantine, to: item.original)
        }
    }
}

private struct JSONLMutation {
    let fileURL: URL
    let output: Data
    let fingerprint: SessionFileFingerprint
}
