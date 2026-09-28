import Foundation

/**
 A log file, because a menu bar app has nowhere else to speak.

 There is no terminal attached, no window to print into, and `os_log` needs Console
 open and a predicate to find anything. Meanwhile every interesting failure here is
 environmental — a permission not granted, a device that vanished, a write refused —
 and the app's only way to report is a color in a menu bar, which cannot say *why*.

 The Node version had exactly this file and it is what made every problem in this
 project tractable. Rebuilding it in Swift was overdue: several rounds of diagnosis
 were spent inferring state from the outside because the app could not simply say
 what it saw.

 Bounded, since it runs for as long as the user is logged in.
 */
public enum Log {
    private static let queue = DispatchQueue(label: "com.openboard.log")
    private static let maxBytes = 512 * 1024

    /// `~/Library/Logs/OpenBoard/app.log` — where Console.app looks, and where "send me
    /// your logs" already points.
    public static var url: URL {
        AppPaths.logs().appendingPathComponent("app.log")
    }

    private static let secretsLock = NSLock()
    nonisolated(unsafe) private static var secrets: [String] = []

    /// Keep this token out of every line written from now on — see `LogRedactor`.
    /// Registering the same token twice is harmless.
    public static func registerSecret(_ token: SecretToken) {
        token.withRaw { raw in
            guard !raw.isEmpty else { return }
            secretsLock.lock()
            defer { secretsLock.unlock() }
            if !secrets.contains(raw) { secrets.append(raw) }
        }
    }

    /// A message as it would be written: scrubbed of registered secrets, bearer
    /// credentials and token parameters. `write` always goes through this.
    public static func redact(_ message: String) -> String {
        secretsLock.lock()
        let known = secrets
        secretsLock.unlock()
        return LogRedactor.redact(message, secrets: known)
    }

    public static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(redact(message))\n"
        queue.async {
            let url = Self.url
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > maxBytes {
                try? Data().write(to: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Log a transition only when it actually changes, so a 10s poll does not fill
    /// the file with "still fine".
    /**
     Log only when the value differs from last time, and hand back what to remember.

     Returns the new value rather than taking `inout`. The `inout` form took a dynamic
     exclusive access to a *class property*, and every caller here is inside an async
     `@MainActor` method — which is precisely the shape Swift's exclusivity enforcement
     traps on. It crashed the app on launch with `swift_beginAccess`, from the resident
     loop, every few seconds.

     Returning the value moves the write to the call site, where it is an ordinary
     assignment with no access spanning anything.
     */
    public static func changed<T: Equatable>(
        _ label: String,
        last previous: T?,
        to current: T
    ) -> T? {
        guard previous != current else { return previous }
        write("\(label): \(current)")
        return current
    }
}

/**
 What keeps the host-service token out of `app.log`.

 The log is what gets attached to "send me your logs", and the token in Superset's
 `manifest.json` opens every workspace on the machine. So every line is scrubbed on
 its way in, whoever wrote it:

 - every registered secret, wherever in the line it sits
 - `Bearer <credential>` (the `Authorization` header), any case
 - a URL with a `token=` parameter is cut down to its path — the port changes on
   every Superset launch and says nothing, the token says too much
 - any remaining `token=` parameter

 Cheap by design, because every `Log.write` pays for it: one `replacingOccurrences` per
 secret, and the patterns only run when a cheap substring check says they could match.
 */
public enum LogRedactor {
    public static let marker = "«redacted»"

    private static let bearer = try! NSRegularExpression(
        pattern: #"(?i)\b(bearer)\s+[^\s"',;]+"#
    )
    private static let urlWithToken = try! NSRegularExpression(
        pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^/\s?#]+(/[^\s?#]*)?\?[^\s#]*\btoken=[^\s#]*(#\S*)?"#
    )
    private static let tokenParameter = try! NSRegularExpression(
        pattern: #"(?i)\b(token=)[^\s&#"']+"#
    )

    public static func redact(_ line: String, secrets: [String]) -> String {
        var result = line
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: marker)
        }
        let lowered = result.lowercased()
        if lowered.contains("bearer") {
            result = replace(bearer, in: result, with: "$1 \(marker)")
        }
        if lowered.contains("token=") {
            result = replace(urlWithToken, in: result, with: "$1")
            result = replace(tokenParameter, in: result, with: "$1\(marker)")
        }
        return result
    }

    private static func replace(
        _ pattern: NSRegularExpression, in text: String, with template: String
    ) -> String {
        pattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
        )
    }
}
