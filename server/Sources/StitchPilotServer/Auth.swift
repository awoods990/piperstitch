import Foundation
import Vapor

// Accounts for the web edition. License Admin (repo: license-admin/) is
// the authority -- it holds customers, the trial, Stripe's mirror and the
// projects -- and this server talks to it server-to-server with a shared
// key. What the browser holds is a signed, HttpOnly cookie carrying the
// License Admin session token plus a cached copy of the account's
// standing, re-checked against License Admin when it gets old. Nothing is
// stored here, so the server stays stateless.
//
// With LICENSE_ADMIN_URL unset (local development), accounts are off:
// every engine route is open and /auth/me says so.

struct AuthConfig {
    let licenseAdminURL: String?
    let webAPIKey: String
    let sessionSecret: SymmetricKey
    let secureCookies: Bool
    /// Where PiperStitch Proofs lives, for the sign-in page's link and
    /// the Settings offer (PROOFS_APP_URL).
    let proofsURL: String

    var enabled: Bool { licenseAdminURL != nil }

    static func fromEnvironment(_ app: Application) -> AuthConfig {
        let url = Environment.get("LICENSE_ADMIN_URL").flatMap { $0.isEmpty ? nil : $0 }?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let secret = Environment.get("SESSION_SECRET") ?? ""
        if url != nil && secret.count < 32 {
            app.logger.critical("SESSION_SECRET must be set (32+ characters) when LICENSE_ADMIN_URL is configured.")
        }
        if url == nil {
            app.logger.warning("LICENSE_ADMIN_URL is not set: accounts are OFF, every route is open. Fine for development only.")
        }
        return AuthConfig(
            licenseAdminURL: url,
            webAPIKey: Environment.get("WEB_API_KEY") ?? "",
            sessionSecret: SymmetricKey(data: Data((secret.isEmpty ? "development-only-secret-not-for-production" : secret).utf8)),
            secureCookies: app.environment == .production,
            proofsURL: (Environment.get("PROOFS_APP_URL").flatMap { $0.isEmpty ? nil : $0 } ?? "https://proofs.piperstitch.com").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
    }
}

struct AuthConfigKey: StorageKey { typealias Value = AuthConfig }

extension Application {
    var auth: AuthConfig {
        get { storage[AuthConfigKey.self]! }
        set { storage[AuthConfigKey.self] = newValue }
    }
}

// MARK: - What License Admin tells us about an account

struct AccountState: Content {
    var customerId: Int
    var email: String
    var name: String
    /// 'active' | 'trialing' | 'past_due' | 'comp' | 'none' | 'ended'
    var status: String
    var entitled: Bool
    var validUntil: String?
    var periodEnd: String?
    var cancelAtPeriodEnd: Bool
    var hasBilling: Bool
    var priceCents: Int
    var currency: String
    var trialDays: Int
    /// PiperStitch Proofs on the same customer (nil from an older cookie).
    var proofs: ProofsState?

    enum CodingKeys: String, CodingKey {
        case customerId = "customer_id", email, name, status, entitled
        case validUntil = "valid_until", periodEnd = "period_end", cancelAtPeriodEnd = "cancel_at_period_end"
        case hasBilling = "has_billing", priceCents = "price_cents", currency, trialDays = "trial_days", proofs
    }
}

/// The Proofs plan as License Admin reports it: subscribed, or so many
/// free proofs used of the trial. Carried through untouched.
struct ProofsState: Content {
    var subscribed: Bool
    var status: String
    var freeGranted: Int
    var freeUsed: Int
    var freeLeft: Int
    var canSend: Bool
    var hasBilling: Bool
    var priceCents: Int
    var url: String

    enum CodingKeys: String, CodingKey {
        case subscribed, status, url
        case freeGranted = "free_granted", freeUsed = "free_used", freeLeft = "free_left", canSend = "can_send", hasBilling = "has_billing", priceCents = "price_cents"
    }
}

struct LicenseAdminFailure: Decodable { var error: String?; var message: String?; var detail: String? }

struct LicenseAdminError: Error, AbortError {
    var status: HTTPResponseStatus
    var code: String
    var reason: String
}

/// The half-dozen License Admin calls this server makes, all POST JSON
/// with the shared key. Errors come back in License Admin's own
/// `{error, message}` shape and are re-thrown with the same status so the
/// browser sees the message as written.
struct LicenseAdminClient {
    let req: Request

    private var base: String { req.application.auth.licenseAdminURL ?? "" }

    func post<In: Content, Out: Decodable>(_ path: String, _ body: In, query: [String: String] = [:], as: Out.Type) async throws -> Out {
        var uri = URI(string: base + path)
        if !query.isEmpty { uri.query = query.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&") }
        let res = try await req.client.post(uri, headers: ["X-API-Key": req.application.auth.webAPIKey]) { try $0.content.encode(body) }
        if res.status.code >= 400 {
            let failure = try? res.content.decode(LicenseAdminFailure.self)
            throw LicenseAdminError(status: res.status, code: failure?.error ?? "license_admin",
                                    reason: failure?.message ?? failure?.detail ?? "The account service returned \(res.status.code).")
        }
        return try res.content.decode(Out.self)
    }
}

extension Request {
    var licenseAdmin: LicenseAdminClient { LicenseAdminClient(req: self) }
}

// MARK: - The cookie

/// The payload behind `ps_session`: base64url(JSON) + "." + base64url(HMAC).
struct SessionPayload: Codable {
    var token: String
    var account: AccountState
    /// When `account` was last confirmed with License Admin (unix seconds).
    var checkedAt: Int
}

enum SessionCookie {
    static let name = "ps_session"
    static let maxAge = 60 * 60 * 24 * 30
    /// How stale the cached account standing may be before the next request
    /// re-checks it -- the Mac app refreshes every 12 h; a browser is
    /// online anyway so we can afford more often.
    static let recheckAfter: TimeInterval = 60 * 60 * 2

    static func encode(_ payload: SessionPayload, key: SymmetricKey) throws -> String {
        let body = try JSONEncoder().encode(payload).base64URLEncodedString()
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)).base64URLEncodedString()
        return body + "." + mac
    }

    static func decode(_ value: String, key: SymmetricKey) -> SessionPayload? {
        let parts = value.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let body = Data(base64URLEncoded: parts[0]), let mac = Data(base64URLEncoded: parts[1]) else { return nil }
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(parts[0].utf8), using: key) else { return nil }
        return try? JSONDecoder().decode(SessionPayload.self, from: body)
    }

    static func set(_ payload: SessionPayload?, on response: Response, app: Application) {
        if let payload, let value = try? encode(payload, key: app.auth.sessionSecret) {
            response.cookies[name] = .init(string: value, maxAge: maxAge, isSecure: app.auth.secureCookies, isHTTPOnly: true, sameSite: .lax)
        } else {
            response.cookies[name] = .init(string: "", expires: Date(timeIntervalSince1970: 0), isSecure: app.auth.secureCookies, isHTTPOnly: true, sameSite: .lax)
        }
    }
}

struct SessionKey: StorageKey { typealias Value = SessionPayload }

extension Request {
    /// The verified session on this request, if any; refreshed against
    /// License Admin when its cached standing is old. A refresh that fails
    /// because License Admin revoked the session counts as signed out.
    func session(forceRefresh: Bool = false) async -> SessionPayload? {
        if let cached = storage[SessionKey.self], !forceRefresh { return cached }
        guard let raw = cookies[SessionCookie.name]?.string, var payload = SessionCookie.decode(raw, key: application.auth.sessionSecret) else { return nil }
        let age = Date().timeIntervalSince1970 - Double(payload.checkedAt)
        // The cached standing carries its own expiry: the moment a trial or
        // paid period passes, re-check rather than coast on the cache.
        let lapsed = payload.account.validUntil.flatMap { ISO8601DateFormatter().date(from: $0) }.map { $0 <= Date() } ?? false
        if forceRefresh || age > SessionCookie.recheckAfter || (payload.account.entitled && lapsed) {
            struct TokenIn: Content { var token: String }
            do {
                payload.account = try await licenseAdmin.post("/api/web/session", TokenIn(token: payload.token), as: AccountState.self)
                payload.checkedAt = Int(Date().timeIntervalSince1970)
                storage[RefreshedSessionKey.self] = true
            } catch let error as LicenseAdminError where error.status == .unauthorized {
                return nil
            } catch {
                // License Admin unreachable: keep going on the cached standing
                // rather than locking everyone out during its bad moment.
                logger.warning("Session refresh failed, using cached standing: \(error)")
            }
        }
        storage[SessionKey.self] = payload
        return payload
    }
}

struct RefreshedSessionKey: StorageKey { typealias Value = Bool }

/// Gates the engine routes: signed in and entitled (trial or paid), or
/// accounts are off. On a refreshed session the renewed cookie rides
/// along with the response so the re-check isn't repeated.
/// What a browser should be told about how to treat our pages: don't
/// guess content types, don't let another site frame us, don't leak the
/// full URL to third parties, and stay on HTTPS once you've arrived.
struct SecurityHeaders: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "strict-origin-when-cross-origin")
        if request.application.environment == .production {
            response.headers.replaceOrAdd(name: "Strict-Transport-Security", value: "max-age=15552000; includeSubDomains")
        }
        return response
    }
}

struct EntitlementGate: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard request.application.auth.enabled else { return try await next.respond(to: request) }
        guard let session = await request.session() else {
            throw Abort(.unauthorized, reason: "Sign in to use PiperStitch.")
        }
        guard session.account.entitled else {
            throw Abort(.paymentRequired, reason: session.account.status == "trialing" || session.account.status == "ended"
                        ? "Your free trial has ended. Subscribe to keep using PiperStitch."
                        : "This account doesn't have an active subscription.")
        }
        let response = try await next.respond(to: request)
        if request.storage[RefreshedSessionKey.self] == true {
            SessionCookie.set(session, on: response, app: request.application)
        }
        return response
    }
}

// MARK: - base64url

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
