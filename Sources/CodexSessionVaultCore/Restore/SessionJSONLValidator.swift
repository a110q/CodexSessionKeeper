import CryptoKit
import Darwin
import Foundation

public enum SessionJSONLKind: Equatable, Sendable {
    case history
    case historyBackup
    case sessionIndex

    fileprivate var identityKey: String {
        switch self {
        case .history, .historyBackup: "session_id"
        case .sessionIndex: "id"
        }
    }
}

public struct SessionJSONLValidationError: Error, LocalizedError, Equatable, Sendable {
    public let fileURL: URL
    public let lineNumber: Int
    public let reason: String
    public let code = "INVALID_SESSION_JSONL"

    public init(fileURL: URL, lineNumber: Int, reason: String) {
        self.fileURL = fileURL
        self.lineNumber = lineNumber
        self.reason = reason
    }

    public var errorDescription: String? {
        "\(fileURL.path) 第 \(lineNumber) 行无效：\(reason)"
    }
}

public struct SessionFileFingerprint: Equatable, Sendable {
    public let fileURL: URL
    public let fileIdentity: String
    public let size: UInt64
    public let modificationDate: Date
    public let sha256: String

    public func validateCurrent() throws {
        let current = try SessionJSONLScanner.scan(fileURL).fingerprint
        guard current == self else {
            throw SessionJSONLValidationError(
                fileURL: fileURL,
                lineNumber: 1,
                reason: "文件在预检后发生变化"
            )
        }
    }

    public func validateContent(at candidateURL: URL) throws {
        let candidate = try SessionJSONLScanner.scan(candidateURL).fingerprint
        guard candidate.size == size, candidate.sha256 == sha256 else {
            throw SessionJSONLValidationError(
                fileURL: candidateURL,
                lineNumber: 1,
                reason: "复制内容与预检文件不一致"
            )
        }
    }

    public func validateRelocated(at candidateURL: URL) throws {
        let candidate = try SessionJSONLScanner.scan(candidateURL).fingerprint
        guard candidate.fileIdentity == fileIdentity,
              candidate.size == size,
              candidate.modificationDate == modificationDate,
              candidate.sha256 == sha256 else {
            throw SessionJSONLValidationError(
                fileURL: candidateURL,
                lineNumber: 1,
                reason: "隔离文件与预检身份或内容不一致"
            )
        }
    }
}

public struct SessionFileAbsenceExpectation: Equatable, Sendable {
    public let fileURL: URL

    public static func requireMissing(_ fileURL: URL) throws -> SessionFileAbsenceExpectation {
        let expectation = SessionFileAbsenceExpectation(fileURL: fileURL.standardizedFileURL)
        try expectation.validateCurrent()
        return expectation
    }

    public func validateCurrent() throws {
        var information = stat()
        if lstat(fileURL.path, &information) == 0 {
            throw SessionJSONLValidationError(
                fileURL: fileURL,
                lineNumber: 1,
                reason: "文件在预检后被新建"
            )
        }
        guard errno == ENOENT else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

public struct SessionJSONLRecord: Sendable {
    public let lineNumber: Int
    public let rawData: Data
    public let sessionID: String
}

public struct SessionJSONLDocument: Sendable {
    public let records: [SessionJSONLRecord]
    public let fingerprint: SessionFileFingerprint
}

public enum SessionJSONLValidator {
    public static func parse(_ fileURL: URL, kind: SessionJSONLKind) throws -> SessionJSONLDocument {
        var records: [SessionJSONLRecord] = []
        let result = try SessionJSONLScanner.scan(fileURL) { lineNumber, data, object in
            let sessionID = try schemaSessionID(
                object,
                expectedKey: kind.identityKey,
                fileURL: fileURL,
                lineNumber: lineNumber
            )
            records.append(SessionJSONLRecord(
                lineNumber: lineNumber,
                rawData: data,
                sessionID: sessionID
            ))
        }
        return SessionJSONLDocument(records: records, fingerprint: result.fingerprint)
    }

    public static func normalizeSessionID(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.isEmpty,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains("\0") else {
            return nil
        }
        if value.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return value.lowercased()
        }
        return value
    }

    fileprivate static func schemaSessionID(
        _ object: [String: Any],
        expectedKey: String,
        fileURL: URL,
        lineNumber: Int
    ) throws -> String {
        guard let expected = normalizeSessionID(object[expectedKey]) else {
            throw SessionJSONLValidationError(
                fileURL: fileURL,
                lineNumber: lineNumber,
                reason: "缺少有效的顶层 \(expectedKey)"
            )
        }
        for alternateKey in ["id", "session_id"] where alternateKey != expectedKey {
            guard object[alternateKey] != nil,
                  let alternate = normalizeSessionID(object[alternateKey]) else {
                continue
            }
            if alternate != expected {
                throw SessionJSONLValidationError(
                    fileURL: fileURL,
                    lineNumber: lineNumber,
                    reason: "包含冲突的顶层会话身份"
                )
            }
        }
        return expected
    }
}

public enum SessionJSONLRestoreOutput {
    public static func build(
        source: [SessionJSONLRecord],
        destination: [SessionJSONLRecord],
        sessionIDs: Set<String>,
        uniqueBySessionID: Bool,
        replace: Bool
    ) -> Data {
        let selected = Set(sessionIDs.compactMap(SessionJSONLValidator.normalizeSessionID))
        var records = replace ? [] : destination
        var seen = Set<String>()
        for record in records {
            seen.insert(uniqueBySessionID ? record.sessionID : record.rawData.base64EncodedString())
        }
        for record in source where selected.contains(record.sessionID) {
            let identity = uniqueBySessionID ? record.sessionID : record.rawData.base64EncodedString()
            if seen.insert(identity).inserted { records.append(record) }
        }
        var output = Data()
        for record in records {
            output.append(record.rawData)
            output.append(0x0A)
        }
        return output
    }
}

public struct TrustedSessionFile: Equatable, Sendable {
    public let sessionID: String
    public let fileURL: URL
    public let fingerprint: SessionFileFingerprint
}

public struct TrustedSessionFileReference: Equatable, Sendable {
    public let sessionID: String
    public let fileURL: URL
}

public enum TrustedSessionFileResolver {
    public static func validate(
        _ fileURL: URL,
        expectedSessionID: String,
        under codexRoot: URL,
        fileManager: FileManager = .default
    ) throws -> SessionFileFingerprint {
        let normalized = SessionJSONLValidator.normalizeSessionID(expectedSessionID)
        guard let normalized else { throw untrusted(fileURL, "会话 ID 无效") }
        try validateRoot(codexRoot, fileManager: fileManager)
        let values = try fileURL.resourceValues(forKeys: [
            .isSymbolicLinkKey,
            .isRegularFileKey
        ])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw untrusted(fileURL, "不是普通文件")
        }
        return try validateRollout(
            fileURL,
            expectedSessionID: normalized,
            under: codexRoot.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    public static func discover(
        under codexRoot: URL,
        fileManager: FileManager = .default
    ) throws -> [TrustedSessionFileReference] {
        try validateRoot(codexRoot, fileManager: fileManager)
        let canonicalRoot = codexRoot.standardizedFileURL.resolvingSymlinksInPath()
        var result: [TrustedSessionFileReference] = []
        for directoryName in ["sessions", "archived_sessions"] {
            let directory = codexRoot.appendingPathComponent(directoryName, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            try walk(directory, root: canonicalRoot, fileManager: fileManager) { fileURL in
                guard fileURL.pathExtension.lowercased() == "jsonl",
                      let sessionID = try? firstRolloutSessionID(fileURL) else {
                    return
                }
                result.append(TrustedSessionFileReference(sessionID: sessionID, fileURL: fileURL))
            }
        }
        return result.sorted {
            if $0.sessionID == $1.sessionID { return $0.fileURL.path < $1.fileURL.path }
            return $0.sessionID < $1.sessionID
        }
    }

    public static func resolve(
        sessionIDs: Set<String>,
        under codexRoot: URL,
        fileManager: FileManager = .default
    ) throws -> [TrustedSessionFile] {
        let selected = Set(sessionIDs.compactMap(SessionJSONLValidator.normalizeSessionID))
        guard !selected.isEmpty else { return [] }
        try validateRoot(codexRoot, fileManager: fileManager)
        let canonicalRoot = codexRoot.standardizedFileURL.resolvingSymlinksInPath()
        var result: [TrustedSessionFile] = []

        for directoryName in ["sessions", "archived_sessions"] {
            let directory = codexRoot.appendingPathComponent(directoryName, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            try walk(directory, root: canonicalRoot, fileManager: fileManager) { fileURL in
                guard fileURL.pathExtension.lowercased() == "jsonl",
                      let firstID = try? firstRolloutSessionID(fileURL),
                      selected.contains(firstID) else {
                    return
                }
                let fingerprint = try validateRollout(
                    fileURL,
                    expectedSessionID: firstID,
                    under: canonicalRoot
                )
                result.append(TrustedSessionFile(
                    sessionID: firstID,
                    fileURL: fileURL.standardizedFileURL.resolvingSymlinksInPath(),
                    fingerprint: fingerprint
                ))
            }
        }

        return result.sorted {
            if $0.sessionID == $1.sessionID { return $0.fileURL.path < $1.fileURL.path }
            return $0.sessionID < $1.sessionID
        }
    }

    public static func resolve(
        sessionIDs: [String],
        under codexRoot: URL,
        fileManager: FileManager = .default
    ) throws -> [TrustedSessionFile] {
        try resolve(sessionIDs: Set(sessionIDs), under: codexRoot, fileManager: fileManager)
    }

    private static func validateRoot(_ root: URL, fileManager: FileManager) throws {
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw RestoreFilesystemValidationError.unsafePath(root.path)
        }
    }

    private static func walk(
        _ directory: URL,
        root: URL,
        fileManager: FileManager,
        visit: (URL) throws -> Void
    ) throws {
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { return }
        for child in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        ) {
            let childValues = try child.resourceValues(forKeys: [
                .isSymbolicLinkKey,
                .isDirectoryKey,
                .isRegularFileKey
            ])
            if childValues.isSymbolicLink == true { continue }
            if childValues.isDirectory == true {
                try walk(child, root: root, fileManager: fileManager, visit: visit)
            } else if childValues.isRegularFile == true {
                let canonical = child.standardizedFileURL.resolvingSymlinksInPath()
                guard isDescendant(canonical, of: root) else { continue }
                try visit(canonical)
            }
        }
    }

    private static func firstRolloutSessionID(_ fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var line = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(chunk.prefix(upTo: newline))
                break
            }
            line.append(chunk)
            guard line.count <= SessionJSONLScanner.maximumLineBytes else {
                throw untrusted(fileURL, "首行超过 32 MiB")
            }
        }
        if line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw untrusted(fileURL, "首条记录不是有效 JSON")
        }
        return try rolloutSessionID(object, fileURL: fileURL)
    }

    private static func validateRollout(
        _ fileURL: URL,
        expectedSessionID: String,
        under root: URL
    ) throws -> SessionFileFingerprint {
        let canonical = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let isInsideSessionDirectory = ["sessions", "archived_sessions"].contains { directory in
            isDescendant(canonical, of: root.appendingPathComponent(directory, isDirectory: true))
        }
        guard isDescendant(canonical, of: root),
              isInsideSessionDirectory,
              canonical.pathExtension.lowercased() == "jsonl" else {
            throw untrusted(fileURL, "路径越出 Codex 会话目录")
        }
        var firstID: String?
        let result = try SessionJSONLScanner.scan(canonical) { lineNumber, _, object in
            if lineNumber == 1 { firstID = try rolloutSessionID(object, fileURL: canonical) }
        }
        guard firstID == expectedSessionID else {
            throw untrusted(canonical, "session_meta.payload.id 不匹配")
        }
        return result.fingerprint
    }

    private static func rolloutSessionID(_ object: [String: Any], fileURL: URL) throws -> String {
        guard object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let sessionID = SessionJSONLValidator.normalizeSessionID(payload["id"]) else {
            throw untrusted(fileURL, "首条记录不是可信 session_meta")
        }
        return sessionID
    }

    private static func untrusted(_ fileURL: URL, _ reason: String) -> NSError {
        NSError(
            domain: "UNTRUSTED_SESSION_FILE",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "\(fileURL.path)：\(reason)",
                "code": "UNTRUSTED_SESSION_FILE"
            ]
        )
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count > rootComponents.count
            && candidateComponents.starts(with: rootComponents)
    }
}

enum SessionJSONLScanner {
    static let maximumLineBytes = 32 * 1024 * 1024

    struct Result {
        let fingerprint: SessionFileFingerprint
    }

    static func scan(
        _ fileURL: URL,
        onRecord: ((Int, Data, [String: Any]) throws -> Void)? = nil
    ) throws -> Result {
        let values = try fileURL.resourceValues(forKeys: [
            .isSymbolicLinkKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw SessionJSONLValidationError(fileURL: fileURL, lineNumber: 1, reason: "不是普通文件")
        }
        let initialIdentity = values.fileResourceIdentifier.map { String(describing: $0) } ?? ""
        let initialSize = values.fileSize ?? 0
        let initialModificationDate = values.contentModificationDate ?? .distantPast
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var digest = SHA256()
        var pending = Data()
        var lineNumber = 0
        var totalBytes = 0

        func consume(_ input: Data) throws {
            lineNumber += 1
            var line = input
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else {
                throw SessionJSONLValidationError(
                    fileURL: fileURL,
                    lineNumber: lineNumber,
                    reason: "文件中包含空白行"
                )
            }
            guard line.count <= maximumLineBytes else {
                throw SessionJSONLValidationError(
                    fileURL: fileURL,
                    lineNumber: lineNumber,
                    reason: "单行超过 32 MiB"
                )
            }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                throw SessionJSONLValidationError(
                    fileURL: fileURL,
                    lineNumber: lineNumber,
                    reason: "不是有效 UTF-8 JSON 对象"
                )
            }
            try onRecord?(lineNumber, line, object)
        }

        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            totalBytes += chunk.count
            digest.update(data: chunk)
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                try consume(Data(pending.prefix(upTo: newline)))
                pending.removeSubrange(...newline)
            }
            guard pending.count <= maximumLineBytes else {
                throw SessionJSONLValidationError(
                    fileURL: fileURL,
                    lineNumber: lineNumber + 1,
                    reason: "单行超过 32 MiB"
                )
            }
        }
        if !pending.isEmpty { try consume(pending) }

        let currentValues = try fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        let identity = currentValues.fileResourceIdentifier.map { String(describing: $0) } ?? ""
        let currentSize = currentValues.fileSize ?? 0
        let currentModificationDate = currentValues.contentModificationDate ?? .distantPast
        guard identity == initialIdentity,
              currentSize == initialSize,
              currentModificationDate == initialModificationDate,
              totalBytes == currentSize else {
            throw SessionJSONLValidationError(
                fileURL: fileURL,
                lineNumber: 1,
                reason: "文件在读取期间发生变化"
            )
        }
        let fingerprint = SessionFileFingerprint(
            fileURL: fileURL.standardizedFileURL.resolvingSymlinksInPath(),
            fileIdentity: identity,
            size: UInt64(currentSize),
            modificationDate: currentModificationDate,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()
        )
        return Result(fingerprint: fingerprint)
    }
}
