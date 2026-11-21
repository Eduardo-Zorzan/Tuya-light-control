import Darwin
import Foundation
import Testing

@testable import TuyaLocal

@Suite("Discovery decoding")
struct DiscoveryDecodingTests {
    @Test func plainBroadcastOnPort6666() throws {
        let d = try #require(DiscoveryDecoder.decode(Data(hex: UDPVectors.plain6666)))
        #expect(d == DiscoveredDevice(deviceID: "bf1234567890abcdefxyz1", ip: "192.168.0.20", version: .v33, productKey: "keyabc123"))
    }

    @Test func encryptedBroadcastOnPort6667() throws {
        let d = try #require(DiscoveryDecoder.decode(Data(hex: UDPVectors.enc6667)))
        #expect(d.deviceID == "bf9999999999abcdefxyz2")
        #expect(d.ip == "192.168.0.31")
        #expect(d.version == .v34)
    }

    @Test(arguments: [UDPVectors.gcm7000, UDPVectors.gcm7000NoRetcode])
    func gcmBroadcastOnPort7000(hex: String) throws {
        let d = try #require(DiscoveryDecoder.decode(Data(hex: hex)))
        #expect(d.deviceID == "bf5555555555abcdefxyz3")
        #expect(d.ip == "192.168.0.44")
        #expect(d.version == .v35)
    }

    @Test func udpKeyMatchesTinytuya() {
        #expect(DiscoveryDecoder.udpKey.hex == UDPVectors.udpKey)
    }

    @Test func garbageIsIgnored() {
        #expect(DiscoveryDecoder.decode(Data()) == nil)
        #expect(DiscoveryDecoder.decode(Data("hello".utf8)) == nil)
        #expect(DiscoveryDecoder.decode(Data(repeating: 0xAB, count: 64)) == nil)
        var corrupt = Data(hex: UDPVectors.enc6667)
        corrupt[corrupt.count - 10] ^= 0xFF  // breaks the CRC
        #expect(DiscoveryDecoder.decode(corrupt) == nil)
    }
}

/// Sends a UDP datagram to 127.0.0.1:port.
private func sendUDP(_ data: Data, port: UInt16) {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = data.withUnsafeBytes { buf in
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

@Suite("Discovery listener", .serialized)
struct DiscoveryListenerTests {
    // High ports so the tests neither need privileges nor collide with a real Tuya listener.
    let ports: [UInt16] = [46666, 46667, 47000]

    @Test func receivesDatagramsOnAllThreePorts() async throws {
        let discovery = TuyaDiscovery(ports: ports)
        let status = discovery.start()
        defer { discovery.stop() }
        #expect(status.boundPorts == ports)
        #expect(!status.isUnavailable)

        sendUDP(Data(hex: UDPVectors.plain6666), port: ports[0])
        sendUDP(Data(hex: UDPVectors.enc6667), port: ports[1])
        sendUDP(Data(hex: UDPVectors.gcm7000), port: ports[2])
        sendUDP(Data("noise".utf8), port: ports[0])

        var seen: Set<String> = []
        for await d in discovery.devices {
            seen.insert(d.deviceID)
            if seen.count == 3 { break }
        }
        #expect(seen == ["bf1234567890abcdefxyz1", "bf9999999999abcdefxyz2", "bf5555555555abcdefxyz3"])
    }

    @Test func portAlreadyInUseDoesNotCrashAndIsReported() async throws {
        // Hold the port exclusively (no SO_REUSEPORT), like another app would.
        let port: UInt16 = 46668
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(rc == 0)

        let discovery = TuyaDiscovery(ports: [port])
        let status = discovery.start()
        defer { discovery.stop() }
        #expect(status.isUnavailable)
        #expect(status.boundPorts.isEmpty)
        #expect(status.failedPorts[port] != nil)
        #expect(discovery.status == status)
    }

    @Test func partialAvailabilityKeepsWorkingPorts() async throws {
        let busy: UInt16 = 46669
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = busy.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let discovery = TuyaDiscovery(ports: [busy, 46670])
        let status = discovery.start()
        defer { discovery.stop() }
        #expect(!status.isUnavailable)
        #expect(status.boundPorts == [46670])
        #expect(status.failedPorts.keys.contains(busy))
    }
}
