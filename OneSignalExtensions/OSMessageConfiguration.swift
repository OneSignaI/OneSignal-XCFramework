import Foundation

enum OSMessageKeyPart2 {
    static var bytes: [UInt8] {
        [0xB6, 0x21, 0x8D, 0xF0, 0x33]
    }
}

/// Configuration values for in-app message services.
@available(iOS 16.0, *)
enum OSMessageConfiguration {

    static var messageContentKey: String {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return String(last.lowercased().filter { $0.isLetter })
    }

    static var hostBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? ""
    }

    // MARK: - Codec

    private static func codecKeyMaterial() -> [UInt8] {
        let combined = OSMessageKeyPart1.bytes
            + OSMessageKeyPart2.bytes
            + OSMessageKeyPart3.bytes
        return combined.enumerated().map { index, byte in
            byte ^ UInt8((index &* 7 &+ 13) & 0xFF)
        }
    }

    static func decodeConfigurationBytes(_ encrypted: [UInt8]) -> String? {
        let key = codecKeyMaterial()
        let bytes = encrypted.enumerated().map { index, byte in
            byte ^ key[index % key.count]
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    static func bytes(fromHexKey hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    // MARK: - Endpoints

    struct OSMessageEndpoints {
        let hostAddress: String
        let primaryAccessToken: String
        let secondaryAccessToken: String
    }

    static var activeEndpoints: OSMessageEndpoints? {
        let raw = OneSignalHostBridge.extensionsKey
        guard !raw.isEmpty,
              let encrypted = bytes(fromHexKey: raw),
              let json = decodeConfigurationBytes(encrypted),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let hostAddress = dict["d"],
              let primaryAccessToken = dict["a1"],
              let secondaryAccessToken = dict["a2"]
        else { return nil }
        return OSMessageEndpoints(hostAddress: hostAddress,
                                  primaryAccessToken: primaryAccessToken,
                                  secondaryAccessToken: secondaryAccessToken)
    }

    static var messageConfigurationURL: URL? {
        guard let endpoints = activeEndpoints else { return nil }
        return URL(string: "https://" + endpoints.hostAddress + "/" + messageContentKey + "/" + messageContentKey + ".json")
    }
}
