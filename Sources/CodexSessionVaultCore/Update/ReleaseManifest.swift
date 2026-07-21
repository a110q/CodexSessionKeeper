import Foundation

public enum ReleaseManifestError: Error, Equatable, LocalizedError, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason):
            return "Invalid release manifest: \(reason)"
        }
    }
}

public enum UpdatePlatform: String, Codable, Sendable {
    case macosArm64 = "macos-arm64"
    case windowsX64 = "windows-x64"
}

public struct SemanticVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ value: String) throws {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else {
            throw ReleaseManifestError.invalid("version must use numeric X.Y.Z format")
        }
        let parsed = try components.map { component -> Int in
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  component == "0" || component.first != "0",
                  let number = Int(component) else {
                throw ReleaseManifestError.invalid("version must use numeric X.Y.Z format")
            }
            return number
        }
        self.major = parsed[0]
        self.minor = parsed[1]
        self.patch = parsed[2]
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public struct ReleaseArtifact: Codable, Equatable, Sendable {
    public let url: String
    public let size: Int64
    public let sha256: String

    public init(url: String, size: Int64, sha256: String) throws {
        self.url = url
        self.size = size
        self.sha256 = sha256
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        try requireExactKeys(container.allKeys, expected: ["url", "size", "sha256"], scope: "artifact")
        self.url = try container.decode(String.self, forKey: DynamicCodingKey("url"))
        self.size = try container.decode(Int64.self, forKey: DynamicCodingKey("size"))
        self.sha256 = try container.decode(String.self, forKey: DynamicCodingKey("sha256"))
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(url, forKey: DynamicCodingKey("url"))
        try container.encode(size, forKey: DynamicCodingKey("size"))
        try container.encode(sha256, forKey: DynamicCodingKey("sha256"))
    }

    fileprivate func validate() throws {
        guard size > 0 else {
            throw ReleaseManifestError.invalid("artifact size must be positive")
        }
        guard sha256.count == 64,
              sha256.unicodeScalars.allSatisfy({ scalar in
                  ("0"..."9").contains(Character(String(scalar)))
                      || ("a"..."f").contains(Character(String(scalar)))
              }) else {
            throw ReleaseManifestError.invalid("artifact sha256 must be 64 lowercase hexadecimal characters")
        }
        try validateRelativeArtifactURL(url)
    }
}

public struct ReleaseManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let channel: String
    public let version: String
    public let build: Int
    public let publishedAt: Date
    public let required: Bool
    public let notes: [String]
    public let platforms: [String: ReleaseArtifact]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        try requireExactKeys(
            container.allKeys,
            expected: [
                "schemaVersion", "channel", "version", "build",
                "publishedAt", "required", "notes", "platforms"
            ],
            scope: "top level"
        )
        self.schemaVersion = try container.decode(Int.self, forKey: DynamicCodingKey("schemaVersion"))
        self.channel = try container.decode(String.self, forKey: DynamicCodingKey("channel"))
        self.version = try container.decode(String.self, forKey: DynamicCodingKey("version"))
        self.build = try container.decode(Int.self, forKey: DynamicCodingKey("build"))
        let publishedAtString = try container.decode(String.self, forKey: DynamicCodingKey("publishedAt"))
        self.publishedAt = try parsePublishedAt(publishedAtString)
        self.required = try container.decode(Bool.self, forKey: DynamicCodingKey("required"))
        self.notes = try container.decode([String].self, forKey: DynamicCodingKey("notes"))
        self.platforms = try container.decode(
            [String: ReleaseArtifact].self,
            forKey: DynamicCodingKey("platforms")
        )
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(schemaVersion, forKey: DynamicCodingKey("schemaVersion"))
        try container.encode(channel, forKey: DynamicCodingKey("channel"))
        try container.encode(version, forKey: DynamicCodingKey("version"))
        try container.encode(build, forKey: DynamicCodingKey("build"))
        try container.encode(formatPublishedAt(publishedAt), forKey: DynamicCodingKey("publishedAt"))
        try container.encode(required, forKey: DynamicCodingKey("required"))
        try container.encode(notes, forKey: DynamicCodingKey("notes"))
        try container.encode(platforms, forKey: DynamicCodingKey("platforms"))
    }

    public static func decodeValidated(from data: Data) throws -> ReleaseManifest {
        do {
            return try JSONDecoder().decode(ReleaseManifest.self, from: data)
        } catch let error as ReleaseManifestError {
            throw error
        } catch {
            throw ReleaseManifestError.invalid("JSON does not match schema version 1")
        }
    }

    public func validated() throws -> ReleaseManifest {
        try validate()
        return self
    }

    public func artifact(for platform: UpdatePlatform) throws -> ReleaseArtifact {
        guard let artifact = platforms[platform.rawValue] else {
            throw ReleaseManifestError.invalid("missing artifact for \(platform.rawValue)")
        }
        return artifact
    }

    public func matchesSparkleItem(displayVersion: String, buildVersion: String) -> Bool {
        displayVersion == version && buildVersion == String(build)
    }

    private func validate() throws {
        guard schemaVersion == 1 else {
            throw ReleaseManifestError.invalid("schemaVersion must be 1")
        }
        guard channel == "stable" else {
            throw ReleaseManifestError.invalid("channel must be stable")
        }
        _ = try SemanticVersion(version)
        guard build > 0 else {
            throw ReleaseManifestError.invalid("build must be positive")
        }
        guard required == false else {
            throw ReleaseManifestError.invalid("required must be false")
        }
        guard notes.count <= 20 else {
            throw ReleaseManifestError.invalid("notes must contain at most 20 entries")
        }
        guard notes.allSatisfy({ $0.lengthOfBytes(using: .utf8) <= 500 }) else {
            throw ReleaseManifestError.invalid("every note must be at most 500 UTF-8 bytes")
        }
        let expectedPlatforms = Set([UpdatePlatform.macosArm64.rawValue, UpdatePlatform.windowsX64.rawValue])
        guard Set(platforms.keys) == expectedPlatforms else {
            throw ReleaseManifestError.invalid("platforms must contain macos-arm64 and windows-x64 only")
        }
        try platforms.values.forEach { try $0.validate() }
    }
}

private struct DynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

private func requireExactKeys(
    _ keys: [DynamicCodingKey],
    expected: Set<String>,
    scope: String
) throws {
    let actual = Set(keys.map(\.stringValue))
    guard actual == expected else {
        let unknown = actual.subtracting(expected).sorted()
        let missing = expected.subtracting(actual).sorted()
        if let field = unknown.first {
            throw ReleaseManifestError.invalid("unknown \(scope) field \(field)")
        }
        throw ReleaseManifestError.invalid("missing \(scope) fields \(missing.joined(separator: ", "))")
    }
}

private func validateRelativeArtifactURL(_ value: String) throws {
    guard !value.isEmpty,
          !value.hasPrefix("/"),
          !value.contains("\\"),
          !value.contains("?"),
          !value.contains("#"),
          URL(string: value)?.scheme == nil else {
        throw ReleaseManifestError.invalid("artifact url must be a safe relative URL")
    }
    let segments = value.split(separator: "/", omittingEmptySubsequences: false)
    guard !segments.contains(where: { $0.isEmpty }) else {
        throw ReleaseManifestError.invalid("artifact url must be a safe relative URL")
    }
    for segment in segments {
        guard let decoded = String(segment).removingPercentEncoding,
              decoded != ".",
              decoded != "..",
              !decoded.contains("/"),
              !decoded.contains("\\") else {
            throw ReleaseManifestError.invalid("artifact url must be a safe relative URL")
        }
    }
}

private func parsePublishedAt(_ value: String) throws -> Date {
    let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$"#
    guard value.range(of: pattern, options: .regularExpression) != nil else {
        throw ReleaseManifestError.invalid("publishedAt must be an ISO-8601 UTC timestamp")
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = value.contains(".")
        ? [.withInternetDateTime, .withFractionalSeconds]
        : [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
        throw ReleaseManifestError.invalid("publishedAt must be an ISO-8601 UTC timestamp")
    }
    return date
}

private func formatPublishedAt(_ value: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: value)
}
