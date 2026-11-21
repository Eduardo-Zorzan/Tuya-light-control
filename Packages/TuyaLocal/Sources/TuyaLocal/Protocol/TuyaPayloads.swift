import Foundation

/// JSON payload construction/parsing for the commands this package uses.
enum TuyaPayloads {
    /// Command word + plaintext payload for a DP query.
    static func query(version: TuyaVersion, deviceID: String, now: Date = Date()) -> (command: UInt32, payload: Data) {
        switch version {
        case .v33:
            return (
                TuyaCommand.dpQuery,
                json(["gwId": deviceID, "devId": deviceID, "uid": deviceID, "t": String(Int(now.timeIntervalSince1970))])
            )
        case .v34, .v35:
            return (TuyaCommand.dpQueryNew, Data("{}".utf8))
        }
    }

    /// Command word + plaintext payload for setting datapoints.
    static func control(version: TuyaVersion, deviceID: String, dps: DPMap, now: Date = Date()) -> (command: UInt32, payload: Data) {
        let t = Int(now.timeIntervalSince1970)
        let dpsObject = Dictionary(uniqueKeysWithValues: dps.map { (String($0.key), $0.value.jsonObject) })
        switch version {
        case .v33:
            return (TuyaCommand.control, json(["devId": deviceID, "uid": deviceID, "t": String(t), "dps": dpsObject]))
        case .v34, .v35:
            return (TuyaCommand.controlNew, json(["protocol": 5, "t": t, "data": ["dps": dpsObject]]))
        }
    }

    static func heartbeat(deviceID: String) -> Data {
        json(["gwId": deviceID, "devId": deviceID])
    }

    /// Extracts the `dps` map from a decrypted payload (3.3 top-level `dps`, 3.4+ `data.dps`).
    /// A payload that is not JSON means the key was wrong (decrypted to garbage) → `.invalidKey`.
    static func parseDPs(_ payload: Data) throws -> DPMap {
        if payload.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            if String(decoding: payload, as: UTF8.self).contains("data unvalid") {
                throw TuyaError.protocol("device rejected the request")
            }
            throw TuyaError.invalidKey
        }
        let raw = (object["dps"] as? [String: Any]) ?? ((object["data"] as? [String: Any])?["dps"] as? [String: Any]) ?? [:]
        var out = DPMap()
        for (k, v) in raw {
            if let id = Int(k), let value = DPValue(json: v) { out[id] = value }
        }
        return out
    }

    private static func json(_ object: [String: Any]) -> Data {
        // Tuya devices reject payloads containing spaces; JSONSerialization output is compact.
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
}
