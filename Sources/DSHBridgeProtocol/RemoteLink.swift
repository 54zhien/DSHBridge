import Foundation
import CryptoKit

/// Application-layer message envelope carried inside the Noise channel.
public struct RemoteMessage {
    public var v = 1
    public var id: String
    public var type: String
    public var timestamp: Int
    public var payload: [String: Any]

    public init(id: String = UUID().uuidString, type: String, payload: [String: Any]) {
        self.id = id
        self.type = type
        self.timestamp = Int(Date().timeIntervalSince1970 * 1000)
        self.payload = payload
    }
}

public enum RemoteLinkError: Error, Sendable {
    case transport(String)
    case server(code: String, message: String)
    case closed(code: Int, reason: String)
    case timeout(String)
    case handshake(String)
}

/// Reassembles application plaintext split across Noise transport messages.
/// Mirrors `SecureMessageCodec` in packages/protocol/src/index.ts.
struct SecureMessageCodec {
    static let chunkBytes = 48 * 1024
    static let maxMessageBytes = 4 * 1024 * 1024
    static let magic: [UInt8] = [0x44, 0x53, 0x48, 0x46] // DSHF
    static let headerBytes = 17

    private var nextId: UInt32 = 1
    private var assemblies: [UInt32: (total: UInt16, totalBytes: UInt32, chunks: [Data])] = [:]

    mutating func encode(_ message: Data) throws -> [Data] {
        guard message.count <= Self.maxMessageBytes else { throw RemoteLinkError.transport("message too large") }
        guard message.count > Self.chunkBytes else { return [message] }

        let messageId = nextId
        nextId = messageId == UInt32.max ? 1 : messageId + 1
        let total = UInt16((message.count + Self.chunkBytes - 1) / Self.chunkBytes)

        var frames: [Data] = []
        for index in 0..<Int(total) {
            let start = index * Self.chunkBytes
            let end = min(message.count, start + Self.chunkBytes)
            var frame = Data(count: Self.headerBytes)
            frame.replaceSubrange(0..<4, with: Self.magic)
            frame[4] = 1
            frame.replaceSubrange(5..<9, with: withUnsafeBytes(of: messageId.bigEndian) { Data($0) })
            frame.replaceSubrange(9..<11, with: withUnsafeBytes(of: UInt16(index).bigEndian) { Data($0) })
            frame.replaceSubrange(11..<13, with: withUnsafeBytes(of: total.bigEndian) { Data($0) })
            frame.replaceSubrange(13..<17, with: withUnsafeBytes(of: UInt32(message.count).bigEndian) { Data($0) })
            frame.append(message.subdata(in: start..<end))
            frames.append(frame)
        }
        return frames
    }

    mutating func decode(_ frame: Data) throws -> Data? {
        guard frame.count >= 4, Array(frame.prefix(4)) == Self.magic else { return frame }
        guard frame.count > Self.headerBytes, frame[4] == 1 else { throw RemoteLinkError.transport("bad fragment header") }

        func u32(_ offset: Int) -> UInt32 {
            frame.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        }
        func u16(_ offset: Int) -> UInt16 {
            frame.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian }
        }

        let messageId = u32(5)
        let index = Int(u16(9))
        let total = Int(u16(11))
        let totalBytes = Int(u32(13))
        guard messageId != 0, total >= 2, index < total,
              totalBytes > Self.chunkBytes, totalBytes <= Self.maxMessageBytes,
              total == (totalBytes + Self.chunkBytes - 1) / Self.chunkBytes else {
            throw RemoteLinkError.transport("bad fragment metadata")
        }
        let chunk = frame.subdata(in: Self.headerBytes..<frame.count)
        let expected = min(Self.chunkBytes, totalBytes - index * Self.chunkBytes)
        guard chunk.count == expected else { throw RemoteLinkError.transport("bad fragment length") }

        var assembly = assemblies[messageId] ?? (total: UInt16(total), totalBytes: UInt32(totalBytes), chunks: [])
        guard assembly.chunks.count == index else {
            assemblies[messageId] = nil
            throw RemoteLinkError.transport("bad fragment sequence")
        }
        assembly.chunks.append(chunk)
        if assembly.chunks.count < total {
            assemblies[messageId] = assembly
            return nil
        }
        assemblies[messageId] = nil
        var joined = Data()
        assembly.chunks.forEach { joined.append($0) }
        guard joined.count == totalBytes else { throw RemoteLinkError.transport("bad message length") }
        return joined
    }
}

/// Client side of the DSH Remote control plane plus the Relay data plane.
///
/// The Relay socket only ever carries Noise ciphertext; every application
/// message is sealed before it leaves the device.
public actor RemoteLink {
    public enum State: String, Sendable {
        case idle, controlOpen, connecting, relayAttached, handshaking, ready, closed
    }

    public private(set) var state: State = .idle
    public private(set) var connectionId: String = ""
    public private(set) var diagnostics: [String] = []

    private var control: URLSessionWebSocketTask?
    private var relay: URLSessionWebSocketTask?
    private var noise: NoiseIKInitiator?
    private var codec = SecureMessageCodec()
    private var counter: UInt64 = 0

    private var hostDeviceId = ""
    private var clientDeviceId = ""
    private var pendingRpc: [String: CheckedContinuation<Data, Error>] = [:]
    private var pendingHandshake: CheckedContinuation<Data, Error>?
    private var pendingAck: [String: CheckedContinuation<[String: Any], Error>] = [:]

    public init() {}

    private func note(_ text: String) {
        diagnostics.append(text)
        if diagnostics.count > 200 { diagnostics.removeFirst(diagnostics.count - 200) }
    }

    // MARK: - Connect

    public func connect(serverURL: URL, hostDeviceId: String, hostIdentityKey: Data, accessToken: String, identity: DeviceIdentity) async throws {
        guard let wsURL = Self.webSocketURL(from: serverURL) else {
            throw RemoteLinkError.transport("server URL is not http(s)")
        }
        self.hostDeviceId = hostDeviceId
        self.clientDeviceId = identity.deviceId

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: wsURL)
        task.resume()
        control = task
        state = .controlOpen
        note("control open \(wsURL.absoluteString)")

        Task { await self.pumpControl() }

        _ = try await request("hello", waitType: "hello.ack", payload: [
            "role": "client",
            "deviceId": identity.deviceId,
            "accessToken": accessToken,
            "protocols": [1],
            "capabilities": ["transport.relay", "transport.relay.attach", "harness.api.v1"],
            "clientVersion": "dshbridge/0.1",
        ], timeout: 10)
        note("hello.ack")

        state = .connecting
        let accepted = try await request("connect.request", waitType: "connect.accepted", payload: [
            "hostDeviceId": hostDeviceId,
            "preferredTransports": ["relay"],
        ], timeout: 30)
        guard let cid = accepted["connectionId"] as? String else {
            throw RemoteLinkError.transport("connect.accepted missing connectionId")
        }
        connectionId = cid
        note("connect.accepted \(cid.prefix(8))")

        guard let endpoint = accepted["relayEndpoint"] as? String,
              let ticket = accepted["relayTicket"] as? String,
              let relayURL = URL(string: endpoint) else {
            throw RemoteLinkError.transport("server did not assign a relay")
        }
        let epoch = accepted["relayEpoch"] as? Int

        let relayTask = session.webSocketTask(with: relayURL)
        relayTask.resume()
        relay = relayTask
        Task { await self.pumpRelay() }

        try await sendRelayJSON([
            "v": 1,
            "id": UUID().uuidString,
            "type": "relay.attach",
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "payload": [
                "connectionId": cid,
                "deviceId": identity.deviceId,
                "peerDeviceId": hostDeviceId,
                "ticket": ticket,
            ],
        ])
        let ready = try await waitAck("relay.ready", timeout: 20)
        if let assigned = epoch, let got = ready["epoch"] as? Int, assigned != got {
            throw RemoteLinkError.transport("relay epoch mismatch")
        }
        state = .relayAttached
        note("relay.ready")

        try await performHandshake(identity: identity, hostIdentityKey: hostIdentityKey)
    }

    private func performHandshake(identity: DeviceIdentity, hostIdentityKey: Data) async throws {
        state = .handshaking
        let prologue = Data("DSH-REMOTE\u{0}v=1\u{0}connection=\(connectionId)\u{0}host=\(hostDeviceId)\u{0}client=\(clientDeviceId)".utf8)

        let initiator = NoiseIKInitiator(
            staticPrivateKey: identity.privateKey,
            remoteStaticPublicKey: hostIdentityKey,
            prologue: prologue
        )
        noise = initiator

        let message1 = try initiator.writeMessage1()
        try await sendControl("secure.handshake", [
            "connectionId": connectionId,
            "targetDeviceId": hostDeviceId,
            "step": 1,
            "data": Base64URL.encode(message1),
        ])
        note("handshake step1 \(message1.count)B")

        let reply = try await waitHandshake(timeout: 30)
        try initiator.readMessage2(reply)
        state = .ready
        note("handshake complete")
    }

    // MARK: - RPC

    /// Sends `harness.remote.call` for one Host endpoint and returns the raw
    /// `{ok, value}` / `{ok:false, error}` result as JSON data.
    public func remoteCall(endpoint: String, payloadJSON: Data = Data("{}".utf8)) async throws -> Data {
        guard state == .ready else { throw RemoteLinkError.transport("link not ready (\(state.rawValue))") }
        var params: [String: Any] = ["endpoint": endpoint]
        params["payload"] = try JSONSerialization.jsonObject(with: payloadJSON)
        let result = try await rpc("harness.remote.call", params)
        return try JSONSerialization.data(withJSONObject: result)
    }

    public func rpc(_ method: String, _ params: [String: Any], timeout: TimeInterval = 30) async throws -> Any {
        let message = RemoteMessage(type: "rpc.request", payload: ["method": method, "params": params])
        let body = try JSONSerialization.data(withJSONObject: [
            "v": message.v, "id": message.id, "type": message.type,
            "timestamp": message.timestamp, "payload": message.payload,
        ])

        let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingRpc[message.id] = continuation
            Task {
                do {
                    try await self.sendSecure(body)
                } catch {
                    await self.failRpc(message.id, error)
                }
            }
        }

        let envelope = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] ?? [:]
        let payload = envelope["payload"] as? [String: Any] ?? [:]
        if envelope["type"] as? String == "rpc.error" {
            throw RemoteLinkError.server(
                code: payload["code"] as? String ?? "UNKNOWN",
                message: payload["message"] as? String ?? "rpc failed"
            )
        }
        return payload["result"] ?? [:]
    }

    private func failRpc(_ id: String, _ error: Error) {
        if let continuation = pendingRpc.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func sendSecure(_ plaintext: Data) async throws {
        guard let noise else { throw RemoteLinkError.transport("noise not ready") }
        for fragment in try codec.encode(plaintext) {
            let cipher = try noise.seal(fragment)
            counter += 1
            try await sendRelayJSON([
                "v": 1,
                "id": UUID().uuidString,
                "type": "relay",
                "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                "payload": [
                    "connectionId": connectionId,
                    "targetDeviceId": hostDeviceId,
                    "counter": Int(counter),
                    "ciphertext": Base64URL.encode(cipher),
                ],
            ])
        }
    }

    // MARK: - Frame plumbing

    private func request(_ type: String, waitType: String, payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        try await sendControl(type, payload)
        return try await waitAck(waitType, timeout: timeout)
    }

    private func sendControl(_ type: String, _ payload: [String: Any]) async throws {
        guard let control else { throw RemoteLinkError.transport("control socket closed") }
        let frame: [String: Any] = [
            "v": 1,
            "id": UUID().uuidString,
            "type": type,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "payload": payload,
        ]
        let data = try JSONSerialization.data(withJSONObject: frame)
        try await control.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func sendRelayJSON(_ frame: [String: Any]) async throws {
        guard let relay else { throw RemoteLinkError.transport("relay socket closed") }
        let data = try JSONSerialization.data(withJSONObject: frame)
        try await relay.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func waitAck(_ type: String, timeout: TimeInterval) async throws -> [String: Any] {
        try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                    Task { await self.registerAck(type, continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw RemoteLinkError.timeout(type)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func registerAck(_ type: String, _ continuation: CheckedContinuation<[String: Any], Error>) {
        pendingAck[type] = continuation
    }

    private func waitHandshake(timeout: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    Task { await self.registerHandshake(continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw RemoteLinkError.timeout("secure.handshake step 2")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func registerHandshake(_ continuation: CheckedContinuation<Data, Error>) {
        pendingHandshake = continuation
    }

    private func pumpControl() async {
        guard let control else { return }
        while true {
            do {
                let message = try await control.receive()
                switch message {
                case .string(let text): try await handleControl(text)
                case .data(let data): try await handleControl(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
            } catch {
                note("control closed: \(error.localizedDescription)")
                state = .closed
                return
            }
        }
    }

    private func handleControl(_ text: String) async throws {
        guard let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = frame["type"] as? String else { return }
        let payload = frame["payload"] as? [String: Any] ?? [:]

        switch type {
        case "ping":
            if let nonce = payload["nonce"] {
                try await sendControl("pong", ["nonce": nonce])
            }
        case "secure.handshake":
            guard (payload["step"] as? Int) == 2,
                  let data = payload["data"] as? String,
                  let bytes = Base64URL.decode(data) else { return }
            pendingHandshake?.resume(returning: bytes)
            pendingHandshake = nil
        case "error":
            note("control error \(payload["code"] as? String ?? "?")")
        default:
            if let continuation = pendingAck.removeValue(forKey: type) {
                continuation.resume(returning: payload)
            }
        }
    }

    private func pumpRelay() async {
        guard let relay else { return }
        while true {
            do {
                let message = try await relay.receive()
                let text: String
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(decoding: data, as: UTF8.self)
                @unknown default: continue
                }
                try await handleRelay(text)
            } catch {
                note("relay closed: \(error.localizedDescription)")
                return
            }
        }
    }

    private func handleRelay(_ text: String) async throws {
        guard let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = frame["type"] as? String else { return }
        let payload = frame["payload"] as? [String: Any] ?? [:]

        if type == "relay.ready" {
            if let continuation = pendingAck.removeValue(forKey: "relay.ready") {
                continuation.resume(returning: payload)
            }
            return
        }
        guard type == "relay", let noise else { return }
        guard let cipherText = payload["ciphertext"] as? String,
              let cipher = Base64URL.decode(cipherText) else { return }

        let plain = try noise.open(cipher)
        guard let message = try codec.decode(plain) else { return }
        let envelope = try JSONSerialization.jsonObject(with: message) as? [String: Any] ?? [:]
        let messageType = envelope["type"] as? String ?? ""
        let id = envelope["id"] as? String ?? ""

        switch messageType {
        case "rpc.response", "rpc.error":
            if let continuation = pendingRpc.removeValue(forKey: id) {
                continuation.resume(returning: message)
            }
        default:
            note("event \(messageType)")
        }
    }

    public func close() {
        control?.cancel(with: .goingAway, reason: nil)
        relay?.cancel(with: .goingAway, reason: nil)
        state = .closed
    }

    static func webSocketURL(from serverURL: URL) -> URL? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = (components.scheme == "http") ? "ws" : "wss"
        components.path = "/ws/v1/connect"
        components.query = nil
        return components.url
    }
}

