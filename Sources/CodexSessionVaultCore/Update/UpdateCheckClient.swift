import CryptoKit
import Foundation

public protocol UpdateTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

public enum UpdateCheckError: Error, Equatable, Sendable {
    case timeout
    case invalidConfiguration
}

public enum UpdateCheckResult: Equatable, Sendable {
    case available(manifest: ReleaseManifest, artifact: ReleaseArtifact)
    case upToDate
    case unavailable
    case invalid(message: String)
}

public struct URLSessionUpdateTransport: UpdateTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 5) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

public struct UpdateCheckClient: Sendable {
    private static let invalidMessage = "更新信息验证失败，请联系管理员"

    private let baseURL: URL
    private let publicKeyData: Data
    private let transport: any UpdateTransport
    private let timeout: Duration

    public init(
        baseURL: URL,
        publicKey: Data,
        transport: any UpdateTransport,
        timeout: Duration = .seconds(5)
    ) {
        self.baseURL = baseURL
        self.publicKeyData = publicKey
        self.transport = transport
        self.timeout = timeout
    }

    public func check(
        currentVersion: String,
        currentBuild: Int,
        platform: UpdatePlatform
    ) async -> UpdateCheckResult {
        let fetched: FetchedUpdateData
        do {
            fetched = try await fetchWithDeadline()
        } catch {
            return .unavailable
        }

        do {
            guard publicKeyData.count == 32 else {
                throw UpdateCheckError.invalidConfiguration
            }
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            let signature = try decodeSignature(fetched.signature)
            guard publicKey.isValidSignature(signature, for: fetched.manifest) else {
                return .invalid(message: Self.invalidMessage)
            }

            let manifest = try ReleaseManifest.decodeValidated(from: fetched.manifest)
            let artifact = try manifest.artifact(for: platform)
            let remoteVersion = try SemanticVersion(manifest.version)
            let localVersion = try SemanticVersion(currentVersion)

            if remoteVersion > localVersion
                || (remoteVersion == localVersion && manifest.build > currentBuild) {
                return .available(manifest: manifest, artifact: artifact)
            }
            if remoteVersion == localVersion && manifest.build == currentBuild {
                return .upToDate
            }
            return .invalid(message: Self.invalidMessage)
        } catch {
            return .invalid(message: Self.invalidMessage)
        }
    }

    private func fetchWithDeadline() async throws -> FetchedUpdateData {
        try await withThrowingTaskGroup(of: FetchRaceResult.self) { group in
            group.addTask {
                let manifestURL = baseURL.appendingPathComponent("release.json")
                let signatureURL = baseURL.appendingPathComponent("release.json.sig")
                let manifest = try await transport.data(from: manifestURL)
                try Task.checkCancellation()
                let signature = try await transport.data(from: signatureURL)
                return .fetched(FetchedUpdateData(manifest: manifest, signature: signature))
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }

            guard let first = try await group.next() else {
                throw UpdateCheckError.invalidConfiguration
            }
            group.cancelAll()
            switch first {
            case .fetched(let data):
                return data
            case .timedOut:
                throw UpdateCheckError.timeout
            }
        }
    }

    private func decodeSignature(_ data: Data) throws -> Data {
        guard let encoded = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let decoded = Data(base64Encoded: encoded),
              decoded.count == 64,
              decoded.base64EncodedString() == encoded else {
            throw UpdateCheckError.invalidConfiguration
        }
        return decoded
    }
}

private struct FetchedUpdateData: Sendable {
    let manifest: Data
    let signature: Data
}

private enum FetchRaceResult: Sendable {
    case fetched(FetchedUpdateData)
    case timedOut
}
