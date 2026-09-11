import Foundation

/// Reads the update feed the website hosts (updates/piperstitch-mac.json)
/// and says whether a newer version than the running one exists. Same
/// model as Amerus: NOT a silent auto-installer — the app only shows a
/// notice with a download link, and the person installs it themselves,
/// because an unsigned build can't safely swap itself in place.
///
/// Malformed JSON, a network failure, or a version that isn't strictly
/// newer all mean "no update" — quietly. A stray comma in the feed must
/// never make every installed copy show an error.
public struct UpdateFeed: Decodable, Equatable, Sendable {
    public let latest_version: String
    public let download_url: String
    public let notes: String?
}

public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let downloadURL: URL
    public let notes: String
}

public enum UpdateChecker {
    /// Compares dotted numeric versions ("0.2.0" vs "0.10.1") component by
    /// component. Non-numeric components compare as 0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    public static func availableUpdate(from data: Data, currentVersion: String) -> AvailableUpdate? {
        guard let feed = try? JSONDecoder().decode(UpdateFeed.self, from: data),
              isNewer(feed.latest_version, than: currentVersion),
              let url = URL(string: feed.download_url) else { return nil }
        return AvailableUpdate(version: feed.latest_version, downloadURL: url, notes: feed.notes ?? "")
    }

    public static func check(feedURL: URL, currentVersion: String, session: URLSession = .shared) async -> AvailableUpdate? {
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        guard let (data, _) = try? await session.data(for: request) else { return nil }
        return availableUpdate(from: data, currentVersion: currentVersion)
    }
}
