import SwiftUI
import StitchPilotCore

/// The account sheet: sign in with an email + six-digit code, see the
/// subscription's state, open Stripe's billing page, sign this Mac out.
/// One view for every licensing state, so the same sheet serves the
/// trial's "Subscribe / Sign in" prompt, the locked paywall, and a
/// subscriber's account panel.
struct AccountSheet: View {
    @EnvironmentObject var license: LicenseManager
    @Environment(\.dismiss) private var dismiss

    private enum Step { case idle, codeSent(email: String), noSubscription(email: String, reason: String) }

    @State private var email = ""
    @State private var code = ""
    @State private var step: Step = .idle
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if license.isSignedIn {
                accountPanel
            } else {
                signInPanel
            }
            if let errorText {
                Text(errorText).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                if !license.isLocked {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                } else {
                    Text("PiperStitch stays locked until you sign in with a subscription.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(22)
        .frame(width: 440, height: 420)
        .onAppear { email = license.accountEmail ?? "" }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let url = Bundle.module.url(forResource: "PiperStitchIcon", withExtension: "png"), let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("PiperStitch Subscription").font(.title3.weight(.semibold))
                Text(statusLine).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var statusLine: String {
        switch license.status {
        case .trial(let days): return "Free trial — \(days) day\(days == 1 ? "" : "s") left. No account needed yet."
        case .trialExpired: return "Your free trial has ended."
        case .subscribed(let e): return subscribedLine(e)
        case .subscriptionLapsed: return "Your subscription has ended."
        }
    }

    private func subscribedLine(_ e: Entitlement) -> String {
        let f = DateFormatter(); f.dateStyle = .medium
        switch e.status {
        case "comp": return "Complimentary access" + (e.periodEnd.map { " through \(f.string(from: $0))" } ?? "")
        case "past_due": return "Payment issue — update your card to keep PiperStitch"
        default:
            guard let end = e.periodEnd else { return "Subscribed" }
            return e.cancelAtPeriodEnd ? "Subscribed — ends \(f.string(from: end))" : "Subscribed — renews \(f.string(from: end))"
        }
    }

    // MARK: signed-in

    private var accountPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Signed in as", value: license.accountEmail ?? "—")
            if let at = license.lastRefreshedAt {
                LabeledContent("Last checked", value: at.formatted(date: .abbreviated, time: .shortened))
            }
            if let problem = license.lastRefreshProblem {
                Text(problem).font(.footnote).foregroundStyle(.secondary)
            }
            if case .subscriptionLapsed = license.status {
                Text("Resubscribe with the same email and this Mac unlocks the next time it checks — or use Check Now below.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Manage Billing…") { Task { await license.openAccountPage() } }
                    .help("Update your card, download invoices, or cancel — on Stripe's secure page.")
                Button("Check Now") { Task { isWorking = true; await license.refreshNow(); isWorking = false } }.disabled(isWorking)
                if case .subscriptionLapsed = license.status {
                    Button("Subscribe…") { license.openPricing() }
                }
                Spacer()
                Button("Sign Out This Mac", role: .destructive) { Task { await license.signOut(); step = .idle } }
            }
            if isWorking { ProgressView().controlSize(.small) }
        }
    }

    // MARK: sign-in

    @ViewBuilder
    private var signInPanel: some View {
        switch step {
        case .idle:
            VStack(alignment: .leading, spacing: 10) {
                Text(license.isLocked
                     ? "Subscribe for $19 a month at piperstitch.com, then sign in here with the same email. There's no license key — a six-digit code arrives by email."
                     : "Already subscribed? Sign in with the email you subscribed with. Otherwise, keep enjoying the trial.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                TextField("Email address", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await sendCode() } }
                HStack {
                    Button("Subscribe at piperstitch.com…") { license.openPricing() }
                    Spacer()
                    Button("Email Me a Code") { Task { await sendCode() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || !email.contains("@"))
                }
                if isWorking { ProgressView().controlSize(.small) }
            }
        case .codeSent(let sentTo):
            VStack(alignment: .leading, spacing: 10) {
                Text("We emailed a six-digit code to \(sentTo). Enter it below — it works for 15 minutes.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                TextField("6-digit code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title2, design: .monospaced))
                    .onSubmit { Task { await verify(sentTo) } }
                HStack {
                    Button("Use a different email") { step = .idle; code = ""; errorText = nil }
                    Button("Send again") { Task { await sendCode() } }.disabled(isWorking)
                    Spacer()
                    Button("Sign In") { Task { await verify(sentTo) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || code.filter(\.isNumber).count != 6)
                }
                if isWorking { ProgressView().controlSize(.small) }
            }
        case .noSubscription(let addr, let reason):
            VStack(alignment: .leading, spacing: 10) {
                Text(reason == "subscription_ended"
                     ? "The subscription for \(addr) has ended. Resubscribe with the same email and sign in again."
                     : "There's no PiperStitch subscription for \(addr) yet. Subscribing takes a minute, then sign in here with the same email.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try another email") { step = .idle; errorText = nil }
                    Spacer()
                    Button("Subscribe at piperstitch.com…") { license.openPricing() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func sendCode() async {
        errorText = nil
        isWorking = true
        defer { isWorking = false }
        let addr = email.trimmingCharacters(in: .whitespaces).lowercased()
        do {
            let result = try await license.requestCode(email: addr)
            if result.sent {
                code = ""
                step = .codeSent(email: addr)
            } else {
                step = .noSubscription(email: addr, reason: result.reason)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func verify(_ addr: String) async {
        errorText = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await license.verify(email: addr, code: code.filter(\.isNumber))
            step = .idle
            code = ""
            if !license.isLocked { dismiss() }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Covers the editor when the trial is over or the subscription lapsed.
/// Nothing underneath is destroyed — a saved project is still on disk —
/// but no editing or exporting happens until someone signs in.
struct LockedOverlay: View {
    @EnvironmentObject var license: LicenseManager

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                if let url = Bundle.module.url(forResource: "PiperStitchIcon", withExtension: "png"), let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 72, height: 72)
                }
                Text(title).font(.title2.weight(.semibold))
                Text(body_).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Subscribe — $19/month") { license.openPricing() }.buttonStyle(.borderedProminent).controlSize(.large)
                    Button(license.isSignedIn ? "Account…" : "Sign In…") { license.isShowingAccount = true }.controlSize(.large)
                }
                Text("Files you've already exported keep working on your machine.").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(36)
        }
    }

    private var title: String {
        switch license.status {
        case .subscriptionLapsed: return "Your PiperStitch subscription has ended"
        default: return "Your free trial has ended"
        }
    }

    private var body_: String {
        switch license.status {
        case .subscriptionLapsed(let e):
            return e.cancelAtPeriodEnd
                ? "Thanks for stitching with us. Resubscribe any time with \(e.email) and everything picks up where it left off."
                : "We couldn't confirm your renewal for \(e.email). If your card was declined, update it from Manage Billing and this Mac will unlock on its next check."
        default:
            return "Hope the \(license.config.trialDays) days were useful. PiperStitch is $19 a month, renews automatically, and can be cancelled any time. Subscribe on the website, then sign in here with the same email."
        }
    }
}

/// The compact status-bar item: trial countdown, or the account email.
struct LicenseStatusPill: View {
    @EnvironmentObject var license: LicenseManager

    var body: some View {
        Button { license.isShowingAccount = true } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.callout)
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help("Subscription and account")
    }

    private var label: String {
        switch license.status {
        case .trial(let d): return "Trial: \(d) day\(d == 1 ? "" : "s") left"
        case .trialExpired: return "Trial ended"
        case .subscribed(let e): return e.status == "past_due" ? "Payment issue" : (license.accountEmail ?? "Subscribed")
        case .subscriptionLapsed: return "Subscription ended"
        }
    }

    private var icon: String {
        switch license.status {
        case .trial: return "clock"
        case .subscribed(let e): return e.status == "past_due" ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
        default: return "lock.fill"
        }
    }

    private var color: Color {
        switch license.status {
        case .trial(let d): return d <= 3 ? .orange : .secondary
        case .subscribed(let e): return e.status == "past_due" ? .orange : .secondary
        default: return .red
        }
    }
}
