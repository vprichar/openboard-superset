import Foundation

/**
 Finds and reads `~/.superset/host/<org>/manifest.json`.

 Superset writes one manifest per organization it hosts, and rewrites it on every
 start: the port changes each time. So this is called per connection, not cached —
 and the result lives only in memory (Plan §4). Nothing here writes, and no error
 carries the file's contents, because the file holds the bearer token.
 */
public enum SupersetManifestLocator {
    public enum Failure: Error, Equatable, Sendable {
        /// No manifest for the org asked for, or no org has one.
        case missing
        /// `orgID` was nil and more than one org has a manifest: guessing would talk to
        /// the wrong account.
        case ambiguous
        /// There is a file, but no usable endpoint, org or token in it.
        case malformed
    }

    public static let fileName = "manifest.json"

    /// `root` is `~/.superset/host`. With `orgID` nil, the one org folder that holds a
    /// manifest — folders without one do not count.
    public static func resolve(root: URL, orgID: String?) throws -> SupersetManifest {
        let fm = FileManager.default
        if let orgID {
            let file = root.appendingPathComponent(orgID).appendingPathComponent(fileName)
            guard let data = fm.contents(atPath: file.path) else { throw Failure.missing }
            return try parse(data, folder: orgID)
        }
        let folders = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { fm.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent(fileName).path) }
            .sorted()
        guard let only = folders.first else { throw Failure.missing }
        guard folders.count == 1 else { throw Failure.ambiguous }
        guard let data = fm.contents(atPath: root.appendingPathComponent(only).appendingPathComponent(fileName).path)
        else { throw Failure.missing }
        return try parse(data, folder: only)
    }

    /// The manifest's keys are `endpoint`, `authToken`, `organizationId`, `pid` and
    /// `startedAt`; only the first three matter here. A missing `organizationId` falls
    /// back to the folder name, which Superset names after the org.
    public static func parse(_ data: Data, folder: String) throws -> SupersetManifest {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpointText = object["endpoint"] as? String,
              let endpoint = URL(string: endpointText), endpoint.scheme != nil, endpoint.host != nil,
              let token = object["authToken"] as? String, !token.isEmpty
        else { throw Failure.malformed }
        let org = (object["organizationId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder
        // wire: Log.registerSecret(SecretToken(token)) — once K1's redactor lands, the
        // caller registers the token here so no log line can carry it.
        return SupersetManifest(endpoint: endpoint, organizationID: org, token: SecretToken(token))
    }
}
