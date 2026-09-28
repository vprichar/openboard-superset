import Foundation

/**
 What may be written into one agent's terminal from the pad (F7), and when.

 Two intents, each gated on the binding's last lifecycle event and on a snapshot having
 been taken first (Plan §6: "snapshot before anything that writes to a terminal"):

 - **interrupt** only an agent that is working (`Start`): ⎋, then clear its status,
   because agents fire no hook on Esc and the key would otherwise stay "working".
 - **send** only to an agent that has stopped or is asking for permission, stripped of
   control characters (all but `\n` and `\t`), then cut to `maxSendBytes` on a
   character boundary, and submitted.

 `requireStopForSend` is deliberately not read. It is a safety rule shown locked in the
 UI, and a hand-edited config that sets it to false must not unlock typing into a
 working agent.
 */
public enum TargetedControl {
    public enum Intent: Equatable, Sendable {
        case interrupt
        case send(text: String)
    }

    public enum Plan: Equatable, Sendable {
        case refuse(reason: String)
        case calls([SupersetCall])
    }

    public static func plan(
        _ intent: Intent,
        binding: AgentBinding?,
        snapshot: String?,
        limits: Preferences.Targeted
    ) -> Plan {
        guard let binding else { return .refuse(reason: "no agent bound to that terminal") }
        guard snapshot != nil else { return .refuse(reason: "no snapshot taken first") }
        let terminal = binding.terminalID, workspace = binding.workspaceID

        switch intent {
        case .interrupt:
            guard binding.lastEventType == .start else {
                return .refuse(reason: "agent is not working")
            }
            return .calls([
                .writeInput(terminalID: terminal, workspaceID: workspace, data: .escape),
                .clearStatuses(workspaceID: workspace, terminalID: terminal),
            ])

        case .send(let text):
            guard binding.lastEventType == .stop || binding.lastEventType == .permissionRequest else {
                return .refuse(reason: "agent has not stopped")
            }
            let cut = truncate(sanitize(text), toUTF8Bytes: limits.maxSendBytes)
            guard !cut.isEmpty else { return .refuse(reason: "nothing to send") }
            return .calls([.send(terminalID: terminal, workspaceID: workspace, text: cut, submit: true)])
        }
    }

    /// The text without control characters, except `\n` and `\t`.
    ///
    /// `send` submits on its own, so a `\r` inside the text would submit early, and ESC,
    /// NUL or any other C0/C1 control (DEL included) would drive the TUI instead of
    /// typing into it. Filtered by scalar, not by character: Swift treats `\r\n` as one
    /// character, and only its `\n` may survive.
    static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let control = v < 0x20 || (0x7F...0x9F).contains(v)
            if !control || scalar == "\n" || scalar == "\t" { scalars.append(scalar) }
        }
        return String(scalars)
    }

    /// The longest prefix of whole characters (grapheme clusters) that fits in `limit`
    /// UTF-8 bytes. Cutting by character, not by scalar, keeps an emoji or an accented
    /// letter written as two scalars in one piece.
    static func truncate(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard limit > 0 else { return "" }
        if text.utf8.count <= limit { return text }
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            if bytes + size > limit { break }
            bytes += size
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}
