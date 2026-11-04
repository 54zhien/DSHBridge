import Foundation
import SwiftUI

/// 一台可以连的 DSH 主机。多地址切换是核心功能：
/// 校内走一台、校外走另一台，切换成本必须接近零。
struct HostProfile: Identifiable, Hashable {
    let id: UUID
    var name: String
    var serverURL: String
    var note: String
    var isOnline: Bool

    static let samples: [HostProfile] = [
        .init(id: UUID(), name: "zhien · Windows", serverURL: "https://dsh.r2049.cn", note: "寝室 · 有线", isOnline: true),
        .init(id: UUID(), name: "长工教务", serverURL: "http://10.217.185.54:8080", note: "校园内网", isOnline: false),
    ]
}

struct SessionSummary: Identifiable, Hashable {
    let id: UUID
    var title: String
    var subtitle: String
    var updatedAt: Date
    var isRunning: Bool
    var unread: Int
}

enum MessageRole: Hashable {
    case user
    case assistant
    case tool(String)
}

struct ChatMessage: Identifiable, Hashable {
    let id: UUID
    var role: MessageRole
    var text: String
    var isStreaming: Bool
}

struct ApprovalRequest: Identifiable, Hashable {
    let id: UUID
    var tool: String
    var summary: String
    var detail: String
}

@MainActor
@Observable
final class AppModel {
    var hosts: [HostProfile] = HostProfile.samples
    var activeHostID: UUID = HostProfile.samples[0].id
    var sessions: [SessionSummary] = AppModel.sampleSessions
    var messages: [ChatMessage] = AppModel.sampleMessages
    var pendingApproval: ApprovalRequest? = AppModel.sampleApproval
    var draft: String = ""
    var isConnected: Bool = true

    var activeHost: HostProfile {
        hosts.first { $0.id == activeHostID } ?? hosts[0]
    }

    func switchHost(to id: UUID) {
        activeHostID = id
        isConnected = hosts.first { $0.id == id }?.isOnline ?? false
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        messages.append(.init(id: UUID(), role: .user, text: text, isStreaming: false))
        messages.append(.init(id: UUID(), role: .assistant, text: "", isStreaming: true))
    }

    func stop() {
        if let index = messages.lastIndex(where: { $0.isStreaming }) {
            messages[index].isStreaming = false
        }
    }

    static let sampleSessions: [SessionSummary] = [
        .init(id: UUID(), title: "iOS 远程端协议对接", subtitle: "Noise IK 握手已经通了，接下来是 Typert 信封", updatedAt: Date().addingTimeInterval(-120), isRunning: true, unread: 0),
        .init(id: UUID(), title: "重构 DrawerHostController", subtitle: "把位移、缩放、圆角都收敛到单一 progress", updatedAt: Date().addingTimeInterval(-3600), isRunning: false, unread: 2),
        .init(id: UUID(), title: "校园网出口排查", subtitle: "UDP 全封，DERP 绕旧金山 177ms", updatedAt: Date().addingTimeInterval(-86400), isRunning: false, unread: 0),
    ]

    static let sampleMessages: [ChatMessage] = [
        .init(id: UUID(), role: .user, text: "先把握手跑通，别的先放一放", isStreaming: false),
        .init(id: UUID(), role: .assistant, text: "握手用官方的确定性向量对了一遍，96 字节的 msg1 和 msg2 都能逐字节对齐。接下来接 Control 通道的 hello 和 connect.request。", isStreaming: false),
        .init(id: UUID(), role: .tool("shell"), text: "$ swift test --filter NoiseConformance\n✔ noise-ik-v1-deterministic (0.004s)", isStreaming: false),
    ]

    static let sampleApproval = ApprovalRequest(
        id: UUID(),
        tool: "shell",
        summary: "执行 1 条命令",
        detail: "swift build -c release"
    )
}
