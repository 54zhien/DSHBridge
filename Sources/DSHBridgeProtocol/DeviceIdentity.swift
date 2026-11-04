import CryptoKit
import Foundation
import Security

/// 本机设备身份。私钥只进 Keychain，公钥在注册时交给服务器，
/// 后续 Noise 握手用它做 pinning。
public struct DeviceIdentity: Codable, Sendable {
    public var deviceId: String
    public var name: String
    public var privateKey: Data
    public var publicKey: Data

    public init(deviceId: String, name: String, privateKey: Data, publicKey: Data) {
        self.deviceId = deviceId
        self.name = name
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    public static func generate(name: String) -> DeviceIdentity {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return DeviceIdentity(
            deviceId: UUID().uuidString.lowercased(),
            name: name,
            privateKey: key.rawRepresentation,
            publicKey: key.publicKey.rawRepresentation
        )
    }

    public var identityKey: String { Base64URL.encode(publicKey) }

    public var signingKey: Curve25519.KeyAgreement.PrivateKey? {
        try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
    }
}

/// 服务器凭据。accessToken 十分钟就过期，靠 refreshToken 续。
public struct ServerCredentials: Codable, Sendable {
    public var serverUrl: String
    public var deviceId: String
    public var account: String?
    public var accessToken: String
    public var refreshToken: String
    public var accessTokenExpiresAt: Int64
    public var refreshTokenExpiresAt: Int64

    public var isAccessTokenFresh: Bool {
        accessTokenExpiresAt - Int64(Date().timeIntervalSince1970 * 1000) > 30_000
    }
}

public enum IdentityStore {
    private static let service = "dev.zhien.dshbridge.identity"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    public static func loadIdentity() -> DeviceIdentity? { load(DeviceIdentity.self, account: "device") }

    public static func save(identity: DeviceIdentity) { save(identity, account: "device") }

    public static func loadCredentials(serverUrl: String) -> ServerCredentials? {
        load(ServerCredentials.self, account: "creds:\(serverUrl)")
    }

    public static func save(credentials: ServerCredentials) {
        save(credentials, account: "creds:\(credentials.serverUrl)")
    }

    public static func clearCredentials(serverUrl: String) {
        SecItemDelete(query("creds:\(serverUrl)") as CFDictionary)
    }

    private static func load<T: Decodable>(_ type: T.Type, account: String) -> T? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let q = query(account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(q as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            var insert = q
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}
