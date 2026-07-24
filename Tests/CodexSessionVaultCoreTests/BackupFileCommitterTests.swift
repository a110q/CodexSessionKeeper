import Darwin
import Foundation
import Testing
@testable import CodexSessionVaultCore

@Test
func sourceInspectionUsesLstatIdentityAndStillRejectsSymlinks() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackupFileCommitterTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("session.jsonl")
    try Data("{}\n".utf8).write(to: source)
    var sourceStat = stat()
    #expect(lstat(source.path, &sourceStat) == 0)

    let metadata = try BackupFileCommitter().inspectSource(source)

    #expect(metadata.fileIdentity == "\(sourceStat.st_dev):\(sourceStat.st_ino)")

    let symlink = root.appendingPathComponent("linked.jsonl")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
    #expect(throws: BackupPathsError.self) {
        try BackupFileCommitter().inspectSource(symlink)
    }
}

@Test
func sourceInspectionRejectsPathReplacedAfterCachedRegularFileCheck() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackupFileCommitterTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("session.jsonl")
    let outside = root.appendingPathComponent("outside.jsonl")
    try Data("{}\n".utf8).write(to: source)
    try Data("{}\n".utf8).write(to: outside)
    _ = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    try FileManager.default.removeItem(at: source)
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)

    #expect(throws: BackupPathsError.self) {
        try BackupFileCommitter().inspectSource(source)
    }
}
