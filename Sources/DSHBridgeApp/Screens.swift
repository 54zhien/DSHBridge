import SwiftUI

struct SessionsScreen: View {
    @Bindable var model: AppModel
    var live: LiveStore
    var onMenu: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.sessions) { session in
                        NavigationLink(value: session) {
                            SessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .navigationDestination(for: SessionSummary.self) { session in
                ChatScreen(model: model, session: session, live: live)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HeaderBar(title: "会话", onMenu: onMenu)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if session.isRunning {
                    ProgressView().controlSize(.mini)
                }
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if session.unread > 0 {
                    Text("\(session.unread)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint, in: .capsule)
                }
            }
            Text(session.subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(session.updatedAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect()
    }
}

struct HeaderBar: View {
    let title: String
    var onMenu: (() -> Void)?

    var body: some View {
        HStack {
            if let onMenu {
                Button(action: onMenu) {
                    WeightedIcon("referenceFile", size: 20, weight: .medium)
                        .frame(width: 44, height: 44)
                }
            }
            Spacer()
            Text(title).font(.headline)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

struct ChatScreen: View {
    @Bindable var model: AppModel
    let session: SessionSummary
    var live: LiveStore

    private var shownMessages: [ChatMessage] {
        live.messages.isEmpty ? model.messages : live.messages
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(shownMessages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                    if let approval = live.approvals.first {
                        ApprovalCard(request: approval) { decision in
                            live.respond(to: approval, allow: decision)
                        }
                        .id("approval")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(model.messages.last?.id, anchor: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .task { await live.loadHistory(sessionId: session.rawId.isEmpty ? session.id.uuidString : session.rawId) }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("给 DSH 发消息", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            if model.messages.contains(where: { $0.isStreaming }) {
                Button { model.stop(); Task { await live.cancelCurrent() } } label: {
                    Image(systemName: "stop.fill").font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.glass)
            } else {
                Button {
                    let text = model.draft
                    model.draft = ""
                    Task { await live.send(text) }
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(DSTheme.accent, in: .rect(cornerRadius: 18))
                    .foregroundStyle(.white)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(.tint).frame(width: 6, height: 6)
                    Text("DSH").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                if message.text.isEmpty && message.isStreaming {
                    ProgressView().controlSize(.small)
                } else {
                    Text(message.text)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let name):
            VStack(alignment: .leading, spacing: 4) {
                Text(name.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(message.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 20))
        }
    }
}

private struct ApprovalCard: View {
    let request: ApprovalRequest
    var onDecision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 15, weight: .semibold))
                Text("需要你确认").font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text(request.summary).font(.footnote).foregroundStyle(.secondary)
            Text(request.detail)
                .font(.system(.caption, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DSTheme.canvas.opacity(0.7), in: .rect(cornerRadius: 10))

            HStack(spacing: 10) {
                Button("拒绝") { onDecision(false) }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                Button("允许") { onDecision(true) }
                    .buttonStyle(.glassProminent)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .glassEffect()
    }
}
