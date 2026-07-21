import CryptoKit
import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite
struct UpdateCheckClientTests {
    private let baseURL = URL(
        string: "http://192.168.10.99:18080/codex-session-keeper/stable/"
    )!

    @Test
    func newerVersionIsAvailableAfterSignatureVerification() async throws {
        let fixture = try signedResponses()
        let client = UpdateCheckClient(
            baseURL: baseURL,
            publicKey: fixture.publicKey,
            transport: StubUpdateTransport(responses: fixture.responses),
            timeout: .seconds(5)
        )

        let result = await client.check(
            currentVersion: "1.0.99",
            currentBuild: 10099,
            platform: .macosArm64
        )

        guard case .available(let manifest, let artifact) = result else {
            Issue.record("Expected available update, got \(result)")
            return
        }
        #expect(manifest.version == "1.1.0")
        #expect(artifact.url.hasSuffix("macos-arm64.zip"))
    }

    @Test
    func equalVersionAndBuildIsUpToDate() async throws {
        let fixture = try signedResponses()
        let client = makeClient(fixture: fixture)

        #expect(await client.check(
            currentVersion: "1.1.0",
            currentBuild: 10100,
            platform: .macosArm64
        ) == .upToDate)
    }

    @Test
    func equalVersionWithHigherRemoteBuildIsAvailable() async throws {
        let fixture = try signedResponses(version: "1.1.0", build: 10101)
        let client = makeClient(fixture: fixture)

        guard case .available = await client.check(
            currentVersion: "1.1.0",
            currentBuild: 10100,
            platform: .macosArm64
        ) else {
            Issue.record("Expected higher build to be available")
            return
        }
    }

    @Test
    func downgradeIsRejectedAsInvalid() async throws {
        let fixture = try signedResponses(version: "1.0.99", build: 10099)
        let client = makeClient(fixture: fixture)

        #expect(await client.check(
            currentVersion: "1.1.0",
            currentBuild: 10100,
            platform: .macosArm64
        ) == .invalid(message: "更新信息验证失败，请联系管理员"))
    }

    @Test
    func tamperedManifestIsRejected() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let original = try manifestData()
        let signature = try privateKey.signature(for: original).base64EncodedData()
        var tampered = original
        tampered[tampered.startIndex] ^= 1
        let client = UpdateCheckClient(
            baseURL: baseURL,
            publicKey: privateKey.publicKey.rawRepresentation,
            transport: StubUpdateTransport(responses: [
                baseURL.appendingPathComponent("release.json"): tampered,
                baseURL.appendingPathComponent("release.json.sig"): signature
            ]),
            timeout: .seconds(5)
        )

        #expect(await client.check(
            currentVersion: "1.0.99",
            currentBuild: 10099,
            platform: .macosArm64
        ) == .invalid(message: "更新信息验证失败，请联系管理员"))
    }

    @Test
    func unavailableTransportIsSilent() async {
        let client = UpdateCheckClient(
            baseURL: baseURL,
            publicKey: Data(repeating: 0, count: 32),
            transport: FailingUpdateTransport(),
            timeout: .seconds(5)
        )

        #expect(await client.check(
            currentVersion: "1.0.99",
            currentBuild: 10099,
            platform: .macosArm64
        ) == .unavailable)
    }

    @Test
    func oneDeadlineCoversBothSequentialRequests() async throws {
        let fixture = try signedResponses()
        let client = UpdateCheckClient(
            baseURL: baseURL,
            publicKey: fixture.publicKey,
            transport: SlowUpdateTransport(
                responses: fixture.responses,
                delay: .milliseconds(40)
            ),
            timeout: .milliseconds(60)
        )
        let clock = ContinuousClock()
        let started = clock.now

        let result = await client.check(
            currentVersion: "1.0.99",
            currentBuild: 10099,
            platform: .macosArm64
        )

        #expect(result == .unavailable)
        #expect(started.duration(to: clock.now) < .milliseconds(100))
    }

    private func signedResponses(
        version: String = "1.1.0",
        build: Int = 10100
    ) throws -> SignedResponseFixture {
        let privateKey = Curve25519.Signing.PrivateKey()
        let data = try manifestData(version: version, build: build)
        let signature = try privateKey.signature(for: data).base64EncodedData()
        return SignedResponseFixture(
            publicKey: privateKey.publicKey.rawRepresentation,
            responses: [
                baseURL.appendingPathComponent("release.json"): data,
                baseURL.appendingPathComponent("release.json.sig"): signature
            ]
        )
    }

    private func makeClient(fixture: SignedResponseFixture) -> UpdateCheckClient {
        UpdateCheckClient(
            baseURL: baseURL,
            publicKey: fixture.publicKey,
            transport: StubUpdateTransport(responses: fixture.responses),
            timeout: .seconds(5)
        )
    }
}

private struct SignedResponseFixture: Sendable {
    let publicKey: Data
    let responses: [URL: Data]
}

private struct StubUpdateTransport: UpdateTransport {
    let responses: [URL: Data]

    func data(from url: URL) async throws -> Data {
        guard let data = responses[url] else { throw URLError(.fileDoesNotExist) }
        return data
    }
}

private struct SlowUpdateTransport: UpdateTransport {
    let responses: [URL: Data]
    let delay: Duration

    func data(from url: URL) async throws -> Data {
        try await Task.sleep(for: delay)
        guard let data = responses[url] else { throw URLError(.fileDoesNotExist) }
        return data
    }
}

private struct FailingUpdateTransport: UpdateTransport {
    func data(from url: URL) async throws -> Data {
        throw URLError(.cannotConnectToHost)
    }
}

