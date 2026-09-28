import Foundation
import OpenBoardKit

/**
 What the pad shows, as opposed to who holds a key.

 The registry is identity and persistence; the pad is a view drawn from it at paint
 time. Every test here builds a real registry through `claim` and `enrich` — the same
 path hooks take — so a view that only works on hand-made entries cannot pass.
 */
func runPadViewTests() {
    let alive: (Int?) -> Bool = { _ in true }
    let frontend = "11111111-1111-4111-8111-111111111111"
    let backend = "22222222-2222-4222-8222-222222222222"

    /// Claim a session and tag it with a workspace, the way a Superset hook does.
    func add(
        _ registry: inout SessionRegistry, _ id: String, pid: Int,
        workspace: String? = nil, cwd: String? = nil, state: SessionState = .idle
    ) {
        _ = registry.claim(sessionID: id, cwd: cwd, pid: pid, state: state, isAlive: alive)
        registry.enrich(sessionID: id, supersetWorkspaceID: workspace)
    }

    test("each workspace shows only its own sessions, from key 1") {
        // Interleaved on purpose: registry slots 1, 2, 3 belong to frontend, Backend,
        // frontend, and the pad must not leave Backend's slot as a hole.
        var registry = SessionRegistry()
        add(&registry, "m1", pid: 1, workspace: frontend)
        add(&registry, "o1", pid: 2, workspace: backend)
        add(&registry, "m2", pid: 3, workspace: frontend)

        let mine = PadView.compose(entries: registry.entries, context: .superset(workspaceID: frontend))
        expectEqual(mine.keys, [1: "m1", 2: "m2"])
        let theirs = PadView.compose(entries: registry.entries, context: .superset(workspaceID: backend))
        expectEqual(theirs.keys, [1: "o1"])
    }

    test("releasing key 1 leaves no gap, and a newcomer goes last") {
        var registry = SessionRegistry()
        add(&registry, "m1", pid: 1, workspace: frontend)
        add(&registry, "m2", pid: 2, workspace: frontend)
        add(&registry, "m3", pid: 3, workspace: frontend)
        registry.release(sessionID: "m1")
        let context = BoardContext.superset(workspaceID: frontend)
        expectEqual(PadView.compose(entries: registry.entries, context: context).keys,
                    [1: "m2", 2: "m3"])

        // Takes registry slot 1, but it is the newest session, so it is the last key.
        add(&registry, "m4", pid: 4, workspace: frontend)
        expectEqual(registry.entry(forSession: "m4")?.slot, 1)
        expectEqual(PadView.compose(entries: registry.entries, context: context).keys,
                    [1: "m2", 2: "m3", 3: "m4"])
    }

    test("a session waiting elsewhere borrows key 6") {
        // Hiding a prompt because it is in another workspace would be the board
        // failing at the one thing it is for.
        var registry = SessionRegistry()
        add(&registry, "m1", pid: 1, workspace: frontend)
        add(&registry, "m2", pid: 2, workspace: frontend)
        add(&registry, "o1", pid: 3, workspace: backend, state: .error)
        add(&registry, "o2", pid: 4, workspace: backend, state: .awaiting)

        let view = PadView.compose(entries: registry.entries, context: .superset(workspaceID: frontend))
        expectEqual(view.keys, [1: "m1", 2: "m2", 6: "o2"], "awaiting outranks error")
        expectEqual(view.overflowKey, 6)

        registry.setState(sessionID: "o2", to: .working)
        let after = PadView.compose(entries: registry.entries, context: .superset(workspaceID: frontend))
        expectEqual(after.keys[6], "o1", "an error elsewhere also qualifies")
    }

    test("a finished session elsewhere does not take the overflow key") {
        var registry = SessionRegistry()
        add(&registry, "m1", pid: 1, workspace: frontend)
        add(&registry, "o1", pid: 2, workspace: backend, state: .done)

        let view = PadView.compose(entries: registry.entries, context: .superset(workspaceID: frontend))
        expectEqual(view.keys, [1: "m1"])
        expectEqual(view.overflowKey, nil)
    }

    test("six sessions of its own leave no room for overflow") {
        // Seven slots so both can exist at once; the pad still has six keys.
        var registry = SessionRegistry(slotCount: 7)
        for index in 1...6 { add(&registry, "m\(index)", pid: index, workspace: frontend) }
        add(&registry, "o1", pid: 7, workspace: backend, state: .awaiting)

        let view = PadView.compose(
            entries: registry.entries, context: .superset(workspaceID: frontend), capacity: 6
        )
        expectEqual(view.keys, [1: "m1", 2: "m2", 3: "m3", 4: "m4", 5: "m5", 6: "m6"])
        expectEqual(view.overflowKey, nil)
    }

    test("the ring still sees every session, filtered or not") {
        // The ring summarises the whole board. A prompt in a workspace you are not
        // looking at must still be able to light it.
        var registry = SessionRegistry()
        add(&registry, "m1", pid: 1, workspace: frontend)
        add(&registry, "o1", pid: 2, workspace: backend, state: .done)

        let view = PadView.compose(entries: registry.entries, context: .superset(workspaceID: frontend))
        expectEqual(view.ringStates, registry.occupancy().map { $0.entry?.state })
        expect(view.ringStates.contains(.done), "Backend's finished session fell out of the ring")
    }

    test("the all context reproduces the registry's occupancy exactly") {
        // Holes included: outside Superset nothing about the pad changes.
        var registry = SessionRegistry()
        add(&registry, "a", pid: 1, workspace: frontend)
        add(&registry, "b", pid: 2)
        add(&registry, "c", pid: 3, workspace: backend, state: .awaiting)
        registry.release(sessionID: "b")

        let view = PadView.compose(entries: registry.entries, context: .all)
        var expected: [Int: String] = [:]
        for (slot, entry) in registry.occupancy() { if let entry { expected[slot] = entry.sessionID } }
        expectEqual(view.keys, expected)
        expectEqual(view.keys, [1: "a", 3: "c"])
        expectEqual(view.overflowKey, nil)
        expectEqual(view.ringStates, registry.occupancy().map { $0.entry?.state })
    }

    test("a session without a workspace id is placed by its working directory") {
        // Restored from an old registry, or adopted before its first Superset hook:
        // the worktree path is the only thing that ties it to a workspace.
        let tree = "/Users/someone/.superset/worktrees/my-app/feature-branch"
        var registry = SessionRegistry()
        add(&registry, "tagged", pid: 1, workspace: frontend)
        add(&registry, "untagged", pid: 2, cwd: tree)
        add(&registry, "stranger", pid: 3, cwd: "/Users/someone/elsewhere")

        let view = PadView.compose(
            entries: registry.entries,
            context: .superset(workspaceID: frontend),
            worktrees: [frontend: tree, backend: "/Users/someone/backend-overview"]
        )
        expectEqual(view.keys, [1: "tagged", 2: "untagged"])
    }

    test("nextKey wraps around inside the workspace") {
        var registry = SessionRegistry()
        add(&registry, "m1", pid: 1, workspace: frontend)
        add(&registry, "o1", pid: 2, workspace: backend)
        add(&registry, "m2", pid: 3, workspace: frontend)
        add(&registry, "m3", pid: 4, workspace: frontend)
        let view = PadView.compose(entries: registry.entries, context: .superset(workspaceID: frontend))
        expectEqual(view.keys, [1: "m1", 2: "m2", 3: "m3"])

        expectEqual(view.nextKey(from: 1, forward: true), 2)
        expectEqual(view.nextKey(from: 2, forward: true), 3)
        expectEqual(view.nextKey(from: 3, forward: true), 1, "past the last visible key is the first")
        expectEqual(view.nextKey(from: nil, forward: true), 1, "nothing focused starts at the first")
    }

    test("nextKey backwards from the first goes to the last visible key") {
        var registry = SessionRegistry()
        add(&registry, "m1", pid: 1, workspace: frontend)
        add(&registry, "m2", pid: 2, workspace: frontend)
        let view = PadView.compose(entries: registry.entries, context: .superset(workspaceID: frontend))
        expectEqual(view.nextKey(from: 1, forward: false), 2)
        expectEqual(view.nextKey(from: 2, forward: false), 1)
        expectEqual(view.nextKey(from: nil, forward: false), 2)
    }

    test("nextKey never lands on the overflow key") {
        // The borrowed key belongs to another workspace; stepping onto it would take
        // BRANCH out of the workspace in front.
        var registry = SessionRegistry()
        add(&registry, "m1", pid: 1, workspace: frontend)
        add(&registry, "m2", pid: 2, workspace: frontend)
        add(&registry, "o1", pid: 3, workspace: backend, state: .awaiting)
        let view = PadView.compose(entries: registry.entries, context: .superset(workspaceID: frontend))
        expectEqual(view.overflowKey, 6)
        expectEqual(view.nextKey(from: 2, forward: true), 1)
        expectEqual(view.nextKey(from: 1, forward: false), 2)
        expectEqual(view.nextKey(from: 6, forward: true), 1, "from the overflow key, back into the workspace")
        expectEqual(view.nextKey(from: 6, forward: false), 2)
    }

    test("nextKey skips dark keys and is nil on an empty pad") {
        var registry = SessionRegistry()
        add(&registry, "a", pid: 1)
        add(&registry, "b", pid: 2)
        add(&registry, "c", pid: 3)
        registry.release(sessionID: "b")
        let view = PadView.compose(entries: registry.entries, context: .all)
        expectEqual(view.nextKey(from: 1, forward: true), 3, "the hole at key 2 is skipped")
        expectEqual(view.nextKey(from: 2, forward: true), 3, "from a dark key, the next lit one")
        expectEqual(view.nextKey(from: 2, forward: false), 1)
        expectEqual(PadView().nextKey(from: nil, forward: true), nil)
        expectEqual(PadView().nextKey(from: 3, forward: false), nil)
    }
}
