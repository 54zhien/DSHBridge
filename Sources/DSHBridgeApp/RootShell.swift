import SwiftUI

struct RootShell: View {
    @State private var isOpen = false
    private let metrics = DrawerMetrics()

    var body: some View {
        UIKitDrawer(isOpen: $isOpen, metrics: metrics) {
            SidebarView()
        } content: {
            HomeView(onMenu: { withAnimation(metrics.spring) { isOpen = true } })
        }
        .ignoresSafeArea()
    }
}

struct SidebarView: View {
    private let hosts = ["zhien · Windows", "长工教务", "Mac mini"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DSH Bridge")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 22)
                .padding(.top, 72)
                .padding(.bottom, 26)

            ForEach(hosts, id: \.self) { host in
                HStack(spacing: 12) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text(host)
                        .font(.body)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
            }

            Spacer()

            Text("未连接")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct HomeView: View {
    var onMenu: () -> Void
    @State private var showGallery = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onMenu) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                Spacer()
                Text("会话")
                    .font(.headline)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Spacer()
            Text("向右滑动打开侧栏")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("图标校对") { showGallery = true }
                .buttonStyle(.bordered)
                .padding(.top, 12)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .sheet(isPresented: $showGallery) { IconGallery() }
    }
}
