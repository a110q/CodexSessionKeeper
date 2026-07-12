import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct CompanyNASLocatorTests {
    @Test
    func productionEndpointIsFixedToCompanyShare() {
        let endpoint = CompanyNASEndpoint.production

        #expect(endpoint.server == "192.168.10.99")
        #expect(endpoint.share == "文件中转站")
        #expect(endpoint.backupRootName == "codex会话备份")
    }

    @Test
    func locatesTrustedRootFromMatchingSMBMountMetadata() throws {
        let fixture = try CompanyNASLocatorFixture()
        defer { fixture.cleanup() }
        try fixture.createTrustedRoot()

        let mount = try fixture.makeLocator(remountURL: fixture.companyRemountURL).locate()

        #expect(mount.mountRootURL.standardizedFileURL == fixture.mountRoot.standardizedFileURL)
        #expect(mount.trustedRootURL.standardizedFileURL == fixture.trustedRoot.standardizedFileURL)
    }

    @Test
    func rejectsSameNamedLocalLookalikeWithoutSMBMetadata() throws {
        let fixture = try CompanyNASLocatorFixture()
        defer { fixture.cleanup() }
        try fixture.createTrustedRoot()
        let locator = CompanyNASLocator(
            mountedVolumes: {
                [NASMountedVolume(rootURL: fixture.mountRoot, remountURL: nil)]
            }
        )

        #expect(throws: CompanyNASLocatorError.notConnected) {
            try locator.locate()
        }
    }

    @Test(arguments: [
        "smb://171@192.168.10.98/%E6%96%87%E4%BB%B6%E4%B8%AD%E8%BD%AC%E7%AB%99",
        "smb://171@192.168.10.99/%E5%85%AC%E5%85%B1%E6%96%87%E4%BB%B6%E5%A4%B9",
        "afp://171@192.168.10.99/%E6%96%87%E4%BB%B6%E4%B8%AD%E8%BD%AC%E7%AB%99"
    ])
    func rejectsWrongServerShareOrProtocol(remountURLString: String) throws {
        let fixture = try CompanyNASLocatorFixture()
        defer { fixture.cleanup() }
        try fixture.createTrustedRoot()
        let remountURL = try #require(URL(string: remountURLString))

        #expect(throws: CompanyNASLocatorError.notConnected) {
            try fixture.makeLocator(remountURL: remountURL).locate()
        }
    }

    @Test
    func rejectsMissingTrustedRoot() throws {
        let fixture = try CompanyNASLocatorFixture()
        defer { fixture.cleanup() }

        #expect(throws: CompanyNASLocatorError.trustedRootMissing(fixture.trustedRoot.path)) {
            try fixture.makeLocator(remountURL: fixture.companyRemountURL).locate()
        }
    }

    @Test
    func rejectsSymbolicLinkTrustedRoot() throws {
        let fixture = try CompanyNASLocatorFixture()
        defer { fixture.cleanup() }
        let outside = fixture.tempRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.trustedRoot, withDestinationURL: outside)

        #expect(throws: CompanyNASLocatorError.invalidTrustedRoot(fixture.trustedRoot.path)) {
            try fixture.makeLocator(remountURL: fixture.companyRemountURL).locate()
        }
    }
}

private final class CompanyNASLocatorFixture {
    let tempRoot: URL
    let mountRoot: URL
    let trustedRoot: URL
    let companyRemountURL: URL

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompanyNASLocatorTests-\(UUID().uuidString)", isDirectory: true)
        mountRoot = tempRoot.appendingPathComponent("文件中转站", isDirectory: true)
        trustedRoot = mountRoot.appendingPathComponent("codex会话备份", isDirectory: true)
        companyRemountURL = try #require(URL(string: "smb://171@192.168.10.99/%E6%96%87%E4%BB%B6%E4%B8%AD%E8%BD%AC%E7%AB%99"))
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
    }

    func createTrustedRoot() throws {
        try FileManager.default.createDirectory(at: trustedRoot, withIntermediateDirectories: true)
    }

    func makeLocator(remountURL: URL) -> CompanyNASLocator {
        CompanyNASLocator(
            mountedVolumes: {
                [NASMountedVolume(rootURL: self.mountRoot, remountURL: remountURL)]
            }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempRoot)
    }
}
