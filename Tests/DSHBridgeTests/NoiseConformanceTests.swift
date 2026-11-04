import XCTest
@testable import DSHBridge

/// 对照官方确定性向量验证 Noise IK 实现。
/// 这是整个协议层唯一能离线证明正确性的地方：静态密钥、临时密钥、
/// prologue、两条握手消息、传输密文全部逐字节比对。
final class NoiseConformanceTests: XCTestCase {
    private func loadVector() throws -> [String: Any] {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "noise-ik", withExtension: "json") else {
            XCTFail("noise-ik.json 没有打进测试包")
            throw XCTSkip("fixture missing")
        }
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let vectors = try XCTUnwrap(root["vectors"] as? [[String: Any]])
        return try XCTUnwrap(vectors.first)
    }

    private func data(_ object: Any?) throws -> Data {
        let string = try XCTUnwrap(object as? String)
        return try XCTUnwrap(Base64URL.decode(string), "不是合法 base64url: \(string.prefix(16))")
    }

    func testHandshakeMatchesOfficialVector() throws {
        let vector = try loadVector()

        let staticKeys = try XCTUnwrap(vector["staticKeys"] as? [String: Any])
        let initiatorKeys = try XCTUnwrap(staticKeys["initiator"] as? [String: Any])
        let responderKeys = try XCTUnwrap(staticKeys["responder"] as? [String: Any])
        let ephemeral = try XCTUnwrap(vector["ephemeralPrivateKeys"] as? [String: Any])
        let prologue = try XCTUnwrap(vector["prologue"] as? [String: Any])
        let handshake = try XCTUnwrap(vector["handshake"] as? [String: Any])
        let message1 = try XCTUnwrap(handshake["message1"] as? [String: Any])
        let message2 = try XCTUnwrap(handshake["message2"] as? [String: Any])

        let initiator = try NoiseIKInitiator(
            staticPrivateKey: try data(initiatorKeys["privateKey"]),
            remoteStaticPublicKey: try data(responderKeys["publicKey"]),
            prologue: try data(prologue["bytes"])
        )

        let produced = try initiator.writeMessage1(
            payload: try data(message1["payload"]),
            ephemeralKey: try data(ephemeral["initiator"])
        )
        XCTAssertEqual(
            Base64URL.encode(produced),
            try XCTUnwrap(message1["message"] as? String),
            "握手第一条不匹配"
        )

        let payload = try initiator.readMessage2(
            try data(message2["message"]),
            ephemeralKey: try data(ephemeral["responder"])
        )
        XCTAssertEqual(
            Base64URL.encode(payload),
            try XCTUnwrap(message2["payload"] as? String),
            "握手第二条解出的 payload 不匹配"
        )
        XCTAssertTrue(initiator.isComplete)

        // 传输阶段：发起方发出的每一条都要对上
        let transport = try XCTUnwrap(vector["transport"] as? [[String: Any]])
        for entry in transport {
            let sender = try XCTUnwrap(entry["sender"] as? String)
            if sender == "initiator" {
                let sealed = try initiator.seal(try data(entry["plaintext"]))
                XCTAssertEqual(
                    Base64URL.encode(sealed),
                    try XCTUnwrap(entry["ciphertext"] as? String),
                    "加密密文不匹配"
                )
            } else {
                let opened = try initiator.open(try data(entry["ciphertext"]))
                XCTAssertEqual(
                    Base64URL.encode(opened),
                    try XCTUnwrap(entry["plaintext"] as? String),
                    "解密明文不匹配"
                )
            }
        }
    }
}
