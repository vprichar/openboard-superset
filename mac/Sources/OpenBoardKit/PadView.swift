import Foundation

/// Which sessions the pad is showing.
public enum BoardContext: Equatable, Sendable {
    /// Every session on the board, on its registry slot — the behaviour before
    /// workspaces existed, and what any non-Superset surface in front still gets.
    case all
    /// Only the sessions of this Superset workspace, packed from key 1.
    case superset(workspaceID: String)
}

/**
 What the six keys show, derived from the registry at paint time.

 The registry stays what it was — identity and persistence, who holds which slot —
 and is never reshuffled to suit a view. Reassigning slots every time you switch
 workspaces would churn `registry.json`, break "my session is slot 2" in the popover,
 and make eviction pick victims by what you happened to be looking at. So the pad is a
 *view*: recomputed from the entries whenever it is drawn, and thrown away after.

 ## Rules

 - `.all` is exactly `occupancy()`: key N is registry slot N, holes included.
 - `.superset(W)` shows W's sessions packed onto keys 1…n, no holes, sorted by
   `boardOrder` — so a `/clear` stays put and a newcomer goes last.
 - **Overflow.** With a key to spare, the last key borrows the most urgent session
   from anywhere else — but only one asking for something (`awaiting`) or broken
   (`error`). A prompt hidden because it is in another workspace is the board failing
   at its one job; a finished session elsewhere is not urgent and stays off.
 - The ring summarises every session regardless of context: `ringStates` is the full
   registry, in slot order, exactly what `Ambient.resolve` read before.
 */
public struct PadView: Equatable, Sendable {
    /// Pad key (1…capacity, before calibration) → session id. Keys absent here are dark.
    public var keys: [Int: String] = [:]
    /// The key lent to another workspace's urgent session, if any. Set only in a
    /// Superset context.
    public var overflowKey: Int? = nil
    /// Every registry slot's state, for the ring — never filtered.
    public var ringStates: [SessionState?] = []
    public var context: BoardContext = .all

    public init() {}

    /// The session a pad key press means, if the key is showing one.
    public func sessionID(forKey key: Int) -> String? { keys[key] }

    /**
     The key after (or before) `current`, among the keys this view is showing.

     What BRANCH steps through: only lit keys, wrapping at either end, and never the
     overflow key — that one is lent from another workspace, and stepping onto it would
     walk out of the workspace in front. From a key that is not showing anything (or
     the overflow key) it goes to the nearest lit key in that direction; with nothing
     focused it starts at the first key going forward, the last going back.
     */
    public func nextKey(from current: Int?, forward: Bool) -> Int? {
        let visible = keys.keys.filter { $0 != overflowKey }.sorted()
        guard let first = visible.first, let last = visible.last else { return nil }
        guard let current else { return forward ? first : last }
        if forward {
            return visible.first { $0 > current } ?? first
        }
        return visible.last { $0 < current } ?? last
    }

    /**
     - Parameter worktrees: workspace id → worktree path, from Superset's own table.
       Only consulted for an entry with no `supersetWorkspaceID` — restored from a
       registry written before the field existed, or adopted before its first
       Superset hook — where the working directory is the only thing tying it to a
       workspace.
     - Parameter borrowOverflow: whether the last key may be lent at all
       (`overflow.enabled`).
     */
    public static func compose(
        entries: [SessionRegistry.Entry],
        context: BoardContext,
        capacity: Int = BoardLayout.slotCount,
        worktrees: [String: String] = [:],
        borrowOverflow: Bool = true
    ) -> PadView {
        var view = PadView()
        view.context = context
        let highestSlot = max(capacity, entries.map(\.slot).max() ?? 0)
        view.ringStates = (1...max(highestSlot, 1)).map { slot in
            entries.first { $0.slot == slot }?.state
        }

        guard case let .superset(workspaceID) = context else {
            for entry in entries where (1...capacity).contains(entry.slot) {
                view.keys[entry.slot] = entry.sessionID
            }
            return view
        }

        let byOrder = { (a: SessionRegistry.Entry, b: SessionRegistry.Entry) in
            (a.boardOrder, a.claimSeq) < (b.boardOrder, b.claimSeq)
        }
        let own = entries
            .filter { workspace(of: $0, worktrees: worktrees) == workspaceID }
            .sorted(by: byOrder)
        for (index, entry) in own.prefix(capacity).enumerated() {
            view.keys[index + 1] = entry.sessionID
        }

        guard borrowOverflow, own.count < capacity else { return view }
        let ownIDs = Set(own.map(\.sessionID))
        // Awaiting before error, then whoever has been waiting longest.
        let rank: (SessionState) -> Int? = { state in
            switch state {
            case .awaiting: return 0
            case .error: return 1
            default: return nil
            }
        }
        let urgent = entries
            .filter { !ownIDs.contains($0.sessionID) && rank($0.state) != nil }
            .sorted { a, b in
                let (ra, rb) = (rank(a.state)!, rank(b.state)!)
                if ra != rb { return ra < rb }
                if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
                return byOrder(a, b)
            }
        if let borrowed = urgent.first {
            view.keys[capacity] = borrowed.sessionID
            view.overflowKey = capacity
        }
        return view
    }

    /**
     The Superset workspace an entry belongs to.

     The hook's `SUPERSET_WORKSPACE_ID` when it was carried. Otherwise the working
     directory: an exact worktree match, or failing that the deepest worktree the
     directory sits inside — a session started in a subfolder is still that
     workspace's, and the deepest match keeps a worktree nested in another checkout
     from being claimed by the outer one.
     */
    public static func workspace(
        of entry: SessionRegistry.Entry, worktrees: [String: String]
    ) -> String? {
        if let id = entry.supersetWorkspaceID { return id }
        guard let cwd = entry.cwd.map(normalized) else { return nil }
        var best: (id: String, length: Int)?
        for (id, path) in worktrees {
            let root = normalized(path)
            guard cwd == root || cwd.hasPrefix(root + "/") else { continue }
            if root.count > (best?.length ?? -1) { best = (id, root.count) }
        }
        return best?.id
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
