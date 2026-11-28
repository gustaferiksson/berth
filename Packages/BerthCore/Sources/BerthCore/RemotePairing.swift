import Foundation

public enum RemotePairing {
    public static let scheme = "berthremote"

    private static let tokenCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-")
    private static let queryAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func payload(address: String, token: String) -> String? {
        guard let url = URL(string: address), url.scheme == "wss", url.host()?.isEmpty == false, isValid(token: token) else { return nil }

        let encodedAddress = url.absoluteString.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
        let encodedToken = token.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
        return "\(scheme)://pair?url=\(encodedAddress)&token=\(encodedToken)"
    }

    public static func parse(_ payload: String) -> (url: URL, token: String)? {
        guard payload.utf8.count <= 1024,
              let components = URLComponents(string: payload),
              components.scheme == scheme,
              components.host == "pair",
              let items = components.queryItems,
              items.count == 2,
              let address = items.first(where: { $0.name == "url" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value,
              isValid(token: token),
              let url = URL(string: address),
              url.scheme == "wss",
              url.host()?.isEmpty == false,
              url.user == nil,
              url.password == nil
        else { return nil }

        return (url, token)
    }

    private static func isValid(token: String) -> Bool {
        (16...128).contains(token.utf8.count) && token.unicodeScalars.allSatisfy(tokenCharacters.contains)
    }
}
