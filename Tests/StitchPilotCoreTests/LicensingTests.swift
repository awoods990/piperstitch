import CryptoKit
import Foundation
import XCTest
@testable import StitchPilotCore

/// The app's side of the subscription contract with license-admin: the
/// entitlement verifier, the trial clock, the status evaluator, and the
/// update-feed parser. Every token here is signed with a throwaway key
/// generated in the test — except the interop fixture, which was signed
/// by the real Python service (`app/entitlement.py`) with a deterministic
/// test key, to prove the two implementations agree byte for byte.
final class LicensingTests: XCTestCase {

    // MARK: fixtures

    /// Signed by license-admin's entitlement.sign() using the private key
    /// bytes 0x00…0x1f. If this ever fails to verify, the Python and Swift
    /// wire formats have drifted apart — fix that, don't regenerate this.
    static let pythonPublicKey = "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="
    static let pythonToken = "PSE1.eyJjYW5jZWxfYXRfcGVyaW9kX2VuZCI6ZmFsc2UsImNpZCI6NDIsImRldiI6IkZJWFRVUkUtTUFDIiwiZW1haWwiOiJmaXh0dXJlQGV4YW1wbGUuY29tIiwiZXhwIjoiMjA5OS0wMS0wMVQwMDowMDowMFoiLCJpYXQiOiIyMDI2LTA5LTExVDAwOjAwOjAwWiIsInBlcmlvZF9lbmQiOiIyMDk4LTEyLTIwVDAwOjAwOjAwWiIsInN0YXR1cyI6ImFjdGl2ZSIsInYiOjF9.DEGmVPsg-sO21byI4yJBV_m8CueGEDQgkboOggHIOQzk4wDbvg0MVco8QDt-slT_qdv8vN-wlm4gtugua6BqDw"

    private struct Signer {
        let key = Curve25519.Signing.PrivateKey()
        var publicKeyBase64: String { key.publicKey.rawRepresentation.base64EncodedString() }

        func token(payload: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let sig = try! key.signature(for: data)
            return "PSE1.\(b64url(data)).\(b64url(sig))"
        }

        func token(cid: Int = 7, dev: String = "mac-1", exp: String = "2099-01-01T00:00:00Z", status: String = "active", v: Int = 1) -> String {
            token(payload: ["v": v, "cid": cid, "dev": dev, "email": "a@b.co", "status": status, "exp": exp, "iat": "2026-09-11T00:00:00Z", "period_end": "2098-12-01T00:00:00Z", "cancel_at_period_end": true])
        }

        private func b64url(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
    }

    // MARK: verifier

    func testPythonSignedTokenVerifies() throws {
        let e = try EntitlementVerifier.verify(Self.pythonToken, publicKeyBase64: Self.pythonPublicKey, expectedDeviceID: "FIXTURE-MAC")
        XCTAssertEqual(e.customerID, 42)
        XCTAssertEqual(e.email, "fixture@example.com")
        XCTAssertEqual(e.status, "active")
        XCTAssertFalse(e.cancelAtPeriodEnd)
        XCTAssertEqual(e.expiresAt, ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z"))
        XCTAssertEqual(e.periodEnd, ISO8601DateFormatter().date(from: "2098-12-20T00:00:00Z"))
        XCTAssertTrue(e.isValid())
    }

    func testRoundTripWithLocalKey() throws {
        let s = Signer()
        let e = try EntitlementVerifier.verify(s.token(), publicKeyBase64: s.publicKeyBase64, expectedDeviceID: "mac-1")
        XCTAssertEqual(e.customerID, 7)
        XCTAssertTrue(e.cancelAtPeriodEnd)
        XCTAssertEqual(e.token, s.token())
    }

    func testWrongKeyIsRejected() {
        let s = Signer(), other = Signer()
        XCTAssertThrowsError(try EntitlementVerifier.verify(s.token(), publicKeyBase64: other.publicKeyBase64)) { XCTAssertEqual($0 as? EntitlementError, .badSignature) }
    }

    func testTamperedPayloadIsRejected() {
        let s = Signer()
        let parts = s.token().split(separator: ".").map(String.init)
        // Re-encode a payload with a later expiry but keep the original signature.
        let forgedPayload = try! JSONSerialization.data(withJSONObject: ["v": 1, "cid": 7, "dev": "mac-1", "email": "a@b.co", "status": "active", "exp": "2199-01-01T00:00:00Z", "iat": "2026-09-11T00:00:00Z"], options: [.sortedKeys])
        let forged = "PSE1.\(forgedPayload.base64EncodedString().replacingOccurrences(of: "=", with: "")).\(parts[2])"
        XCTAssertThrowsError(try EntitlementVerifier.verify(forged, publicKeyBase64: s.publicKeyBase64)) { XCTAssertEqual($0 as? EntitlementError, .badSignature) }
    }

    func testWrongDeviceIsRejectedEvenWithGoodSignature() {
        let s = Signer()
        XCTAssertNoThrow(try EntitlementVerifier.verify(s.token(dev: "mac-1"), publicKeyBase64: s.publicKeyBase64))
        XCTAssertThrowsError(try EntitlementVerifier.verify(s.token(dev: "mac-1"), publicKeyBase64: s.publicKeyBase64, expectedDeviceID: "mac-2")) { XCTAssertEqual($0 as? EntitlementError, .wrongDevice) }
    }

    func testUnsupportedVersionAndMalformedTokens() {
        let s = Signer()
        XCTAssertThrowsError(try EntitlementVerifier.verify(s.token(v: 2), publicKeyBase64: s.publicKeyBase64)) { XCTAssertEqual($0 as? EntitlementError, .unsupportedVersion) }
        for bad in ["", "garbage", "PSE1.abc", "XYZ.a.b", "PSE1.!!!.!!!", "PSE1..", " "] {
            XCTAssertThrowsError(try EntitlementVerifier.verify(bad, publicKeyBase64: s.publicKeyBase64), bad) { XCTAssertEqual($0 as? EntitlementError, .malformed) }
        }
        XCTAssertThrowsError(try EntitlementVerifier.verify(s.token(), publicKeyBase64: "not-a-key")) { XCTAssertEqual($0 as? EntitlementError, .badPublicKey) }
    }

    func testCorruptDateInSignedPayloadIsRejected() {
        let s = Signer()
        XCTAssertThrowsError(try EntitlementVerifier.verify(s.token(exp: "yesterday"), publicKeyBase64: s.publicKeyBase64)) { XCTAssertEqual($0 as? EntitlementError, .corruptPayload) }
    }

    func testExpiredTokenVerifiesButIsNotValid() throws {
        let s = Signer()
        let e = try EntitlementVerifier.verify(s.token(exp: "2020-01-01T00:00:00Z"), publicKeyBase64: s.publicKeyBase64)
        XCTAssertFalse(e.isValid())
        XCTAssertTrue(e.isValid(at: ISO8601DateFormatter().date(from: "2019-12-31T00:00:00Z")!))
    }

    // MARK: trial clock + evaluator

    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testTrialCountsCalendarDaysIncludingTheFirst() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let start = date("2026-09-01T23:30:00Z")
        XCTAssertEqual(LicenseEvaluator.trialDaysRemaining(firstLaunch: start, trialDays: 14, now: start, calendar: cal), 14)
        XCTAssertEqual(LicenseEvaluator.trialDaysRemaining(firstLaunch: start, trialDays: 14, now: date("2026-09-02T00:10:00Z"), calendar: cal), 13)
        XCTAssertEqual(LicenseEvaluator.trialDaysRemaining(firstLaunch: start, trialDays: 14, now: date("2026-09-14T23:59:00Z"), calendar: cal), 1)
        XCTAssertEqual(LicenseEvaluator.trialDaysRemaining(firstLaunch: start, trialDays: 14, now: date("2026-09-15T00:00:00Z"), calendar: cal), 0)
        XCTAssertEqual(LicenseEvaluator.trialDaysRemaining(firstLaunch: start, trialDays: 14, now: date("2027-01-01T00:00:00Z"), calendar: cal), 0)
    }

    func testEvaluatorStates() throws {
        let s = Signer()
        let now = date("2026-09-11T12:00:00Z")
        let live = try EntitlementVerifier.verify(s.token(exp: "2026-10-01T00:00:00Z"), publicKeyBase64: s.publicKeyBase64)
        let dead = try EntitlementVerifier.verify(s.token(exp: "2026-09-01T00:00:00Z"), publicKeyBase64: s.publicKeyBase64)

        XCTAssertEqual(LicenseEvaluator.evaluate(entitlement: live, firstLaunch: date("2020-01-01T00:00:00Z"), trialDays: 14, now: now), .subscribed(live))
        XCTAssertEqual(LicenseEvaluator.evaluate(entitlement: dead, firstLaunch: nil, trialDays: 14, now: now), .subscriptionLapsed(dead))
        XCTAssertEqual(LicenseEvaluator.evaluate(entitlement: nil, firstLaunch: nil, trialDays: 14, now: now), .trial(daysRemaining: 14))
        XCTAssertEqual(LicenseEvaluator.evaluate(entitlement: nil, firstLaunch: date("2026-09-05T00:00:00Z"), trialDays: 14, now: now), .trial(daysRemaining: 8))
        XCTAssertEqual(LicenseEvaluator.evaluate(entitlement: nil, firstLaunch: date("2026-01-01T00:00:00Z"), trialDays: 14, now: now), .trialExpired)

        XCTAssertFalse(LicenseStatus.trial(daysRemaining: 1).isLocked)
        XCTAssertTrue(LicenseStatus.trialExpired.isLocked)
        XCTAssertFalse(LicenseStatus.subscribed(live).isLocked)
        XCTAssertTrue(LicenseStatus.subscriptionLapsed(dead).isLocked)
        XCTAssertTrue(LicenseStatus.subscriptionLapsed(dead).isSignedIn)
        XCTAssertFalse(LicenseStatus.trialExpired.isSignedIn)
    }

    // MARK: update feed

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.99.99"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.0.9", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("garbage", than: "0.1.0"))
    }

    func testFeedParsing() {
        let good = #"{"latest_version": "0.2.0", "download_url": "https://www.piperstitch.com/releases/PiperStitch-0.2.0.dmg", "notes": "Faster fills."}"#.data(using: .utf8)!
        let update = UpdateChecker.availableUpdate(from: good, currentVersion: "0.1.0")
        XCTAssertEqual(update?.version, "0.2.0")
        XCTAssertEqual(update?.downloadURL.lastPathComponent, "PiperStitch-0.2.0.dmg")
        XCTAssertEqual(update?.notes, "Faster fills.")
        XCTAssertNil(UpdateChecker.availableUpdate(from: good, currentVersion: "0.2.0"), "same version is not an update")
        XCTAssertNil(UpdateChecker.availableUpdate(from: good, currentVersion: "0.3.0"), "older feed is not an update")
        XCTAssertNil(UpdateChecker.availableUpdate(from: Data("{oops".utf8), currentVersion: "0.1.0"), "malformed feed means no update, never an error")
        XCTAssertNil(UpdateChecker.availableUpdate(from: Data(#"{"latest_version":"0.9.0","download_url":"not a url at all"}"#.utf8), currentVersion: "0.1.0"))
    }

    func testAPIClientDecodesServerShapes() throws {
        let sent = try JSONDecoder().decode(LicenseAPIClient.CodeRequestResult.self, from: Data(#"{"sent": true, "reason": "ok", "expires_in_minutes": 15, "subscribe_url": "https://x", "account_url": "https://y"}"#.utf8))
        XCTAssertTrue(sent.sent)
        let none = try JSONDecoder().decode(LicenseAPIClient.CodeRequestResult.self, from: Data(#"{"sent": false, "reason": "no_subscription"}"#.utf8))
        XCTAssertEqual(none.reason, "no_subscription")
        let ended = try JSONDecoder().decode(LicenseAPIClient.RefreshResult.self, from: Data(#"{"error":"subscription_ended","message":"m","entitlement":null,"status":"ended","entitled":false,"email":"a@b.co","valid_until":null,"period_end":null,"cancel_at_period_end":false,"account_url":"https://y","subscribe_url":"https://x"}"#.utf8))
        XCTAssertNil(ended.entitlement)
        XCTAssertFalse(ended.entitled)
    }
}
