import CryptoKit
import Foundation
import SwiftUI

/// 真实链路状态。负责：拿主机公钥 → 建 Control/Relay → Noise 握手 → 拉会话。
/// 所有失败都收敛成一句人话，UI 只读 phase。
@MainActor
@Observable
final class LiveStore {
    enum Phase: Equatable {
        case idle
        case working(String)
        case ready
        case failed(String)
    }

    var phase: Phase = .idle
    var sessions: [SessionSummary] = []
    var messages: [ChatMessage] = []
    var activeSessionId: String?
    var connectedHostName: String?
    var lastError: String?

    private var link: RemoteLink?

    var isReady: Bool { phase == .ready }
    var isBusy: Bool { if case .working = phase { return true }; return false }

    func connect(device: RemoteDevice, auth: AuthStore) async {
        guard !isBusy else { return }
        lastError = nil
        do {
            phase = .working("获取主机公钥")
            let context = try await auth.liveContext()
            let key = try await DeviceClient(baseUrl: context.baseUrl, token: context.token)
                .identityKey(deviceId: device.deviceId)

            phase = .working("建立加密通道")
            let link = RemoteLink()
            try await link.connect(
                serverURL: context.baseUrl,
                hostDeviceId: device.deviceId,
                hostIdentityKey: key,
                accessToken: context.token,
                identity: context.identity
            )
            self.link = link

            phase = .working("拉取会话")
            let payload = #"{"_request":{}}"#.data(using: .utf8) ?? Data()
            let data = try await link.remoteCall(endpoint: "session/list", payloadJSON: payload)
            sessions = Self.decodeSessions(data)
            connectedHostName = device.name ?? device.deviceId
            phase = .ready
            startEvents()
        } catch {
            let message = AuthStore.describe(error)
            lastError = message
            phase = .failed(message)
            link = nil
        }
    }

    // MARK: - 会话内操作

    func loadHistory(sessionId: String) async {
        guard let link else { return }
        activeSessionId = sessionId
        messages = []
        lastError = nil
        let body: [String: Any] = [
            "request": [
                "address": ["kind": "session", "sessionId": sessionId],
                "maxMessages": 80,
            ],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        do {
            let stream = try await link.openStream(endpoint: "session/follow", payloadJSON: payload)
            var frames: [Data] = []
            let deadline = Date().addingTimeInterval(2.5)
            for await frame in stream {
                frames.append(frame)
                if Date() > deadline { break }
            }
            messages = Self.decodeFrames(frames)
            if messages.isEmpty {
                lastError = "会话流已连上，但没有解析出消息（收到 \(frames.count) 帧）"
            }
        } catch {
            lastError = AuthStore.describe(error)
        }
    }

    /// 会话流每一帧是一个快照：{ records: [{ event: { type, seq, time, data }, view }] }
    private static func decodeFrames(_ frames: [Data]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for frame in frames {
            guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { continue }
            let records = object["records"] as? [[String: Any]] ?? []
            for record in records {
                guard let event = record["event"] as? [String: Any] else { continue }
                let type = event["type"] as? String ?? ""
                let data = event["data"] as? [String: Any] ?? [:]
                guard let text = Self.text(in: data), !text.isEmpty else { continue }
                let role: MessageRole = (data["role"] as? String) == "user" || type.contains("user") ? .user : .assistant
                out.append(ChatMessage(id: UUID(), role: role, text: text, isStreaming: false))
            }
        }
        return out
    }

    private static func text(in data: [String: Any]) -> String? {
        if let value = data["text"] as? String { return value }
        if let value = data["content"] as? String { return value }
        if let parts = data["content"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            if !joined.isEmpty { return joined }
        }
        if let message = data["message"] as? [String: Any], let value = message["text"] as? String { return value }
        return nil
    }

    func send(_ text: String) async {
        guard let link, let sessionId = activeSessionId else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(id: UUID(), role: .user, text: trimmed, isStreaming: false))
        let body: [String: Any] = [
            "request": [
                "requestId": UUID().uuidString.lowercased(),
                "sessionId": sessionId,
                "mode": "queue",
                "content": [["type": "text", "text": trimmed]],
            ],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        do {
            _ = try await link.remoteCall(endpoint: "session/prompt", payloadJSON: payload)
        } catch {
            lastError = AuthStore.describe(error)
        }
    }

    func cancelCurrent() async {
        guard let link, let sessionId = activeSessionId else { return }
        guard let payload = try? JSONSerialization.data(withJSONObject: ["request": ["sessionId": sessionId]]) else { return }
        _ = try? await link.remoteCall(endpoint: "session/cancel", payloadJSON: payload)
    }

    // MARK: - 审批

    var approvals: [ApprovalRequest] = []
    private var eventClientId: String?
    private var eventTask: Task<Void, Never>?

    func startEvents() {
        guard let link else { return }
        eventTask?.cancel()
        eventTask = Task { @MainActor in
            do {
                let payload = Data(#"{"args":{}}"#.utf8)
                let stream = try await link.openStream(endpoint: "$events", payloadJSON: payload)
                for await frame in stream { self.handleEventFrame(frame) }
            } catch {
                self.lastError = AuthStore.describe(error)
            }
        }
    }

    private func handleEventFrame(_ frame: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { return }
        if let clientId = object["clientId"] as? String {
            eventClientId = clientId
            return
        }
        guard let type = object["type"] as? String else { return }
        switch type {
        case "approval/requested":
            let approvalId = object["approvalId"] as? String ?? UUID().uuidString
            approvals.append(ApprovalRequest(id: UUID(),
                                             tool: object["toolName"] as? String ?? "工具调用",
                                             summary: object["reason"] as? String ?? "需要你的确认",
                                             detail: approvalId))
        case "approval/resolved":
            if let approvalId = object["approvalId"] as? String {
                approvals.removeAll { $0.detail == approvalId }
            }
        default:
            break
        }
    }

    func respond(to approval: ApprovalRequest, allow: Bool) {
        guard let link, let clientId = eventClientId else { return }
        let args: [String: Any] = [
            "clientId": clientId,
            "eventId": approval.detail,
            "outcome": ["kind": "result", "value": allow ? "allowed-once" : "rejected"],
        ]
        Task { @MainActor in
            do {
                let body = try JSONSerialization.data(withJSONObject: args)
                _ = try await link.rpc("$events/result", paramsJSON: body)
                self.approvals.removeAll { $0.id == approval.id }
            } catch {
                self.lastError = AuthStore.describe(error)
            }
        }
    }

    func disconnect() {
        link = nil
        sessions = []
        connectedHostName = nil
        phase = .idle
    }

    // MARK: - 解析

    /// session/list 的返回结构各版本略有差异，这里按「能认几个字段就认几个」处理，
    /// 认不出标题就退化成 id 尾段，绝不因为字段缺失整批丢掉。
    static func decodeSessions(_ data: Data) -> [SessionSummary] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let raw = (root["items"] as? [[String: Any]])
            ?? (root["sessions"] as? [[String: Any]])
            ?? []
        return raw.compactMap { item in
            let id = (item["id"] as? String)
                ?? (item["sessionId"] as? String)
                ?? (item["session_id"] as? String)
            guard let id else { return nil }
            let title = (item["title"] as? String)
                ?? (item["name"] as? String)
                ?? String(id.suffix(8))
            let subtitle = (item["summary"] as? String)
                ?? (item["preview"] as? String)
                ?? (item["cwd"] as? String)
                ?? ""
            let stamp = (item["updatedAt"] as? Double)
                ?? (item["updated_at"] as? Double)
                ?? (item["createdAt"] as? Double)
                ?? 0
            let updated = stamp > 0 ? Date(timeIntervalSince1970: stamp / 1000) : Date()
            let status = (item["status"] as? String) ?? ""
            let running = status == "running" || status == "active" || (item["isRunning"] as? Bool ?? false)
            return SessionSummary(
                id: stableUUID(id),
                rawId: id,
                title: title,
                subtitle: subtitle,
                updatedAt: updated,
                isRunning: running,
                unread: item["unread"] as? Int ?? 0
            )
        }
    }

    /// 历史记录结构随 Host 版本浮动，这里只挑能认出来的文本片段，认不出就跳过。
    static func decodeMessages(_ data: Data) -> [ChatMessage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let records = (root["records"] as? [[String: Any]]) ?? []
        var out: [ChatMessage] = []
        for record in records {
            let role = (record["role"] as? String) ?? (record["type"] as? String) ?? ""
            let content = record["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            let plain = text.isEmpty ? ((record["text"] as? String) ?? "") : text
            guard !plain.isEmpty else { continue }
            let mapped: MessageRole = role.contains("user") ? .user : .assistant
            out.append(ChatMessage(id: stableUUID(UUID().uuidString), role: mapped, text: plain, isStreaming: false))
        }
        return out
    }

    private static func stableUUID(_ string: String) -> UUID {
        let digest = SHA256.hash(data: Data(string.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
