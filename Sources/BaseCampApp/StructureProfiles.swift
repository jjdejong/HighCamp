import BaseCampCore
import CryptoKit
import Foundation

/// The profile names to ask BRouter for: a copy of each profile that also reports tunnels and bridges
/// (`BRouterProfileText.reportingStructures`), uploaded once to each server and kept there, or the profile itself
/// when that cannot be done. BRouter keeps uploaded profiles in its `customprofiles` folder (HighCamp's own server:
/// in HighCamp's BRouter folder).
@MainActor
final class StructureProfiles {
    static let shared = StructureProfiles()

    private static let key = "routing.structureProfiles"
    /// Uploaded copies, by server, profile and the copy's text.
    private var ids: [String: String]

    private init() {
        ids = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    /// The name to route with for `profile` on `server`. `folder` is the BRouter folder whose profiles the server
    /// reads, if it is on this Mac; otherwise the profile is fetched from the server.
    func name(for profile: String, server: URL, folder: URL?) async -> String {
        guard let text = await Self.text(of: profile, server: server, folder: folder) else { return profile }
        let copy = BRouterProfileText.reportingStructures(text)
        let key = Self.key(server: server, profile: profile, text: copy)
        if let id = ids[key] {
            return id
        }
        guard let id = await Self.upload(copy, to: server) else { return profile }
        ids[key] = id
        UserDefaults.standard.set(ids, forKey: Self.key)
        return id
    }

    /// Forgets the copies uploaded to `server`, as when one turned out to be gone; the next request uploads again.
    func forget(server: URL) {
        ids = ids.filter { !$0.key.hasPrefix(server.absoluteString + "|") }
        UserDefaults.standard.set(ids, forKey: Self.key)
    }

    private static func key(server: URL, profile: String, text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(server.absoluteString)|\(profile)|\(digest)"
    }

    private static func text(of profile: String, server: URL, folder: URL?) async -> String? {
        if let folder, let text = try? String(contentsOf: folder.appendingPathComponent("profiles2/\(profile).brf"), encoding: .utf8) {
            return text
        }
        guard let (data, response) = try? await URLSession.shared.data(from: server.appendingPathComponent("brouter/profiles2/\(profile).brf")),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func upload(_ text: String, to server: URL) async -> String? {
        var request = URLRequest(url: server.appendingPathComponent("brouter/profile"))
        request.httpMethod = "POST"
        request.httpBody = Data(text.utf8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["profileid"] as? String
    }
}
