import XCTest
@testable import ProxyLabCore

final class MobileAccessTests: XCTestCase {
    func testLocalhostIsAlwaysAllowedButLANRequiresExplicitApproval() async {
        let access = MobileAccess()
        let local = await access.authorize(address: "127.0.0.1")
        let disabled = await access.authorize(address: "192.168.1.20")
        XCTAssertTrue(local)
        XCTAssertFalse(disabled)
        await access.setEnabled(true)
        let first = await access.authorize(address: "192.168.1.20")
        XCTAssertFalse(first)
        let devices = await access.listDevices()
        XCTAssertEqual(devices.first?.address, "192.168.1.20")
        XCTAssertEqual(devices.first?.access, .pending)
        await access.setAccess(.allowed, address: "192.168.1.20")
        let allowed = await access.authorize(address: "192.168.1.20")
        XCTAssertTrue(allowed)
        await access.setAccess(.denied, address: "192.168.1.20")
        let denied = await access.authorize(address: "192.168.1.20")
        XCTAssertFalse(denied)
    }

    func testDisableRevokesApprovalsAndRepeatedAttemptsStayOneDevice() async {
        let access = MobileAccess()
        await access.setEnabled(true)
        for _ in 0..<4 { _ = await access.authorize(address: "10.0.0.20") }
        let devices = await access.listDevices()
        XCTAssertEqual(devices.count, 1)
        await access.setAccess(.allowed, address: "10.0.0.20")
        await access.setEnabled(false)
        await access.setEnabled(true)
        let stillAllowed = await access.authorize(address: "10.0.0.20")
        XCTAssertFalse(stillAllowed)
    }

    func testPublicAndInvalidAddressesAreNeverAllowed() async {
        let access = MobileAccess()
        await access.setEnabled(true)
        for address in ["8.8.8.8", "not-an-ip", "192.168.1.999"] {
            await access.setAccess(.allowed, address: address)
            let allowed = await access.authorize(address: address)
            XCTAssertFalse(allowed, address)
        }
    }
}
