import Foundation

/**
 The debounce on NEW (F5, D2): no confirmation, because a terminal is cheap to create
 and cheap to close, but never two from one bouncy press.

 The cooldown runs from the last *admitted* launch. A dropped press does not extend
 it, or holding a finger on a chattering key would lock NEW out indefinitely.
 */
public struct LaunchCooldown {
    private let cooldown: TimeInterval
    private var lastLaunch: Date?

    public init(cooldown: TimeInterval) {
        self.cooldown = cooldown
    }

    public mutating func admit(now: Date) -> Bool {
        if let lastLaunch, now.timeIntervalSince(lastLaunch) < cooldown { return false }
        lastLaunch = now
        return true
    }
}

/**
 What NEW (F5) and CODEX (F8) turn into, given where the user is.

 Both act on the focused Superset workspace and nowhere else: outside Superset, or with
 nothing resolved, they propose nothing and the caller shows the "no workspace" blink.
 Neither reads a preference — the agent name is handed in (`launch.newAgent`,
 `launch.handoffAgent`) so the policy has one source of truth for it: the caller.
 */
public enum LaunchPolicy {
    /// `agents.run {prompt: ""}` in the focused workspace; nil outside one.
    public static func newAgent(context: BoardContext, agent: String) -> SupersetCall? {
        guard case .superset(let workspaceID) = context,
              !workspaceID.isEmpty, !agent.isEmpty else { return nil }
        return .runAgent(workspaceID: workspaceID, agent: agent, launch: .bare)
    }

    /// A handoff to confirm, never a call: it always goes through `PendingConfirmation`.
    /// How a confirmed handoff reaches the host-service is decided after the spike.
    public static func handoff(focused: (terminalID: String, workspaceID: String)?, agent: String) -> PendingAction? {
        guard let focused, !focused.terminalID.isEmpty, !focused.workspaceID.isEmpty,
              !agent.isEmpty else { return nil }
        return .handoff(terminalID: focused.terminalID, workspaceID: focused.workspaceID, agent: agent)
    }
}
