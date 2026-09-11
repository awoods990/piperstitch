import Foundation

/// The app's side of License Admin's `/api/app/*` JSON endpoints. Pure
/// transport: it returns what the server said and leaves deciding what
/// it means to `LicenseManager`. Every error the server deliberately
/// returns arrives as `LicenseAPIError.server(code:message:)` with the
/// server's own plain-language message, ready to show verbatim.
public struct LicenseAPIClient: Sendable {
    public struct CodeRequestResult: Decodable, Sendable {
        public let sent: Bool
        /// "ok" | "no_subscription" | "subscription_ended"
        public let reason: String
        public let subscribe_url: String?
        public let account_url: String?
    }

    public struct SignInResult: Decodable, Sendable {
        public let device_token: String
        public let entitlement: String
        public let email: String
        public let name: String
    }

    public struct RefreshResult: Decodable, Sendable {
        /// nil when the subscription has ended (HTTP 402) — the caller
        /// keeps the old entitlement until it expires on its own.
        public let entitlement: String?
        public let status: String
        public let entitled: Bool
        public let email: String?
        public let account_url: String?
    }

    public struct PortalResult: Decodable, Sendable {
        public let url: String
    }

    private struct ServerError: Decodable {
        let error: String
        let message: String
    }

    public enum LicenseAPIError: Error, LocalizedError, Equatable {
        /// The server answered with a deliberate error: `code` is
        /// machine-readable ("device_limit", "code_wrong", "device_revoked",
        /// "subscription_ended", ...), `message` is for the user.
        case server(code: String, message: String)
        case network(String)
        case badResponse

        public var errorDescription: String? {
            switch self {
            case .server(_, let message): return message
            case .network(let text): return "Couldn't reach PiperStitch's servers: \(text)"
            case .badResponse: return "PiperStitch's server sent an unexpected reply."
            }
        }
    }

    public let baseURL: URL
    public let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func requestCode(email: String, deviceID: String, deviceName: String) async throws -> CodeRequestResult {
        try await post("/api/app/activate/request", ["email": email, "device_id": deviceID, "device_name": deviceName])
    }

    public func verifyCode(email: String, code: String, deviceID: String, deviceName: String) async throws -> SignInResult {
        try await post("/api/app/activate/verify", ["email": email, "code": code, "device_id": deviceID, "device_name": deviceName])
    }

    /// A 402 (subscription ended) is NOT thrown: it comes back as a
    /// `RefreshResult` with `entitlement == nil`, because that's a normal
    /// state the caller handles, not a failure.
    public func refreshEntitlement(deviceToken: String) async throws -> RefreshResult {
        try await post("/api/app/entitlement", ["device_token": deviceToken], acceptStatuses: [200, 402])
    }

    public func signOut(deviceToken: String) async throws {
        struct Ok: Decodable { let ok: Bool }
        let _: Ok = try await post("/api/app/signout", ["device_token": deviceToken])
    }

    public func billingPortalURL(deviceToken: String) async throws -> URL {
        let result: PortalResult = try await post("/api/app/billing-portal", ["device_token": deviceToken])
        guard let url = URL(string: result.url) else { throw LicenseAPIError.badResponse }
        return url
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: String], acceptStatuses: Set<Int> = [200]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("PiperStitch-Mac", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LicenseAPIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw LicenseAPIError.badResponse }
        if !acceptStatuses.contains(http.statusCode) {
            if let err = try? JSONDecoder().decode(ServerError.self, from: data) {
                throw LicenseAPIError.server(code: err.error, message: err.message)
            }
            throw LicenseAPIError.server(code: "http_\(http.statusCode)", message: "PiperStitch's server returned an error (\(http.statusCode)). Please try again.")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LicenseAPIError.badResponse
        }
    }
}
