import Foundation
import Testing
@testable import BotChuCore

struct TailscaleLinkTests {
    private typealias Address = TailscaleLink.Address
    /// The Mac's interfaces with Tailscale connected, and after Quit Tailscale, when macOS removed
    /// the tunnel's IPv4 address but kept the interface's link-local one (seen 2026-10-26).
    private let connected = [
        Address(interface: "lo0", address: "127.0.0.1"), Address(interface: "en0", address: "192.168.1.20"),
        Address(interface: "utun8", address: "fe80::d0bb:da6c:b2b2:ab90%utun8"), Address(interface: "utun8", address: "100.101.102.103"),
    ]
    private var quit: [Address] { connected.filter { $0.address != "100.101.102.103" } }

    @Test func tailscaleAddressesAreItsCGNATAndULARanges() {
        #expect(TailscaleLink.isTailscaleAddress("100.64.0.1"))
        #expect(TailscaleLink.isTailscaleAddress("100.127.255.254"))
        #expect(!TailscaleLink.isTailscaleAddress("100.128.0.1"))
        #expect(!TailscaleLink.isTailscaleAddress("100.63.0.1"))
        #expect(!TailscaleLink.isTailscaleAddress("10.0.0.1"))
        #expect(TailscaleLink.isTailscaleAddress("fd7a:115c:a1e0::401:c29f"))
        #expect(TailscaleLink.isTailscaleAddress("fd7a:115c:a1e0::1%utun8"))
        #expect(!TailscaleLink.isTailscaleAddress("fd7a:115c:a1e1::1"))
        #expect(!TailscaleLink.isTailscaleAddress("localhost"))
        #expect(!TailscaleLink.isTailscaleAddress(""))
    }

    @Test func upOnlyWithATunnelAddress() {
        #expect(TailscaleLink.isUp(connected))
        #expect(!TailscaleLink.isUp(quit))
        // A carrier's shared address on Wi-Fi isn't Tailscale.
        #expect(!TailscaleLink.isUp([Address(interface: "en0", address: "100.70.1.2")]))
        #expect(TailscaleLink.isUp([Address(interface: "utun3", address: "fd7a:115c:a1e0::5")]))
    }

    @Test func disconnectedOnlyForAQueueServedThroughTailscale() {
        #expect(TailscaleLink.isDisconnected(listenAddress: "127.0.0.1", installed: true, addresses: quit))
        #expect(TailscaleLink.isDisconnected(listenAddress: " ::1 ", installed: true, addresses: quit))
        #expect(TailscaleLink.isDisconnected(listenAddress: "100.101.102.103", installed: true, addresses: quit))
        #expect(!TailscaleLink.isDisconnected(listenAddress: "127.0.0.1", installed: true, addresses: connected))
        #expect(!TailscaleLink.isDisconnected(listenAddress: "127.0.0.1", installed: false, addresses: quit))
        #expect(!TailscaleLink.isDisconnected(listenAddress: "192.168.1.20", installed: true, addresses: quit))
    }

    @Test func readsThisMacsInterfaces() {
        let addresses = TailscaleLink.interfaceAddresses()
        #expect(addresses.contains { $0.interface.hasPrefix("lo") && $0.address == "127.0.0.1" })
        #expect(addresses.allSatisfy { !$0.address.isEmpty && !$0.interface.isEmpty })
    }
}
