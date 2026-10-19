import Foundation
import Darwin

public enum DeviceAccess: String, Codable, Sendable { case pending, allowed, denied }

public struct MobileDevice: Identifiable, Sendable {
    public var id: String { address }
    public let address: String
    public let access: DeviceAccess
    public let lastSeen: Date
}

public actor MobileAccess {
    private var enabled = false
    private var devices: [String: MobileDevice] = [:]

    public init() {}
    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { devices.removeAll() }
    }

    public func authorize(address: String) -> Bool {
        if Self.isLoopback(address) { return true }
        guard enabled, Self.isLAN(address) else { return false }
        let existing = devices[address]
        guard existing != nil || devices.count < 100 else { return false }
        let access = existing?.access ?? .pending
        devices[address] = MobileDevice(address: address, access: access, lastSeen: Date())
        return access == .allowed
    }

    public func setAccess(_ access: DeviceAccess, address: String) {
        guard enabled, Self.isLAN(address), devices[address] != nil else { return }
        devices[address] = MobileDevice(address: address, access: access, lastSeen: devices[address]!.lastSeen)
    }

    public func listDevices() -> [MobileDevice] { devices.values.sorted { $0.lastSeen > $1.lastSeen } }

    public nonisolated static func isLoopback(_ address: String) -> Bool {
        address == "::1" || (validIPv4(address) && address.hasPrefix("127."))
    }

    public nonisolated static func isLAN(_ address: String) -> Bool {
        guard validIPv4(address) else { return false }
        let bytes = address.split(separator: ".").compactMap { Int($0) }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254) ||
            (bytes[0] == 100 && (64...127).contains(bytes[1]))
    }

    private nonisolated static func validIPv4(_ address: String) -> Bool {
        var ip = in_addr()
        return inet_pton(AF_INET, address, &ip) == 1
    }
}

public struct LANAddress: Identifiable, Hashable, Sendable {
    public var id: String { "\(interface):\(address)" }
    public let interface: String
    public let address: String

    public static func available() -> [LANAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var result: [LANAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let item = entry.pointee
            guard let socketAddress = item.ifa_addr, socketAddress.pointee.sa_family == UInt8(AF_INET),
                  item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard MobileAccess.isLAN(address) else { continue }
            result.append(LANAddress(interface: String(cString: item.ifa_name), address: address))
        }
        return result.sorted {
            let left = $0.interface.hasPrefix("en") ? 0 : 1
            let right = $1.interface.hasPrefix("en") ? 0 : 1
            return left == right ? $0.id < $1.id : left < right
        }
    }
}
