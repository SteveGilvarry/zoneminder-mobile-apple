import Foundation

public enum JWT {
    public static func expirationEpochSeconds(_ token: String) -> Int? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1])
        let padding = 4 - payload.count % 4
        if padding < 4 { payload += String(repeating: "=", count: padding) }
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? Int else {
            return nil
        }
        return exp
    }
}
