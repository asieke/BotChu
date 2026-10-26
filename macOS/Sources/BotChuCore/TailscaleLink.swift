import Foundation

/// Whether this Mac's Tailscale tunnel is up, read passively from its network interfaces: macOS
/// removes the tunnel's address from its `utun` interface when Tailscale disconnects or quits.
/// It never runs the `tailscale` CLI, whose macOS app version starts the VPN session to answer,
/// so checking can't undo a disconnect the owner chose.
public enum TailscaleLink {
    public struct Address: Equatable, Sendable {
        public var interface: String
        public var address: String
        public init(interface: String, address: String) { self.interface = interface; self.address = address }
    }

    /// Where Tailscale's app or daemon is installed on a Mac.
    public static let installPaths = [
        "/Applications/Tailscale.app", "/usr/local/bin/tailscaled", "/opt/homebrew/bin/tailscaled",
    ]

    /// An address Tailscale assigns: IPv4 in 100.64.0.0/10, or IPv6 in fd7a:115c:a1e0::/48.
    public static func isTailscaleAddress(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return bytes[0] == 100 && bytes[1] & 0xC0 == 64
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address.split(separator: "%").first.map(String.init) ?? address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        return bytes.prefix(6).elementsEqual([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
    }

    /// Whether a tunnel interface holds a Tailscale address. Only `utun` counts, so a carrier's
    /// 100.64/10 address on Wi-Fi isn't taken for Tailscale.
    public static func isUp(_ addresses: [Address]) -> Bool {
        addresses.contains { $0.interface.hasPrefix("utun") && isTailscaleAddress($0.address) }
    }

    /// Whether the remote queue is served through Tailscale: on loopback, behind Funnel as its
    /// setup describes, or on this Mac's Tailscale address.
    public static func servesThroughTailscale(listenAddress: String) -> Bool {
        let address = listenAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return address == "::1" || address == "localhost" || address.hasPrefix("127.") || isTailscaleAddress(address)
    }

    /// True when the remote runtime can't reach a queue served through Tailscale because
    /// Tailscale is installed but disconnected on this Mac.
    public static func isDisconnected(listenAddress: String, installed: Bool, addresses: [Address]) -> Bool {
        installed && servesThroughTailscale(listenAddress: listenAddress) && !isUp(addresses)
    }

    public static var isInstalled: Bool { installPaths.contains { FileManager.default.fileExists(atPath: $0) } }

    /// This Mac's interface addresses that are up, numeric.
    public static func interfaceAddresses() -> [Address] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var result: [Address] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, let socket = entry.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(socket.pointee.sa_family)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append(Address(interface: String(cString: entry.ifa_name), address: name))
        }
        return result
    }
}
