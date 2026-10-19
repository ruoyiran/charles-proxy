import XCTest
@testable import ProxyLabCore

final class SystemProxyPatcherTests: XCTestCase {
    func testEnablePreservesUnrelatedSettingsAndRestoreRecoversOriginal() throws {
        let original: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "corp.internal", "HTTPPort": 3128,
            "ExceptionsList": ["localhost", "*.internal"], "ProxyAutoConfigEnable": 1,
        ]
        let enabled = SystemProxyPatcher.enable(original, port: 8888)
        XCTAssertEqual(enabled["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(enabled["HTTPSPort"] as? Int, 8888)
        XCTAssertEqual(enabled["ProxyAutoConfigEnable"] as? Int, 0)
        XCTAssertEqual(enabled["ExceptionsList"] as? [String], ["localhost", "*.internal"])

        let restored = try XCTUnwrap(SystemProxyPatcher.restore(current: enabled, original: original, port: 8888))
        XCTAssertEqual(restored["HTTPProxy"] as? String, "corp.internal")
        XCTAssertNil(restored["HTTPSProxy"])
        XCTAssertEqual(restored["ProxyAutoConfigEnable"] as? Int, 1)
    }

    func testRestoreRefusesToOverwriteUsersLaterProxyChange() {
        let original: [String: Any] = ["HTTPEnable": 0]
        var current = SystemProxyPatcher.enable(original, port: 8888)
        current["HTTPProxy"] = "new.company.proxy"
        XCTAssertNil(SystemProxyPatcher.restore(current: current, original: original, port: 8888))
    }

    func testRestoreAcceptsOmittedDisabledPACFlags() {
        let original: [String: Any] = ["ProxyAutoConfigEnable": 1]
        var current = SystemProxyPatcher.enable(original, port: 8888)
        current.removeValue(forKey: "ProxyAutoConfigEnable")
        current.removeValue(forKey: "ProxyAutoDiscoveryEnable")
        let restored = SystemProxyPatcher.restore(current: current, original: original, port: 8888)
        XCTAssertEqual(restored?["ProxyAutoConfigEnable"] as? Int, 1)
    }
}
