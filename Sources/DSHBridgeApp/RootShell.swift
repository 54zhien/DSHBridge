import SwiftUI

struct RootShell: View {
    @State private var model = AppModel()
    @State private var isOpen = false
    private let metrics = DrawerMetrics()

    var body: some View {
        UIKitDrawer(isOpen: $isOpen, metrics: metrics) {
            SidebarView(model: model, isOpen: $isOpen)
        } content: {
            SessionsScreen(model: model, onMenu: {
                withAnimation(metrics.spring) { isOpen = true }
            })
        }
        .ignoresSafeArea()
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    @Binding var isOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                WhaleMark(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DSH Bridge")
                        .font(.title2.weight(.semibold))
                    Text("远程主机")
                        .font(.caption)
                        .foregroundStyle(DSTheme.textSecondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 72)
            .padding(.bottom, 20)

            ForEach(model.hosts) { host in
                Button {
                    model.switchHost(to: host.id)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { isOpen = false }
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(host.isOnline ? .green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(host.note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if host.id == model.activeHostID {
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
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(model.isConnected ? .green : .orange)
                    .frame(width: 6, height: 6)
                Text(model.isConnected ? "已连接" : "未连接")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
