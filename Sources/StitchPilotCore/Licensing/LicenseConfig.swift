import Foundation

/// Everything the licensing client needs to know about the outside world,
/// in one place. These values are baked into each build; the two URLs
/// marked "permanent" can never change for copies already installed.
public struct LicenseConfig: Sendable {
    /// The License Admin service (license-admin/ in this repo) — the only
    /// server the app ever talks to about subscriptions.
    public var apiBaseURL: URL
    /// The Ed25519 public key whose private half lives ONLY in License
    /// Admin's environment. Must equal `_PUBLIC_KEY_B64` in that service's
    /// app/entitlement.py; generated once and kept in
    /// ~/Documents/PiperStitch-Licensing/ — see LICENSING.md.
    public var publicKeyBase64: String
    /// Days the app runs without any account after first launch on a Mac.
    public var trialDays: Int
    /// How often a signed-in copy silently refreshes its entitlement.
    public var refreshInterval: TimeInterval
    /// Where the "Subscribe" button sends people.
    public var pricingURL: URL
    /// Where the "Manage subscription" button sends people (the service's
    /// self-service page; the app also gets a direct Stripe portal link
    /// from the API when signed in).
    public var accountURL: URL
    /// Permanent: the update feed every installed copy polls.
    public var updateFeedURL: URL?

    public init(apiBaseURL: URL, publicKeyBase64: String, trialDays: Int, refreshInterval: TimeInterval, pricingURL: URL, accountURL: URL, updateFeedURL: URL?) {
        self.apiBaseURL = apiBaseURL
        self.publicKeyBase64 = publicKeyBase64
        self.trialDays = trialDays
        self.refreshInterval = refreshInterval
        self.pricingURL = pricingURL
        self.accountURL = accountURL
        self.updateFeedURL = updateFeedURL
    }

    /// The shipping configuration. `updateFeedURL` is nil in development
    /// builds so a dev copy never polls a URL nobody hosts yet — set it
    /// when the site is live (LICENSING.md → "Shipping an update").
    public static let production = LicenseConfig(
        apiBaseURL: URL(string: "https://admin.piperstitch.com")!,
        publicKeyBase64: "OLvbWOM6exl9IL11JHluZkzrTVsQQZs7kB3eHpJJJDY=",
        trialDays: 14,
        refreshInterval: 12 * 60 * 60,
        pricingURL: URL(string: "https://www.piperstitch.com/pricing.html")!,
        accountURL: URL(string: "https://admin.piperstitch.com/account")!,
        updateFeedURL: nil
    )
}
