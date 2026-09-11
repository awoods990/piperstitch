import Foundation
import AppKit
import SwiftUI
import StitchPilotCore

/// Owns the subscription state of this Mac: the free-trial clock, the
/// device token and signed entitlement once someone signs in, the silent
/// background refresh, and the update-feed check. Everything that decides
/// "is the editor unlocked right now" flows through `status`.
///
/// Persistence is deliberately a plain file (0600) in Application Support
/// mirrored to UserDefaults, not the Keychain: PiperStitch ships unsigned,
/// and the Keychain prompts "PiperStitch wants to use your confidential
/// information" every time an unsigned binary changes — i.e. on every
/// update. The file gives the same practical protection for an unsigned
/// app (see LICENSING.md → "The honest limitation") without that. The
/// trial start is written to BOTH places and the earlier one wins, so
/// deleting one alone doesn't reset the clock.
@MainActor
final class LicenseManager: ObservableObject {
    @Published private(set) var status: LicenseStatus
    @Published private(set) var accountEmail: String?
    /// The last background-refresh failure, for the account panel — never
    /// shown as an alert, because a Mac being offline is not an error.
    @Published private(set) var lastRefreshProblem: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published var isShowingAccount = false

    let config: LicenseConfig
    private let api: LicenseAPIClient
    private var record: LicenseRecord
    private var refreshLoop: Task<Void, Never>?

    init(config: LicenseConfig = .current) {
        self.config = config
        self.api = LicenseAPIClient(baseURL: config.apiBaseURL)
        var loaded = LicenseRecord.load()
        if loaded.firstLaunchAt == nil { loaded.firstLaunchAt = Date() }
        if loaded.deviceID == nil { loaded.deviceID = UUID().uuidString }
        self.record = loaded
        self.status = .trial(daysRemaining: config.trialDays)
        loaded.save()
        self.accountEmail = loaded.accountEmail
        reevaluate()
    }

    var deviceID: String { record.deviceID ?? "" }
    var isSignedIn: Bool { record.deviceToken != nil }
    var isLocked: Bool { status.isLocked }

    /// Call once from the root view. Starts the refresh loop and the
    /// update check; safe to call again (it's idempotent).
    func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshIfNeeded()
                await self.checkForUpdate()
                try? await Task.sleep(nanoseconds: UInt64(self.config.refreshInterval * 1_000_000_000))
            }
        }
    }

    // MARK: - Evaluation

    private func reevaluate(now: Date = Date()) {
        var entitlement: Entitlement?
        if let token = record.entitlementToken, let id = record.deviceID {
            // A stored token that no longer verifies (tampered, or the key
            // rotated) is treated as absent — back to the trial clock,
            // which is almost certainly expired, so the editor locks.
            entitlement = try? EntitlementVerifier.verify(token, publicKeyBase64: config.publicKeyBase64, expectedDeviceID: id)
        }
        if entitlement == nil, record.deviceToken != nil {
            // Signed in but holding no valid token: lapsed, not "trial".
            // Synthesize the lapsed state from whatever we last knew.
            if let token = record.entitlementToken, let stale = try? EntitlementVerifier.verify(token, publicKeyBase64: config.publicKeyBase64) {
                status = .subscriptionLapsed(stale)
                return
            }
            status = .trialExpired
            return
        }
        status = LicenseEvaluator.evaluate(entitlement: entitlement, firstLaunch: record.firstLaunchAt, trialDays: config.trialDays, now: now)
    }

    // MARK: - Sign-in flow

    func requestCode(email: String) async throws -> LicenseAPIClient.CodeRequestResult {
        try await api.requestCode(email: email, deviceID: deviceID, deviceName: Host.current().localizedName ?? "Mac")
    }

    func verify(email: String, code: String) async throws {
        let result = try await api.verifyCode(email: email, code: code, deviceID: deviceID, deviceName: Host.current().localizedName ?? "Mac")
        // Verify what the server handed us before believing it.
        _ = try EntitlementVerifier.verify(result.entitlement, publicKeyBase64: config.publicKeyBase64, expectedDeviceID: deviceID)
        record.deviceToken = result.device_token
        record.entitlementToken = result.entitlement
        record.accountEmail = result.email
        record.save()
        accountEmail = result.email
        lastRefreshProblem = nil
        lastRefreshedAt = Date()
        reevaluate()
    }

    func signOut() async {
        if let token = record.deviceToken {
            try? await api.signOut(deviceToken: token)  // best effort; the server also drops revoked tokens on its own
        }
        record.deviceToken = nil
        record.entitlementToken = nil
        record.accountEmail = nil
        record.save()
        accountEmail = nil
        reevaluate()
    }

    /// Asks License Admin for a fresh entitlement. Quiet on failure: an
    /// offline Mac keeps using the entitlement it has until it expires.
    func refreshNow() async {
        guard let token = record.deviceToken else { reevaluate(); return }
        do {
            let result = try await api.refreshEntitlement(deviceToken: token)
            if let fresh = result.entitlement {
                _ = try EntitlementVerifier.verify(fresh, publicKeyBase64: config.publicKeyBase64, expectedDeviceID: deviceID)
                record.entitlementToken = fresh
            }
            // entitlement == nil: the subscription ended. Keep the old
            // token; it expires on its own and the status turns lapsed.
            if let email = result.email { record.accountEmail = email; accountEmail = email }
            record.save()
            lastRefreshProblem = nil
            lastRefreshedAt = Date()
        } catch let LicenseAPIClient.LicenseAPIError.server(code, message) where code == "device_revoked" {
            // Signed out from the account page or by the admin: honour it.
            record.deviceToken = nil
            record.entitlementToken = nil
            record.save()
            lastRefreshProblem = message
        } catch {
            lastRefreshProblem = error.localizedDescription
        }
        reevaluate()
    }

    private func refreshIfNeeded() async {
        guard record.deviceToken != nil else { reevaluate(); return }
        await refreshNow()
    }

    // MARK: - Links out

    func openPricing() { NSWorkspace.shared.open(config.pricingURL) }

    func openAccountPage() async {
        if let token = record.deviceToken, let url = try? await api.billingPortalURL(deviceToken: token) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(config.accountURL)
        }
    }

    // MARK: - Updates

    func checkForUpdate() async {
        guard let feed = config.updateFeedURL else { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        availableUpdate = await UpdateChecker.check(feedURL: feed, currentVersion: current)
    }
}

// MARK: - Persistence

/// What survives between launches. Two homes — a 0600 JSON file in
/// Application Support and UserDefaults — reconciled on load so that
/// deleting either one alone can't reset the trial.
struct LicenseRecord: Codable {
    var firstLaunchAt: Date?
    var deviceID: String?
    var deviceToken: String?
    var entitlementToken: String?
    var accountEmail: String?

    private static let defaultsKey = "com.piperstitch.license"
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PiperStitch", isDirectory: true).appendingPathComponent("license.json")
    }

    static func load() -> LicenseRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var fromFile: LicenseRecord?
        if let data = try? Data(contentsOf: fileURL) { fromFile = try? decoder.decode(LicenseRecord.self, from: data) }
        var fromDefaults: LicenseRecord?
        if let data = UserDefaults.standard.data(forKey: defaultsKey) { fromDefaults = try? decoder.decode(LicenseRecord.self, from: data) }

        var merged = fromFile ?? fromDefaults ?? LicenseRecord()
        if let a = fromFile?.firstLaunchAt, let b = fromDefaults?.firstLaunchAt {
            merged.firstLaunchAt = min(a, b)
        } else {
            merged.firstLaunchAt = fromFile?.firstLaunchAt ?? fromDefaults?.firstLaunchAt
        }
        merged.deviceID = fromFile?.deviceID ?? fromDefaults?.deviceID
        merged.deviceToken = fromFile?.deviceToken ?? fromDefaults?.deviceToken
        merged.entitlementToken = fromFile?.entitlementToken ?? fromDefaults?.entitlementToken
        merged.accountEmail = fromFile?.accountEmail ?? fromDefaults?.accountEmail
        return merged
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
