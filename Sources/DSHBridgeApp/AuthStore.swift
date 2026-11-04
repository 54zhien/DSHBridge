import AuthenticationServices
import SwiftUI
import UIKit

/// 登录状态。把「服务器地址 → OAuth → 设备注册 → 主机列表」串起来，
/// 只暴露 UI 真正需要的几个字段。
@MainActor
@Observable
final class AuthStore {
    enum Phase: Equatable {
        case signedOut
        case working(String)
        case signedIn
        case failed(String)
    }

    var serverUrl: String {
        didSet { UserDefaults.standard.set(serverUrl, forKey: "serverUrl") }
    }
    var phase: Phase = .signedOut
    var account: String?
    var devices: [RemoteDevice] = []
    var providers: [OAuthProvider] = []

    private var credentials: ServerCredentials?
    private var identity: DeviceIdentity
    private var session: ASWebAuthenticationSession?

    static let knownServers = ["https://dsh.r2049.cn"]

    init() {
        serverUrl = UserDefaults.standard.string(forKey: "serverUrl") ?? Self.knownServers[0]
        if let stored = IdentityStore.loadIdentity() {
            identity = stored
        } else {
            let created = DeviceIdentity.generate(name: UIDevice.current.name)
            IdentityStore.save(identity: created)
            identity = created
        }
        if let saved = IdentityStore.loadCredentials(serverUrl: serverUrl) {
            credentials = saved
            account = saved.account
            phase = .signedIn
        }
    }

    var baseUrl: URL? { URL(string: serverUrl) }

    func loadProviders() async {
        guard let baseUrl else { phase = .failed("服务器地址不合法"); return }
        do {
            providers = try await AuthClient(baseUrl: baseUrl).oauthProviders()
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    func signIn(with provider: OAuthProvider) async {
        guard let baseUrl else { return }
        phase = .working("正在打开 \(provider.displayName)")
        do {
            let token = try await runWebAuth(startUrl: baseUrl.appending(path: provider.startUrl), provider: provider)
            phase = .working("正在注册设备")
            let client = AuthClient(baseUrl: baseUrl)
            let account = try await client.account(token: token)
            let credentials = try await client.register(identity: identity, accountToken: token, account: account)
            IdentityStore.save(credentials: credentials)
            self.credentials = credentials
            self.account = credentials.account
            phase = .signedIn
            await refreshDevices()
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// 建链需要：服务器地址、可用的 access token、本机身份。
    func liveContext() async throws -> (baseUrl: URL, token: String, identity: DeviceIdentity) {
        guard let credentials, let baseUrl else {
            throw RemoteAPIError(code: "NOT_SIGNED_IN", message: "尚未登录", status: 0)
        }
        let fresh = try await validCredentials(credentials, baseUrl: baseUrl)
        return (baseUrl, fresh.accessToken, identity)
    }

    func refreshDevices() async {
        guard let credentials, let baseUrl else { return }
        do {
            let fresh = try await validCredentials(credentials, baseUrl: baseUrl)
            devices = try await DeviceClient(baseUrl: baseUrl, token: fresh.accessToken).devices()
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    func signOut() {
        if let credentials { IdentityStore.clearCredentials(serverUrl: credentials.serverUrl) }
        credentials = nil
        account = nil
        devices = []
        phase = .signedOut
    }

    private func validCredentials(_ current: ServerCredentials, baseUrl: URL) async throws -> ServerCredentials {
        if current.isAccessTokenFresh { return current }
        let refreshed = try await AuthClient(baseUrl: baseUrl)
            .refresh(deviceId: current.deviceId, refreshToken: current.refreshToken)
        var merged = refreshed
        merged.account = merged.account ?? current.account
        IdentityStore.save(credentials: merged)
        credentials = merged
        return merged
    }

    private func runWebAuth(startUrl: URL, provider: OAuthProvider) async throws -> String {
        var components = URLComponents(url: startUrl, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "return_to", value: "dshremote://oauth")]
        guard let url = components?.url else {
            throw RemoteAPIError(code: "BAD_URL", message: "授权地址不合法", status: 0)
        }

        let token: String = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "dshremote") { callback, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callback,
                      let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                      let token = items.first(where: { $0.name == "token" })?.value,
                      token.count >= 16 else {
                    continuation.resume(throwing: RemoteAPIError(code: "NO_TOKEN", message: "授权回调里没有 token", status: 0))
                    return
                }
                continuation.resume(returning: token)
            }
            session.presentationContextProvider = WebAuthPresenter.shared
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: RemoteAPIError(code: "AUTH_START", message: "无法打开授权页面", status: 0))
            }
        }
        session = nil
        return token
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let api = error as? RemoteAPIError { return "\(api.code)：\(api.message)" }
        let ns = error as NSError
        return ns.localizedDescription
    }
}

private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthPresenter()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

public struct RemoteDevice: Decodable, Sendable, Identifiable {
    public let deviceId: String
    public let name: String?
    public let platform: String?
    public let online: Bool?
    public var id: String { deviceId }
}

struct DeviceClient: Sendable {
    let baseUrl: URL
    let token: String

    func devices() async throws -> [RemoteDevice] {
        struct Response: Decodable { let items: [RemoteDevice] }
        var request = URLRequest(url: baseUrl.appending(path: "/api/v1/devices"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw RemoteAPIError(code: "HTTP_\(status)", message: String(data: data.prefix(160), encoding: .utf8) ?? "", status: status)
        }
        return try JSONDecoder().decode(Response.self, from: data).items
    }

    /// 设备列表里没有 identityKey，必须单取一台。
    func identityKey(deviceId: String) async throws -> Data {
        struct Response: Decodable { let identityKey: String }
        var request = URLRequest(url: baseUrl.appending(path: "/api/v1/devices/\(deviceId)"))
        request.setValue("Bearer (token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw RemoteAPIError(code: "HTTP_\(status)", message: String(data: data.prefix(160), encoding: .utf8) ?? "", status: status)
        }
        let key = try JSONDecoder().decode(Response.self, from: data).identityKey
        guard let raw = Base64URL.decode(key) else {
            throw RemoteAPIError(code: "BAD_KEY", message: "identityKey 解不出来", status: 0)
        }
        return raw
    }
}
