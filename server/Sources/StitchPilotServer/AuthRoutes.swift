import Foundation
import Vapor
import StitchPilotCore

/// What the browser sees of its own account. `authEnabled: false` means
/// the server runs without License Admin (development) and everything is
/// open.
struct MeResponse: Content {
    var authEnabled: Bool
    var signedIn: Bool
    var account: AccountState?
}

struct ProjectSummary: Content {
    var id: String
    var name: String
    var widthMM: Double
    var heightMM: Double
    var objectCount: Int
    var createdAt: String
    var updatedAt: String
}

/// License Admin's row shape (snake_case), mapped to the browser's.
private struct LicenseAdminProject: Decodable {
    var id: String; var name: String; var width_mm: Double; var height_mm: Double; var object_count: Int; var created_at: String; var updated_at: String
    var summary: ProjectSummary { .init(id: id, name: name, widthMM: width_mm, heightMM: height_mm, objectCount: object_count, createdAt: created_at, updatedAt: updated_at) }
}

func authRoutes(_ api: RoutesBuilder) {
    let auth = api.grouped("auth")

    auth.get("me") { req -> Response in
        guard req.application.auth.enabled else {
            return try await MeResponse(authEnabled: false, signedIn: false, account: nil).encodeResponse(for: req)
        }
        let force = (try? req.query.get(Bool.self, at: "refresh")) ?? false
        let session = await req.session(forceRefresh: force)
        let response = try await MeResponse(authEnabled: true, signedIn: session != nil, account: session?.account).encodeResponse(for: req)
        if let session, req.storage[RefreshedSessionKey.self] == true {
            SessionCookie.set(session, on: response, app: req.application)
        } else if session == nil, req.cookies[SessionCookie.name] != nil {
            SessionCookie.set(nil, on: response, app: req.application)  // clear a dead cookie
        }
        return response
    }

    auth.post("request") { req -> [String: Bool] in
        try requireEnabled(req)
        struct In: Content { var email: String }
        let body = try req.content.decode(In.self)
        struct Out: Decodable { var sent: Bool }
        let out = try await req.licenseAdmin.post("/api/web/signin/request", In(email: body.email.trimmingCharacters(in: .whitespaces)), as: Out.self)
        return ["sent": out.sent]
    }

    auth.post("verify") { req -> Response in
        try requireEnabled(req)
        struct In: Content { var email: String; var code: String; var user_agent: String }
        struct Body: Content { var email: String; var code: String }
        let body = try req.content.decode(Body.self)
        let userAgent = req.headers.first(name: .userAgent) ?? ""
        struct Out: Decodable { var token: String }
        let raw = try await req.licenseAdmin.post("/api/web/signin/verify",
                                                  In(email: body.email.trimmingCharacters(in: .whitespaces), code: body.code.trimmingCharacters(in: .whitespaces), user_agent: userAgent),
                                                  as: VerifyOut.self)
        let payload = SessionPayload(token: raw.token, account: raw.account, checkedAt: Int(Date().timeIntervalSince1970))
        let response = try await MeResponse(authEnabled: true, signedIn: true, account: raw.account).encodeResponse(for: req)
        SessionCookie.set(payload, on: response, app: req.application)
        return response
    }

    auth.post("signout") { req -> Response in
        try requireEnabled(req)
        struct TokenIn: Content { var token: String }
        struct Out: Decodable { var ok: Bool }
        if let session = await req.session() {
            _ = try? await req.licenseAdmin.post("/api/web/signout", TokenIn(token: session.token), as: Out.self)
        }
        let response = Response(status: .noContent)
        SessionCookie.set(nil, on: response, app: req.application)
        return response
    }

    auth.post("checkout") { req -> [String: String] in
        let session = try await requireSession(req)
        struct Body: Content { var promoCode: String? }
        let body = (try? req.content.decode(Body.self)) ?? Body(promoCode: nil)
        struct In: Content { var token: String; var promo_code: String }
        struct Out: Decodable { var url: String }
        return ["url": try await req.licenseAdmin.post("/api/web/checkout", In(token: session.token, promo_code: body.promoCode ?? ""), as: Out.self).url]
    }

    auth.post("profile") { req -> Response in
        let session = try await requireSession(req)
        struct Body: Content { var name: String }
        let body = try req.content.decode(Body.self)
        struct In: Content { var token: String; var name: String }
        let account = try await req.licenseAdmin.post("/api/web/profile", In(token: session.token, name: body.name), as: AccountState.self)
        var updated = session; updated.account = account; updated.checkedAt = Int(Date().timeIntervalSince1970)
        let response = try await MeResponse(authEnabled: true, signedIn: true, account: account).encodeResponse(for: req)
        SessionCookie.set(updated, on: response, app: req.application)
        return response
    }

    /// The Send button: flatten the document, encode the machine file, and
    /// have License Admin email it on the customer's behalf.
    auth.post("send") { req -> [String: Bool] in
        let session = try await requireSession(req)
        struct Body: Content { var document: StitchDocument; var format: String; var toEmail: String; var message: String? }
        let body = try req.content.decode(Body.self)
        guard let format = ExportFormat(rawValue: body.format.lowercased()) else { throw Abort(.badRequest, reason: "Unknown export format.") }
        let document = body.document
        let data = try await Engine.run { () throws -> Data in
            let (plan, colors) = try DigitizePipeline.flattenWithColors(document)
            return try format.write(plan, designName: document.name, threadColors: colors.map(\.rgb))
        }
        let safeName = document.name.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
        struct In: Content { var token: String; var to_email: String; var filename: String; var content_base64: String; var message: String; var design_name: String }
        struct Out: Decodable { var sent: Bool }
        let out = try await req.licenseAdmin.post("/api/web/send-file", In(token: session.token, to_email: body.toEmail, filename: "\(safeName).\(format.rawValue)",
                                                                        content_base64: data.base64EncodedString(), message: body.message ?? "", design_name: document.name), as: Out.self)
        return ["sent": out.sent]
    }

    /// Is this promo code usable by the signed-in account, and what does it give?
    auth.post("promo") { req -> PromoValidation in
        let session = try await requireSession(req)
        struct Body: Content { var code: String }
        let body = try req.content.decode(Body.self)
        struct In: Content { var token: String; var code: String }
        return try await req.licenseAdmin.post("/api/web/promo/validate", In(token: session.token, code: body.code), as: PromoValidation.self)
    }

    auth.post("billing-portal") { req -> [String: String] in
        let session = try await requireSession(req)
        struct TokenIn: Content { var token: String }
        struct Out: Decodable { var url: String }
        return ["url": try await req.licenseAdmin.post("/api/web/billing-portal", TokenIn(token: session.token), as: Out.self).url]
    }

    // Preferences: the browser's per-user settings (default hoop, thread
    // library...) mirrored to the account so they follow the user between
    // browsers. Opaque JSON both ways.
    auth.get("preferences") { req -> Response in
        let session = try await requireSession(req)
        struct TokenIn: Content { var token: String }
        struct Out: Decodable { var preferences: AnyJSON; var updated_at: String? }
        let out = try await req.licenseAdmin.post("/api/web/preferences/get", TokenIn(token: session.token), as: Out.self)
        let response = Response(status: .ok)
        try response.content.encode(["preferences": out.preferences, "updatedAt": out.updated_at.map(AnyJSON.string) ?? .null])
        return response
    }

    auth.put("preferences") { req -> [String: String] in
        let session = try await requireSession(req)
        struct Body: Content { var preferences: AnyJSON }
        let body = try req.content.decode(Body.self)
        struct In: Content { var token: String; var preferences: AnyJSON }
        struct Out: Decodable { var updated_at: String }
        return ["updatedAt": try await req.licenseAdmin.post("/api/web/preferences/save", In(token: session.token, preferences: body.preferences), as: Out.self).updated_at]
    }

    // Projects: the StitchDocument JSON, kept by License Admin per account.
    let projects = api.grouped("projects").grouped(EntitlementGate())

    projects.get { req -> [ProjectSummary] in
        let session = try await requireSession(req)
        struct TokenIn: Content { var token: String }
        struct Out: Decodable { var projects: [LicenseAdminProject] }
        return try await req.licenseAdmin.post("/api/web/projects/list", TokenIn(token: session.token), as: Out.self).projects.map(\.summary)
    }

    projects.get(":id") { req -> Response in
        let session = try await requireSession(req)
        let id = try projectID(req)
        struct TokenIn: Content { var token: String }
        struct Out: Decodable { var id: String; var name: String; var document: StitchDocumentJSON; var updated_at: String }
        let out = try await req.licenseAdmin.post("/api/web/projects/get", TokenIn(token: session.token), query: ["id": id], as: Out.self)
        let response = Response(status: .ok)
        try response.content.encode(["id": AnyJSON.string(out.id), "name": .string(out.name), "updatedAt": .string(out.updated_at), "document": out.document.value])
        return response
    }

    projects.put(":id") { req -> [String: Bool] in
        let session = try await requireSession(req)
        let id = try projectID(req)
        struct Body: Content { var name: String?; var document: AnyJSON }
        let body = try req.content.decode(Body.self)
        struct In: Content { var token: String; var id: String; var name: String; var document: AnyJSON }
        struct Out: Decodable { var created: Bool }
        let out = try await req.licenseAdmin.post("/api/web/projects/save", In(token: session.token, id: id, name: body.name ?? "", document: body.document), as: Out.self)
        return ["created": out.created]
    }

    projects.delete(":id") { req -> [String: Bool] in
        let session = try await requireSession(req)
        let id = try projectID(req)
        struct TokenIn: Content { var token: String }
        struct Out: Decodable { var deleted: Bool }
        return ["deleted": try await req.licenseAdmin.post("/api/web/projects/delete", TokenIn(token: session.token), query: ["id": id], as: Out.self).deleted]
    }

    // "Send feedback": the original artwork and a picture of the digitized
    // result, forwarded to License Admin for review (repo: license-admin/
    // -- see its own /api/web/feedback and the /admin/feedback pages).
    // Gated the same as projects: only a signed-in, entitled account can
    // send feedback, which is already guaranteed by the time there's a
    // digitized result to send.
    let feedback = api.grouped("feedback").grouped(EntitlementGate())
    feedback.post { req -> [String: Int] in
        let session = try await requireSession(req)
        struct Body: Content {
            var note: String?
            var designName: String?
            var stitchCount: Int?
            var originalImageBase64: String?
            var originalImageType: String?
            var digitizedImageBase64: String
            var digitizedImageType: String?
        }
        let body = try req.content.decode(Body.self)
        struct In: Content {
            var token: String
            var note: String
            var design_name: String
            var stitch_count: Int
            var original_image_base64: String?
            var original_image_type: String
            var digitized_image_base64: String
            var digitized_image_type: String
        }
        struct Out: Decodable { var id: Int }
        let out = try await req.licenseAdmin.post("/api/web/feedback", In(
            token: session.token, note: body.note ?? "", design_name: body.designName ?? "", stitch_count: body.stitchCount ?? 0,
            original_image_base64: body.originalImageBase64, original_image_type: body.originalImageType ?? "image/png",
            digitized_image_base64: body.digitizedImageBase64, digitized_image_type: body.digitizedImageType ?? "image/png"
        ), as: Out.self)
        return ["id": out.id]
    }
}

struct PromoValidation: Content {
    var valid: Bool
    var code: String?
    var percent_off: Double?
    var duration_months: Int?
    var description: String?
    var error: String?
    var message: String?
}

private struct VerifyOut: Decodable {
    var token: String
    var account: AccountState
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        token = try c.decode(String.self, forKey: .token)
        account = try AccountState(from: decoder)
    }
    enum Key: String, CodingKey { case token }
}

/// A project document passes through this server untouched (License
/// Admin stores it as JSON; the engine routes decode it as a real
/// StitchDocument when it's used), so it's carried as opaque JSON here.
struct StitchDocumentJSON: Decodable { var value: AnyJSON; init(from decoder: Decoder) throws { value = try AnyJSON(from: decoder) } }

enum AnyJSON: Content {
    case string(String), number(Double), bool(Bool), null, array([AnyJSON]), object([String: AnyJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([AnyJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: AnyJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

private func requireEnabled(_ req: Request) throws {
    guard req.application.auth.enabled else { throw Abort(.notImplemented, reason: "Accounts are not configured on this server.") }
}

private func requireSession(_ req: Request) async throws -> SessionPayload {
    try requireEnabled(req)
    guard let session = await req.session() else { throw Abort(.unauthorized, reason: "Sign in to use PiperStitch.") }
    return session
}

private func projectID(_ req: Request) throws -> String {
    guard let id = req.parameters.get("id"), !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
        throw Abort(.badRequest, reason: "Invalid project id.")
    }
    return id
}
