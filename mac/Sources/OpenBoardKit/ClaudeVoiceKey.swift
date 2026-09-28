import Foundation

/**
 The key Claude Code listens to for push-to-talk, read from its `keybindings.json`.

 `voice-talk` has to hold *that* key. Claude Code binds `voice:pushToTalk` to Space by
 default, but a user binding — ⌃Y, which OpenBoard's own voice-chord setting installs —
 replaces it, and then a held Space only types spaces. Claude says which key it wants
 when voice is enabled ("Hold ctrl+y to record"); this reads the same answer from the
 file it comes from.

 Mirrors Claude Code's own choice (2.1.283): among `Chat` blocks, the last single-step
 chord bound to `voice:pushToTalk` wins, and a later binding of that same chord to
 another action takes it back. Anything unreadable, unbound or unholdable falls back to
 Space — Claude's default, and what `voice-talk` held before.

 Read-only, and re-read on every press: the file is small, edited by hand and by
 Settings, and a changed binding should not need a restart.
 */
public enum ClaudeVoiceKey {
    public static let action = KeybindingInstall.action
    public static let context = KeybindingInstall.context

    /// The key to hold, from the live file.
    public static func current(url: URL? = nil) -> Shortcut {
        resolve(data: try? Data(contentsOf: url ?? KeybindingInstall.url()))
    }

    /// The key to hold, from the file's bytes. Space when there is no usable binding.
    public static func resolve(data: Data?) -> Shortcut {
        guard let data,
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let chord = chord(in: document),
              let shortcut = shortcut(chord: chord)
        else { return .space }
        return shortcut
    }

    /// The chord bound to push-to-talk in `Chat`, as written, or `nil`.
    public static func chord(in document: [String: Any]) -> String? {
        let blocks = (document["bindings"] as? [[String: Any]] ?? [])
            .filter { $0["context"] as? String == context }
            .compactMap { $0["bindings"] as? [String: Any] }
        var bound: String?
        for block in blocks {
            // A JSON object has no order once parsed; sorted keeps the pick stable
            // when one block binds two chords to push-to-talk.
            for chord in block.keys.sorted() {
                if block[chord] as? String == action {
                    bound = chord
                } else if let current = bound, normalized(current) == normalized(chord) {
                    bound = nil
                }
            }
        }
        return bound
    }

    /// A single-step chord ("ctrl+y", "space") as a held `Shortcut`, or `nil` when it
    /// cannot be held: a multi-step chord, an unknown key, a modifier alone.
    public static func shortcut(chord: String) -> Shortcut? {
        let text = normalized(chord)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let keyName = parts.popLast(), let key = keys[keyName] else { return nil }
        var modifiers: Set<Shortcut.Modifier> = []
        for part in parts {
            guard let modifier = modifierNames[part] else { return nil }
            modifiers.insert(modifier)
        }
        return Shortcut(keyCode: key.code, modifiers: modifiers, key: key.label, mode: .hold)
    }

    private static func normalized(_ chord: String) -> String {
        chord.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Claude Code's names. `meta` is Option: that is what a terminal reports for it.
    private static let modifierNames: [String: Shortcut.Modifier] = [
        "ctrl": .control, "control": .control,
        "alt": .option, "opt": .option, "option": .option, "meta": .option,
        "shift": .shift,
        "cmd": .command, "command": .command, "super": .command,
    ]

    /// ANSI virtual key codes for the keys a chord can name.
    private static let keys: [String: (code: Int, label: String)] = {
        var table: [String: (code: Int, label: String)] = [
            "space": (49, "Space"), "enter": (36, "Return"), "return": (36, "Return"),
            "tab": (48, "Tab"), "escape": (53, "Esc"), "esc": (53, "Esc"),
            "backspace": (51, "Delete"), "delete": (51, "Delete"),
            "up": (126, "↑"), "down": (125, "↓"), "left": (123, "←"), "right": (124, "→"),
        ]
        let characters: [(String, Int)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
            ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
            ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22),
            ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28), ("0", 29),
            ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37),
            ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44),
            ("n", 45), ("m", 46), (".", 47), ("`", 50),
        ]
        for (name, code) in characters { table[name] = (code, name.uppercased()) }
        return table
    }()
}
