import SwiftUI

struct LoginView: View {
    @Bindable var store: AuthStore
    @State private var showServerField = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 14) {
                Text("DSH Bridge")
                    .font(.largeTitle.weight(.semibold))
                Text("连接你自己的 DSH 桌面端")
                    .font(.subheadline)
                    .foregroundStyle(DSTheme.textSecondary)
            }
            .padding(.bottom, 36)

            if store.providers.isEmpty {
                ProgressView().controlSize(.large)
            } else {
                VStack(spacing: 12) {
                    ForEach(store.providers) { provider in
                        Button {
                            Task { await store.signIn(with: provider) }
                        } label: {
                            Text("用 \(provider.displayName) 登录")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(isWorking)
                    }
                }
                .padding(.horizontal, 28)
            }

            if case let .working(text) = store.phase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.footnote).foregroundStyle(DSTheme.textSecondary)
                }
                .padding(.top, 18)
            }

            if case let .failed(message) = store.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 18)
            }

            Spacer(minLength: 0)

            Button {
                showServerField.toggle()
            } label: {
                Label(store.serverUrl, systemImage: "server.rack")
                    .font(.footnote)
            }
            .buttonStyle(.glass)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSTheme.canvas)
        .task { await store.loadProviders() }
        .sheet(isPresented: $showServerField) {
            ServerEditor(store: store)
        }
    }

    private var isWorking: Bool {
        if case .working = store.phase { return true }
        return false
    }
}

private struct ServerEditor: View {
    @Bindable var store: AuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器地址") {
                    TextField("https://dsh.r2049.cn", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section {
                    ForEach(AuthStore.knownServers, id: \.self) { url in
                        Button(url) { draft = url }
                    }
                }
            }
            .navigationTitle("服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.serverUrl = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                        Task { await store.loadProviders() }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { draft = store.serverUrl }
        }
        .presentationDetents([.medium])
    }
}
