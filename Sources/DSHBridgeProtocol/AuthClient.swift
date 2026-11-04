import Foundation

public struct OAuthProvider: Decodable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let startUrl: String
}

public struct RemoteAPIError: Error, Sendable {
    public let code: String
    public let message: String
    public let status: Int
}

/// 服务器 REST 面。只做登录、设备注册、令牌轮换这三件事，
/// 业务数据全在 Noise 隧道里，不走这里。
public struct AuthClient: Sendable {
    public let baseUrl: URL
    private let session: URLSession

    public init(baseUrl: URL) {
        self.baseUrl = baseUrl
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public func oauthProviders() async throws -> [OAuthProvider] {
        struct Response: Decodable { let items: [OAuthProvider] }
        let response: Response = try await get("/api/v1/auth/oauth/providers")
        return response.items
    }

    public func account(token: String) async throws -> String {
        struct Response: Decodable { let account: String }
        let response: Response = try await get("/api/v1/auth/me", bearer: token)
        return response.account
    }

    /// 用网页授权拿到的一次性 token 注册本机设备，换回长期凭据。
    public func register(identity: DeviceIdentity, accountToken: String, account: String) async throws -> ServerCredentials {
        struct Body: Encodable {
            let v = 1
            struct Device: Encodable {
                let deviceId: String
                let name: String
                let role = "client"
                let platform = "ios"
                let identityKey: String
                let clientVersion: String
            }
            let device: Device
        }
        let body = Body(device: .init(
            deviceId: identity.deviceId,
            name: identity.name,
            identityKey: identity.identityKey,
            clientVersion: "0.1.0"
        ))
        let json = try await post("/api/v1/devices/register", body: body, bearer: accountToken)
        return try Self.credentials(from: json, serverUrl: baseUrl.absoluteString, deviceId: identity.deviceId, account: account)
    }

    public func refresh(deviceId: String, refreshToken: String) async throws -> ServerCredentials {
        struct Body: Encodable { let deviceId: String; let refreshToken: String }
        let json = try await post(
            "/api/v1/auth/refresh",
            body: Body(deviceId: deviceId, refreshToken: refreshToken)
        )
        return try Self.credentials(from: json, serverUrl: baseUrl.absoluteString, deviceId: deviceId, account: nil)
    }

    // MARK: - 传输

    private func get<T: Decodable>(_ path: String, bearer: String? = nil) async throws -> T {
        try await send(path, method: "GET", body: nil, bearer: bearer)
    }

    private func post<T: Encodable>(_ path: String, body: T, bearer: String? = nil) async throws -> Any {
        let data = try JSONEncoder().encode(body)
        return try await sendRaw(path, method: "POST", body: data, bearer: bearer)
    }

    private func send<T: Decodable>(_ path: String, method: String, body: Data?, bearer: String?) async throws -> T {
        let data = try await sendData(path, method: method, body: body, bearer: bearer)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw RemoteAPIError(code: "INVALID_RESPONSE", message: "服务器返回的结构不认识：" + snippet, status: 0)
        }
    }

    private func sendData(_ path: String, method: String, body: Data?, bearer: String?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseUrl) else {
            throw RemoteAPIError(code: "BAD_URL", message: "服务器地址不合法", status: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearer {
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var code = "HTTP_" + String(status)
            var message = String(data: data.prefix(200), encoding: .utf8) ?? ""
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? [String: Any] {
                code = error["code"] as? String ?? code
                message = error["message"] as? String ?? message
            }
            throw RemoteAPIError(code: code, message: message, status: status)
        }
        return data
    }

    private func sendRaw(_ path: String, method: String, body: Data?, bearer: String?) async throws -> Any {
        guard let url = URL(string: path, relativeTo: baseUrl) else {
            throw RemoteAPIError(code: "BAD_URL", message: "服务器地址不合法", status: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)

        guard (200..<300).contains(status) else {
            var code = "HTTP_\(status)"
            var message = String(data: data.prefix(200), encoding: .utf8) ?? ""
            if let object = json as? [String: Any], let error = object["error"] as? [String: Any] {
                code = error["code"] as? String ?? code
                message = error["message"] as? String ?? message
            }
            throw RemoteAPIError(code: code, message: message, status: status)
        }
        return json as Any
    }

    // MARK: - 响应解析

    private static func credentials(from json: Any, serverUrl: String, deviceId: String, account: String?) throws -> ServerCredentials {
        guard let root = json as? [String: Any] else {
            throw RemoteAPIError(code: "INVALID_RESPONSE", message: "注册响应不是 JSON 对象", status: 0)
        }
        // 令牌有的版本平铺，有的版本裹一层 tokens，两种都认
        let tokens = (root["tokens"] as? [String: Any]) ?? root
        func string(_ key: String) -> String? {
            (tokens[key] as? String) ?? (root[key] as? String)
        }
        func number(_ key: String) -> Int64? {
            if let value = tokens[key] as? Int64 { return value }
            if let value = tokens[key] as? Double { return Int64(value) }
            if let value = tokens[key] as? NSNumber { return value.int64Value }
            return nil
        }
        guard let access = string("accessToken"), let refresh = string("refreshToken") else {
            throw RemoteAPIError(code: "INVALID_RESPONSE", message: "注册响应里没有令牌", status: 0)
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return ServerCredentials(
            serverUrl: serverUrl,
            deviceId: deviceId,
            account: (root["account"] as? String) ?? account,
            accessToken: access,
            refreshToken: refresh,
            accessTokenExpiresAt: number("accessTokenExpiresAt") ?? (now + 10 * 60 * 1000),
            refreshTokenExpiresAt: number("refreshTokenExpiresAt") ?? (now + 30 * 24 * 3600 * 1000)
        )
    }
}
