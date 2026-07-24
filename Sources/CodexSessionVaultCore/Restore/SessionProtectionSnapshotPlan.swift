import Foundation

public struct SessionProtectionSnapshotPlan {
    public struct TrustedRollout: Sendable {
        public let sessionID: String
        public let sourceURL: URL
        public let destinationURL: URL
        public let relativePath: String
        public let fingerprint: SessionFileFingerprint

        fileprivate let destinationAbsence: SessionFileAbsenceExpectation
    }

    public struct LineOutput: Sendable {
        public let relativePath: String
        public let destinationURL: URL
        public let data: Data

        fileprivate let sourceFingerprint: SessionFileFingerprint
        fileprivate let destinationAbsence: SessionFileAbsenceExpectation
    }

    public let sessionIDs: Set<String>
    public let trustedRollouts: [TrustedRollout]
    public let lineOutputs: [LineOutput]
    public let missingSessionIDs: [String]

    private let fileManager: FileManager

    public static func preflight(
        sessionIDs: Set<String>,
        codexRoot: URL,
        destinationRoot: URL,
        fileManager: FileManager = .default
    ) throws -> SessionProtectionSnapshotPlan {
        let normalized = Set(sessionIDs.compactMap(SessionJSONLValidator.normalizeSessionID))
        let trusted = try TrustedSessionFileResolver.resolve(
            sessionIDs: normalized,
            under: codexRoot,
            fileManager: fileManager
        )
        let canonicalRoot = codexRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = canonicalRoot.path + "/"
        let trustedRollouts = try trusted.map { file in
            let canonicalSource = file.fileURL.standardizedFileURL.resolvingSymlinksInPath()
            guard canonicalSource.path.hasPrefix(rootPrefix) else {
                throw SessionJSONLValidationError(
                    fileURL: file.fileURL,
                    lineNumber: 1,
                    reason: "会话文件越出 Codex 目录"
                )
            }
            let relativePath = String(canonicalSource.path.dropFirst(rootPrefix.count))
            let destinationURL = destinationRoot.appendingPathComponent(relativePath)
            return TrustedRollout(
                sessionID: file.sessionID,
                sourceURL: canonicalSource,
                destinationURL: destinationURL,
                relativePath: relativePath,
                fingerprint: file.fingerprint,
                destinationAbsence: try SessionFileAbsenceExpectation.requireMissing(destinationURL)
            )
        }

        var lineOutputs: [LineOutput] = []
        for (name, kind) in [
            ("history.jsonl", SessionJSONLKind.history),
            ("history.jsonl.bak", SessionJSONLKind.historyBackup),
            ("session_index.jsonl", SessionJSONLKind.sessionIndex)
        ] {
            let sourceURL = codexRoot.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            let document = try SessionJSONLValidator.parse(sourceURL, kind: kind)
            var output = Data()
            var seen = Set<String>()
            for record in document.records where normalized.contains(record.sessionID) {
                let identity = kind == .sessionIndex
                    ? record.sessionID
                    : record.rawData.base64EncodedString()
                guard seen.insert(identity).inserted else { continue }
                output.append(record.rawData)
                output.append(0x0A)
            }
            let destinationURL = destinationRoot.appendingPathComponent(name)
            lineOutputs.append(LineOutput(
                relativePath: name,
                destinationURL: destinationURL,
                data: output,
                sourceFingerprint: document.fingerprint,
                destinationAbsence: try SessionFileAbsenceExpectation.requireMissing(destinationURL)
            ))
        }

        let found = Set(trustedRollouts.map(\.sessionID))
        return SessionProtectionSnapshotPlan(
            sessionIDs: normalized,
            trustedRollouts: trustedRollouts,
            lineOutputs: lineOutputs,
            missingSessionIDs: normalized.subtracting(found).sorted(),
            fileManager: fileManager
        )
    }

    public func validateCurrent(requireMissingDestinations: Bool = true) throws {
        for rollout in trustedRollouts {
            try rollout.fingerprint.validateCurrent()
            if requireMissingDestinations { try rollout.destinationAbsence.validateCurrent() }
        }
        for output in lineOutputs {
            try output.sourceFingerprint.validateCurrent()
            if requireMissingDestinations { try output.destinationAbsence.validateCurrent() }
        }
    }

    @discardableResult
    public func materialize(
        writer: DurableAtomicWriter = DurableAtomicWriter()
    ) throws -> Set<String> {
        try validateCurrent()
        var createdFiles: [URL] = []
        do {
            for output in lineOutputs {
                try writer.writeIfAbsent(
                    output.data,
                    to: output.destinationURL,
                    permissions: 0o600,
                    createParentDirectories: true
                )
                createdFiles.append(output.destinationURL)
            }

            for rollout in trustedRollouts {
                try rollout.fingerprint.validateCurrent()
                try rollout.destinationAbsence.validateCurrent()
                try fileManager.createDirectory(
                    at: rollout.destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let temporaryURL = rollout.destinationURL.deletingLastPathComponent().appendingPathComponent(
                    ".\(rollout.destinationURL.lastPathComponent).protection-\(UUID().uuidString)"
                )
                defer { try? fileManager.removeItem(at: temporaryURL) }
                try fileManager.copyItem(at: rollout.sourceURL, to: temporaryURL)
                let handle = try FileHandle(forWritingTo: temporaryURL)
                defer { try? handle.close() }
                try handle.synchronize()
                try rollout.fingerprint.validateContent(at: temporaryURL)
                try rollout.fingerprint.validateCurrent()
                try fileManager.linkItem(at: temporaryURL, to: rollout.destinationURL)
                createdFiles.append(rollout.destinationURL)
            }

            try validateCurrent(requireMissingDestinations: false)
        } catch {
            for fileURL in createdFiles.reversed() { try? fileManager.removeItem(at: fileURL) }
            throw error
        }

        var includedPaths = Set(lineOutputs.map(\.relativePath))
        for rollout in trustedRollouts {
            includedPaths.insert(rollout.relativePath.split(separator: "/").first.map(String.init) ?? "sessions")
        }
        return includedPaths
    }
}
