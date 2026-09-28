import Foundation

/**
 Question mode: while a session the pad is showing is waiting on a prompt, the stick
 answers it.

 Claude Code's dialogs — AskUserQuestion's options, a permission prompt's choices —
 are walked with the bare arrows: ↑↓ between options, ←→ between the questions of a
 multi-question prompt. With Superset in front its profile makes the stick send ⌥⌘
 arrows, which switch tabs and workspaces instead, so pushing the stick to pick an
 option walked away from the prompt. While a visible session is `awaiting`, the stick
 sends plain arrows whatever the app in front; when it leaves `awaiting` — answered,
 cancelled, back to `working` — the profile is back.

 The rest of the pad follows: FAST and CODEX do nothing, the dial turns through the
 options one per detent (a plan keeps scrolling), clicks Space and holds Tab, and APPR
 and REJ answer the session that turned the mode on. The mode ends only when the hook
 says that session moved on — `next`.

 Only sessions on the keys of the view in front count, and never the overflow key:
 that one is lent from another workspace, whose prompt is not in the terminal the
 arrows would reach. Pure — the entries and the view are arguments.
 */
public enum QuestionMode {
    /// The session that turned question mode on, for the log.
    public struct Trigger: Equatable, Sendable {
        /// The pad key showing it.
        public var key: Int
        public var sessionID: String
        public var workspaceID: String?
        /// Which tool is asking, when the hook said — AskUserQuestion, Bash…
        public var pendingTool: String?

        public init(key: Int, sessionID: String, workspaceID: String?, pendingTool: String?) {
            self.key = key
            self.sessionID = sessionID
            self.workspaceID = workspaceID
            self.pendingTool = pendingTool
        }
    }

    /**
     The session that turns question mode on, if any: the lowest pad key showing an
     `awaiting` session, overflow key excluded.

     - Parameter padKeys: `PadView.keys` — pad key → session id.
     - Parameter overflowKey: `PadView.overflowKey`.
     */
    public static func trigger(
        entries: [SessionRegistry.Entry], padKeys: [Int: String], overflowKey: Int? = nil
    ) -> Trigger? {
        for key in padKeys.keys.sorted() where key != overflowKey {
            // A prompt restored from disk and not confirmed by a live event may have been
            // answered since: arrows sent to it would land in the chat prompt instead —
            // ↑ recalls history, ← opens the agents view.
            guard let id = padKeys[key],
                  let entry = entries.first(where: { $0.sessionID == id }),
                  entry.state == .awaiting, !entry.isUnconfirmed
            else { continue }
            return Trigger(
                key: key, sessionID: id,
                workspaceID: entry.supersetWorkspaceID, pendingTool: entry.pendingTool
            )
        }
        return nil
    }

    /**
     Question mode after the board changed: the session it is on keeps it while that
     session is still waiting on a visible key; otherwise `trigger` picks again.

     Only the hook's state is an input. APPR and REJ are not: ⏎ on the first question
     of a multi-question prompt moves it to the next one and no hook arrives, so the
     mode must hold until the session is `working`, `done` or `ended` — or gone. And a
     second session starting to wait does not steal it: APPR must answer the prompt the
     arrows were moving through.
     */
    public static func next(
        current: Trigger?, entries: [SessionRegistry.Entry], padKeys: [Int: String], overflowKey: Int? = nil
    ) -> Trigger? {
        if let current,
           padKeys.contains(where: { $0.key != overflowKey && $0.value == current.sessionID }),
           let entry = entries.first(where: { $0.sessionID == current.sessionID }),
           entry.state == .awaiting, !entry.isUnconfirmed {
            var kept = current
            // The key may have moved and the tool may have been named since.
            kept.key = padKeys.first { $0.key != overflowKey && $0.value == current.sessionID }?.key ?? current.key
            kept.pendingTool = entry.pendingTool ?? current.pendingTool
            return kept
        }
        return trigger(entries: entries, padKeys: padKeys, overflowKey: overflowKey)
    }

    public static func isActive(
        entries: [SessionRegistry.Entry], padKeys: [Int: String], overflowKey: Int? = nil
    ) -> Bool {
        trigger(entries: entries, padKeys: padKeys, overflowKey: overflowKey) != nil
    }

    /// What the stick sends in question mode: the bare arrow of its direction.
    public static func action(for direction: Joystick.Direction) -> KeyAction {
        switch direction {
        case .up: .arrowUp
        case .down: .arrowDown
        case .left: .arrowLeft
        case .right: .arrowRight
        }
    }

    // MARK: - the rest of the pad

    /**
     FAST and CODEX do nothing while a prompt waits, tap or hold.

     FAST's ⇧⇥ is `confirm:cycleMode` in a dialog: on an edit prompt it picks "accept
     every edit this session", in the plan's feedback field it approves the plan.
     CODEX's ⎋⎋ cancels the prompt with the first ⎋ and opens rewind with the second.
     Neither is something to fire by reaching for a key next to APPR.
     */
    public static let ignoredCaps: Set<String> = ["ACT06", "ACT12"]

    public static func ignores(cap: String, active: Bool) -> Bool {
        active && ignoredCaps.contains(cap)
    }

    public static func ignoredLogLine(cap: String) -> String {
        "key \(cap): ignored in question mode"
    }

    /// The tool whose prompt is a plan to read: the dial keeps scrolling for it.
    public static let planTool = "ExitPlanMode"
    /// Space: toggles a multi-select option or an MCP form's boolean.
    public static let space = Shortcut(keyCode: 49, key: "Space")
    /// Tab: amend a permission answer, next field of an MCP form.
    public static let tab = Shortcut(keyCode: 48, key: "⇥")

    public enum DialInput: Equatable, Sendable {
        /// One detent, as the dispatcher reports it: positive scrolls up.
        case turn(lines: Int)
        case click
        case hold
    }

    public enum DialRoute: Equatable, Sendable {
        /// What the dial does outside question mode.
        case profile
        case arrow(Joystick.Direction)
        case key(Shortcut)
    }

    /**
     The dial while a prompt waits: turning walks the options one per detent — not
     `scrollLines` of them — the click is Space and the hold is Tab. With a plan
     waiting, turning keeps scrolling: the plan has to be read before it is answered.
     */
    public static func dial(_ input: DialInput, pendingTool: String?) -> DialRoute {
        switch input {
        case let .turn(lines):
            if pendingTool == planTool || lines == 0 { return .profile }
            return .arrow(lines > 0 ? .up : .down)
        case .click:
            return .key(space)
        case .hold:
            return .key(tab)
        }
    }

    /**
     The session APPR and REJ answer in question mode: the one the stick is moving
     through, even when another is waiting too. Outside it — or for any other action —
     nil, and `Actions.respond`'s refuse-when-ambiguous rule applies.
     */
    public static func answerTarget(for action: KeyAction, trigger: Trigger?) -> String? {
        guard let trigger, action == .approve || action == .reject else { return nil }
        return trigger.sessionID
    }

    /// "question mode: on (key 2 · 11111111 · AskUserQuestion)" / "question mode: off".
    public static func logLine(_ trigger: Trigger?) -> String {
        guard let trigger else { return "question mode: off" }
        let workspace = trigger.workspaceID.map { String($0.prefix(8)) } ?? "no workspace"
        let tool = trigger.pendingTool.map { " · \($0)" } ?? ""
        return "question mode: on (key \(trigger.key) · \(workspace)\(tool))"
    }
}
