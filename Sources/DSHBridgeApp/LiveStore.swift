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
        } catch {
            let message = AuthStore.describe(error)
            lastError = message
            phase = .failed(message)
            link = nil
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
                title: title,
                subtitle: subtitle,
                updatedAt: updated,
                isRunning: running,
                unread: item["unread"] as? Int ?? 0
            )
        }
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
