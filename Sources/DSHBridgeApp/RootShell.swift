import SwiftUI

struct RootShell: View {
    @State private var model = AppModel()
    @State private var isOpen = false
    @State private var auth = AuthStore()
    @State private var live = LiveStore()
    private let metrics = DrawerMetrics()

    var body: some View {
        Group {
            if auth.phase == .signedIn {
                drawer
            } else {
                LoginView(store: auth)
            }
        }
    }

    private var drawer: some View {
        UIKitDrawer(isOpen: $isOpen, metrics: metrics) {
            SidebarView(model: model, isOpen: $isOpen, auth: auth, live: live)
        } content: {
            SessionsScreen(model: model, onMenu: {
                withAnimation(metrics.spring) { isOpen = true }
            })
        }
        .ignoresSafeArea()
        .onChange(of: live.phase) { _, newValue in
            if newValue == .ready { model.sessions = live.sessions }
        }
        .task { await auth.refreshDevices() }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    @Binding var isOpen: Bool
    var auth: AuthStore
    var live: LiveStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DSH Bridge")
                    .font(.title2.weight(.semibold))
                Text("远程主机")
                    .font(.caption)
                    .foregroundStyle(DSTheme.textSecondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 72)
            .padding(.bottom, 20)

            ForEach(auth.devices) { device in
                Button {
                    Task { await live.connect(device: device, auth: auth) }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { isOpen = false }
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill((device.online ?? false) ? .green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name ?? device.deviceId.prefix(8).description)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text("\(device.platform ?? \"unknown\") · \(device.deviceId.prefix(8))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if live.connectedHostName == (device.name ?? device.deviceId) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(live.isBusy)
            }

            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(live.isReady ? .green : .orange)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var statusText: String {
        switch live.phase {
        case .idle: return "未连接"
        case .working(let step): return step
        case .ready: return "已连接"
        case .failed(let message): return message
        }
    }
}
