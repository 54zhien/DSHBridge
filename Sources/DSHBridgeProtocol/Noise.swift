import Foundation
import CryptoKit

public enum NoiseError: Error, Equatable {
    case badKeyLength
    case decryptFailed
    case unexpectedState
    case truncatedMessage
}

enum NoiseHash {
    static let length = 32

    static func hkdf(chainKey: Data, input: Data, count: Int) -> [Data] {
        let prk = hmac(key: chainKey, message: input)
        var blocks: [Data] = []
        var previous = Data()
        var counter: UInt8 = 1
        while blocks.reduce(0, { $0 + $1.count }) < count {
            var message = Data()
            message.append(previous)
            message.append(counter)
            let block = hmac(key: prk, message: message)
            blocks.append(block)
            previous = block
            counter &+= 1
        }
        var result: [Data] = []
        var remaining = count
        for block in blocks {
            let take = min(remaining, block.count)
            result.append(block.prefix(take))
            remaining -= take
            if remaining == 0 { break }
        }
        return result
    }

    static func hmac(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }
}

public struct CipherState {
    public var key: SymmetricKey?
    public var nonce: UInt64 = 0

    public init(key: SymmetricKey? = nil, nonce: UInt64 = 0) {
        self.key = key
        self.nonce = nonce
    }

    private func nonceObject(_ value: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { raw in
            for i in 0..<8 { bytes[4 + i] = raw[i] }
        }
        return try ChaChaPoly.Nonce(data: Data(bytes))
    }

    public mutating func encrypt(_ plaintext: Data, ad: Data) throws -> Data {
        guard let key else { return plaintext }
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonceObject(nonce), authenticating: ad)
        nonce &+= 1
        return sealed.ciphertext + sealed.tag
    }

    public mutating func decrypt(_ ciphertext: Data, ad: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard ciphertext.count >= 16 else { throw NoiseError.truncatedMessage }
        let box = try ChaChaPoly.SealedBox(
            nonce: nonceObject(nonce),
            ciphertext: ciphertext.dropLast(16),
            tag: ciphertext.suffix(16)
        )
        let opened = try ChaChaPoly.open(box, using: key, authenticating: ad)
        nonce &+= 1
        return opened
    }
}

public struct SymmetricState {
    public private(set) var chainKey: Data
    public private(set) var handshakeHash: Data
    public private(set) var cipher: CipherState

    public init(protocolName: String) {
        var hash = Data(protocolName.utf8)
        if hash.count <= NoiseHash.length {
            hash.append(Data(repeating: 0, count: NoiseHash.length - hash.count))
        } else {
            hash = Data(SHA256.hash(data: hash))
        }
        chainKey = hash
        handshakeHash = hash
        cipher = CipherState()
    }

    public mutating func mixHash(_ data: Data) {
        handshakeHash = Data(SHA256.hash(data: handshakeHash + data))
    }

    public mutating func mixKey(_ input: Data) {
        let out = NoiseHash.hkdf(chainKey: chainKey, input: input, count: 64)
        chainKey = out[0]
        cipher.key = SymmetricKey(data: out[1])
        cipher.nonce = 0
    }

    public mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let output = try cipher.encrypt(plaintext, ad: handshakeHash)
        mixHash(output)
        return output
    }

    public mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let output = try cipher.decrypt(ciphertext, ad: handshakeHash)
        mixHash(ciphertext)
        return output
    }

    public func split() -> (CipherState, CipherState) {
        let out = NoiseHash.hkdf(chainKey: chainKey, input: Data(), count: 64)
        return (
            CipherState(key: SymmetricKey(data: out[0])),
            CipherState(key: SymmetricKey(data: out[1]))
        )
    }
}

/// IK 发起方（App 侧）。预先知道对端静态公钥，用 prologue 绑定连接上下文。
public final class NoiseIKInitiator {
    public static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"

    private var state: SymmetricState
    private let staticPrivate: Curve25519.KeyAgreement.PrivateKey
    private let remoteStaticPublic: Curve25519.KeyAgreement.PublicKey
    private var ephemeralPrivate: Curve25519.KeyAgreement.PrivateKey?
    private var sendCipher: CipherState?
    private var receiveCipher: CipherState?

    public init(staticPrivateKey: Data, remoteStaticPublicKey: Data, prologue: Data) throws {
        guard staticPrivateKey.count == 32, remoteStaticPublicKey.count == 32 else {
            throw NoiseError.badKeyLength
        }
        staticPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivateKey)
        remoteStaticPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStaticPublicKey)
        state = SymmetricState(protocolName: Self.protocolName)
        state.mixHash(prologue)
        // IK 的预共享消息是 `<- s`：对端静态公钥要先进入握手哈希，
        // 否则 AD 不同，密文一样但 tag 对不上。
        state.mixHash(remoteStaticPublicKey)
    }

    public var localStaticPublicKey: Data { staticPrivate.publicKey.rawRepresentation }
    public var handshakeHash: Data { state.handshakeHash }
    public var isComplete: Bool { sendCipher != nil }

    public func writeMessage1(payload: Data = Data(), ephemeralKey: Data? = nil) throws -> Data {
        let ephemeral = try ephemeralKey.map {
            try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0)
        } ?? Curve25519.KeyAgreement.PrivateKey()
        ephemeralPrivate = ephemeral

        var message = Data()
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation
        message.append(ephemeralPublic)
        state.mixHash(ephemeralPublic)

        state.mixKey(try dh(ephemeral, remoteStaticPublic))
        message.append(try state.encryptAndHash(staticPrivate.publicKey.rawRepresentation))

        state.mixKey(try dh(staticPrivate, remoteStaticPublic))
        message.append(try state.encryptAndHash(payload))
        return message
    }

    @discardableResult
    public func readMessage2(_ message: Data, ephemeralKey: Data? = nil) throws -> Data {
        guard let ephemeralPrivate else { throw NoiseError.unexpectedState }
        guard message.count >= 32 else { throw NoiseError.truncatedMessage }

        let remoteEphemeralBytes = Data(message.prefix(32))
        let remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeralBytes)
        state.mixHash(remoteEphemeralBytes)

        state.mixKey(try dh(ephemeralPrivate, remoteEphemeral))
        state.mixKey(try dh(staticPrivate, remoteEphemeral))

        // IK 第二条只有 e、ee、se，对端静态公钥不重发，32 字节后直接是 payload。
        let cursor = message.index(message.startIndex, offsetBy: 32)
        let payload = try state.decryptAndHash(Data(message[cursor...]))

        let (sending, receiving) = state.split()
        sendCipher = sending
        receiveCipher = receiving
        return payload
    }

    public func seal(_ plaintext: Data) throws -> Data {
        guard var sendCipher else { throw NoiseError.unexpectedState }
        let output = try sendCipher.encrypt(plaintext, ad: Data())
        self.sendCipher = sendCipher
        return output
    }

    public func open(_ ciphertext: Data) throws -> Data {
        guard var receiveCipher else { throw NoiseError.unexpectedState }
        let output = try receiveCipher.decrypt(ciphertext, ad: Data())
        self.receiveCipher = receiveCipher
        return output
    }

    private func dh(
        _ privateKey: Curve25519.KeyAgreement.PrivateKey,
        _ publicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> Data {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return secret.withUnsafeBytes { Data($0) }
    }
}

public enum Base64URL {
    public static func decode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
