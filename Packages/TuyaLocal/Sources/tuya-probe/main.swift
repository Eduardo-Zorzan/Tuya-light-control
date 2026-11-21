import Foundation
import TuyaLocal

let usage = """
    Usage:
      tuya-probe <ip> <deviceID> <localKey> [--version 3.3|3.4|3.5] [--port 6668]
          Connects to a light, auto-detects the protocol version and prints its datapoints.
      tuya-probe --discover [seconds]
          Listens for Tuya UDP broadcasts (ports 6666, 6667, 7000) and prints announced devices (default 15 s).

    The local key is read from the command line only for probing; it is never logged.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func describe(_ value: DPValue) -> String {
    switch value {
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .string(let s): return "\"\(s)\""
    }
}

func printDPs(_ dps: DPMap) {
    print("Datapoints:")
    for id in dps.keys.sorted() { print("  dp \(id) = \(describe(dps[id]!))") }
    let hasV2 = (20...24).allSatisfy { dps[$0] != nil }
    let hasLegacy = (1...5).allSatisfy { dps[$0] != nil }
    switch (hasV2, hasLegacy) {
    case (true, _): print("Profile: v2 (DPs 20–24: switch_led, work_mode, bright_value_v2, temp_value_v2, colour_data_v2)")
    case (_, true): print("Profile: legacy (DPs 1–5: switch, mode, bright, temp, colour)")
    default: print("Profile: unknown — record the DP map above in DEVICES.md")
    }
}

func runDiscovery(seconds: Int) async {
    let discovery = TuyaDiscovery()
    let status = discovery.start()
    if status.isUnavailable { fail("Discovery unavailable: \(status.failedPorts)") }
    if !status.failedPorts.isEmpty { print("Warning: could not bind \(status.failedPorts)") }
    print("Listening on UDP \(status.boundPorts) for \(seconds) s…")
    let stopper = Task {
        try? await Task.sleep(for: .seconds(seconds))
        discovery.stop()
    }
    var seen = Set<DiscoveredDevice>()
    for await d in discovery.devices where seen.insert(d).inserted {
        print("found id=\(d.deviceID) ip=\(d.ip) version=\(d.version?.rawValue ?? "?") product=\(d.productKey ?? "?")")
    }
    stopper.cancel()
    if seen.isEmpty { print("Nothing heard. Check Local Network permission and that the light is on this LAN.") }
}

func runProbe(arguments: [String]) async {
    var positional: [String] = []
    var version: TuyaVersion?
    var port: UInt16 = 6668
    var it = arguments.makeIterator()
    while let a = it.next() {
        switch a {
        case "--version":
            guard let v = it.next(), let parsed = TuyaVersion(rawValue: v) else { fail("--version needs 3.3, 3.4 or 3.5") }
            version = parsed
        case "--port":
            guard let p = it.next(), let parsed = UInt16(p) else { fail("--port needs a number") }
            port = parsed
        default: positional.append(a)
        }
    }
    guard positional.count == 3 else { fail(usage) }
    let (ip, deviceID, key) = (positional[0], positional[1], positional[2])
    print("Probing \(ip):\(port) (device \(deviceID))…")
    do {
        let result = try await VersionDetector.detect(host: ip, port: port, deviceID: deviceID, localKey: key, preferred: version)
        print("Protocol version: \(result.version.rawValue)")
        printDPs(result.dps)
    } catch let error as TuyaError {
        switch error {
        case .invalidKey: fail("Error: invalid local key (or unsupported protocol version).")
        case .connectionRefused: fail("Error: connection refused — another app may hold the device's single local connection.")
        case .localNetworkDenied: fail("Error: Local Network permission denied for this terminal/app.")
        case .timeout: fail("Error: timed out — wrong IP, light off, or not on this LAN.")
        default: fail("Error: \(error)")
        }
    } catch {
        fail("Error: \(error)")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--discover" {
    await runDiscovery(seconds: args.dropFirst().first.flatMap(Int.init) ?? 15)
} else if args.isEmpty || args.contains("--help") || args.contains("-h") {
    print(usage)
} else {
    await runProbe(arguments: args)
}
