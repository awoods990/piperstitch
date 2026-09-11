import CryptoKit
import Foundation

/// A signed statement from License Admin: "customer N, on device D, may
/// use PiperStitch until `expiresAt`." The subscription-world replacement
/// for a license key — short-lived, refreshed silently, and verified here
/// against the public key in `LicenseConfig` so the app never has to trust
/// the network or a value on disk.
///
/// Wire format, kept byte-for-byte in sync with license-admin's
/// app/entitlement.py:
///
///     PSE1.<base64url(payload JSON, no padding)>.<base64url(64-byte Ed25519 signature)>
///
/// The signature covers the exact payload bytes; verification happens
/// BEFORE the JSON is parsed, and nothing in the payload is trusted until
/// it has.
public struct Entitlement: Equatable, Sendable {
    public let customerID: Int
    public let deviceID: String
    public let email: String
    /// 'active' | 'trialing' | 'past_due' | 'comp' — for display only.
    public let status: String
    public let expiresAt: Date
    public let issuedAt: Date
    /// The billing period's real end (nil for a comp with no end set).
    public let periodEnd: Date?
    public let cancelAtPeriodEnd: Bool
    /// The token exactly as received, for storage and re-verification.
    public let token: String

    public func isValid(at now: Date = Date()) -> Bool { now < expiresAt }
}

public enum EntitlementError: Error, Equatable, LocalizedError {
    case malformed
    case badSignature
    case unsupportedVersion
    case corruptPayload
    case wrongDevice
    case badPublicKey

    public var errorDescription: String? {
        switch self {
        case .malformed: return "That isn't a PiperStitch entitlement."
        case .badSignature: return "This entitlement isn't valid."
        case .unsupportedVersion: return "This entitlement was issued in a newer format than this version of PiperStitch understands. Please update the app."
        case .corruptPayload: return "This entitlement is corrupted."
        case .wrongDevice: return "This entitlement was issued to a different Mac."
        case .badPublicKey: return "The app's licensing key is misconfigured."
        }
    }
}

public enum EntitlementVerifier {
    static let prefix = "PSE1"
    static let version = 1

    private struct Payload: Decodable {
        let v: Int
        let cid: Int
        let dev: String
        let email: String
        let status: String
        let exp: String
        let iat: String
        let period_end: String?
        let cancel_at_period_end: Bool?
    }

    /// Verifies the signature and returns the entitlement — or throws.
    /// `expectedDeviceID` binds the token to this Mac: a token copied from
    /// another machine fails even though its signature is genuine.
    public static func verify(_ token: String, publicKeyBase64: String, expectedDeviceID: String? = nil) throws -> Entitlement {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == prefix,
              let payloadBytes = base64URLDecode(parts[1]),
              let signature = base64URLDecode(parts[2]), signature.count == 64 else {
            throw EntitlementError.malformed
        }
        guard let keyBytes = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            throw EntitlementError.badPublicKey
        }
        guard publicKey.isValidSignature(signature, for: payloadBytes) else {
            throw EntitlementError.badSignature
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: payloadBytes)
        } catch {
            throw EntitlementError.corruptPayload
        }
        guard payload.v == version else { throw EntitlementError.unsupportedVersion }
        guard let exp = parseISO8601(payload.exp), let iat = parseISO8601(payload.iat) else {
            throw EntitlementError.corruptPayload
        }
        if let expected = expectedDeviceID, expected != payload.dev {
            throw EntitlementError.wrongDevice
        }
        return Entitlement(
            customerID: payload.cid,
            deviceID: payload.dev,
            email: payload.email,
            status: payload.status,
            expiresAt: exp,
            issuedAt: iat,
            periodEnd: payload.period_end.flatMap(parseISO8601),
            cancelAtPeriodEnd: payload.cancel_at_period_end ?? false,
            token: trimmed
        )
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }

    static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
