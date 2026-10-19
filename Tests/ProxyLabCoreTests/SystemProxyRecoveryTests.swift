import XCTest
@testable import ProxyLabCore

@MainActor
final class SystemProxyRecoveryTests: XCTestCase {
    func testAlreadyRestoredSnapshotIsClearedAndRepeatRestoreIsHarmless() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original: [String: Any] = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 8888]
        let snapshot = try makeSnapshot(in: directory, original: original)
        let manager = SystemProxyManager(snapshotURL: snapshot, configurationReader: { ["wifi": original] })
        XCTAssertTrue(manager.hasPendingRestore)
        try manager.restore()
        XCTAssertFalse(manager.hasPendingRestore)
        try manager.restore()
        XCTAssertFalse(manager.hasPendingRestore)
    }

    func testConflictPreservesSnapshotForRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try makeSnapshot(in: directory, original: [:])
        let changed: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "company.example", "HTTPPort": 8080]
        let manager = SystemProxyManager(snapshotURL: snapshot, configurationReader: { ["wifi": changed] })
        XCTAssertThrowsError(try manager.restore())
        XCTAssertTrue(manager.hasPendingRestore)
    }

    func testFailedApplyRemainsPendingUntilApplySucceeds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original: [String: Any] = ["HTTPEnable": 0]
        let snapshot = try makeSnapshot(in: directory, original: original)
        let value: [String: Any] = ["port": 8888, "services": ["wifi": original], "restoreNeedsApply": true]
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: snapshot)
        var attempts = 0
        let manager = SystemProxyManager(snapshotURL: snapshot, configurationReader: { ["wifi": original] },
                                        pendingApply: {
            attempts += 1
            if attempts == 1 { throw SystemProxyError.preferences(1003) }
        })
        XCTAssertThrowsError(try manager.restore())
        XCTAssertTrue(manager.hasPendingRestore)
        XCTAssertEqual(attempts, 1)
        try manager.restore()
        XCTAssertFalse(manager.hasPendingRestore)
        XCTAssertEqual(attempts, 2)
    }

    private func makeSnapshot(in directory: URL, original: [String: Any]) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("proxy-snapshot.plist")
        let value: [String: Any] = ["port": 8888, "services": ["wifi": original]]
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: url)
        return url
    }
}
