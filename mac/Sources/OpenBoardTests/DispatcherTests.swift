import Foundation
import OpenBoardKit

/**
 Key dispatch, including the three cases that each caused a real, visible failure:
 a wide keycap firing twice, an encoder that stopped responding when turned quickly,
 and a debounce that swallowed a release and left a key held down.
 */
func runDispatcherTests() {
    let t0 = Date()

    test("an agent key jumps to its slot") {
        var dispatcher = KeyDispatcher()
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "AG00", action: .down), now: t0),
            .jump(slot: 1)
        )
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "AG05", action: .down), now: t0),
            .jump(slot: 6)
        )
    }

    test("an action key runs what it is bound to") {
        var dispatcher = KeyDispatcher()
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ACT06", action: .down), now: t0),
            .action(.approve, key: "ACT06")
        )
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ACT08", action: .down), now: t0),
            .action(.snippet, key: "ACT08")
        )
    }

    test("ACT10 and ACT11 are separate keys on the clone") {
        // The clone has separate mic and pencil caps, so ACT11 must not be folded into
        // ACT10 — pressing the pencil would otherwise start dictation.
        var dispatcher = KeyDispatcher(actions: ["ACT10": .voiceTap, "ACT11": .snippet])
        let first = dispatcher.intent(for: KeyEvent(key: "ACT10", action: .down), now: t0)
        let second = dispatcher.intent(
            for: KeyEvent(key: "ACT11", action: .down),
            now: t0.addingTimeInterval(0.007)
        )
        expectEqual(first, .action(.voiceTap, key: "ACT10"))
        expectEqual(second, .action(.snippet, key: "ACT11"))
    }

    test("a repeat inside the debounce window is dropped") {
        // Approve sends Return. A burst can accept a prompt and then submit empty
        // input to the session behind it.
        var dispatcher = KeyDispatcher()
        expect(dispatcher.intent(for: KeyEvent(key: "ACT06", action: .down), now: t0) != nil)
        expect(
            dispatcher.intent(
                for: KeyEvent(key: "ACT06", action: .down), now: t0.addingTimeInterval(0.1)
            ) == nil,
            "too soon"
        )
        expect(
            dispatcher.intent(
                for: KeyEvent(key: "ACT06", action: .down), now: t0.addingTimeInterval(0.5)
            ) != nil,
            "past the window, should fire"
        )
    }

    test("a different key is not blocked by another's debounce") {
        var dispatcher = KeyDispatcher()
        _ = dispatcher.intent(for: KeyEvent(key: "ACT06", action: .down), now: t0)
        expect(
            dispatcher.intent(
                for: KeyEvent(key: "ACT07", action: .down), now: t0.addingTimeInterval(0.01)
            ) != nil,
            "debounce is per key"
        )
    }

    test("encoder ticks are never debounced") {
        // A fast turn emits many ticks in quick succession. Debouncing them drops most
        // of the turn, which reads as the encoder being broken rather than sensitive.
        var dispatcher = KeyDispatcher()
        var delivered = 0
        for i in 0..<20 {
            let intent = dispatcher.intent(
                for: KeyEvent(key: "ENC_CW", action: .tick),
                now: t0.addingTimeInterval(Double(i) * 0.005)
            )
            if intent != nil { delivered += 1 }
        }
        expectEqual(delivered, 20, "every tick must survive")
    }

    test("the encoder scrolls both ways, and clicks separately") {
        var dispatcher = KeyDispatcher(actions: KeyAction.defaults, encoderClick: .settings)
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ENC_CW", action: .tick), now: t0),
            .scroll(lines: 3)
        )
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ENC_CC", action: .tick), now: t0),
            .scroll(lines: -3)
        )
        // The click is reported as an edge, not resolved to an action: it has two
        // bindings now, and which applies depends on how long the button stays down.
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ENC_CLK", action: .down), now: t0),
            .encoderPressed
        )
    }

    test("inverting the encoder flips both directions together") {
        var dispatcher = KeyDispatcher(actions: KeyAction.defaults, encoderClick: .settings)
        dispatcher.clockwiseScrollsUp = false

        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ENC_CW", action: .tick), now: t0),
            .scroll(lines: -3)
        )
        // Flipping only one end would leave a dial that scrolls the same way whichever
        // way it is turned — indistinguishable from broken hardware.
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ENC_CC", action: .tick), now: t0),
            .scroll(lines: 3)
        )
    }

    test("scroll distance follows the configured lines") {
        var dispatcher = KeyDispatcher(actions: KeyAction.defaults)
        dispatcher.scrollLines = 8
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ENC_CW", action: .tick), now: t0),
            .scroll(lines: 8)
        )
        dispatcher.clockwiseScrollsUp = false
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ENC_CW", action: .tick), now: t0),
            .scroll(lines: -8)
        )
    }

    test("a fast turn is never debounced away") {
        // Ticks have no release and arrive in bursts. Debouncing them would drop most
        // of a fast turn, which feels like a dead dial rather than a sensitive one.
        var dispatcher = KeyDispatcher(actions: KeyAction.defaults)
        for offset in 0..<20 {
            let intent = dispatcher.intent(
                for: KeyEvent(key: "ENC_CW", action: .tick),
                now: t0.addingTimeInterval(Double(offset) * 0.005)
            )
            expectEqual(intent, .scroll(lines: 3), "tick \(offset) was swallowed")
        }
    }

    test("a release is delivered raw, never debounced") {
        // Push-to-talk needs both edges. A dropped release leaves a key held down
        // indefinitely — invisible until every later keystroke is wrong.
        var dispatcher = KeyDispatcher()
        _ = dispatcher.intent(for: KeyEvent(key: "ACT10", action: .down), now: t0)
        expectEqual(
            dispatcher.intent(
                for: KeyEvent(key: "ACT10", action: .up), now: t0.addingTimeInterval(0.05)
            ),
            .release(key: "ACT10"),
            "a release inside the debounce window must still arrive"
        )
    }

    test("releasing an agent key does nothing") {
        // Agent keys jump on press; there is nothing to let go of.
        var dispatcher = KeyDispatcher()
        expect(dispatcher.intent(for: KeyEvent(key: "AG00", action: .up), now: t0) == nil)
    }

    test("an unbound key is silent") {
        var dispatcher = KeyDispatcher(actions: [:])
        expect(dispatcher.intent(for: KeyEvent(key: "ACT06", action: .down), now: t0) == nil)
        expect(dispatcher.intent(for: KeyEvent(key: "NONSENSE", action: .down), now: t0) == nil)
    }

    test("rebinding clears the debounce history") {
        // Otherwise the first press after a rebind is swallowed by the old key's window.
        var dispatcher = KeyDispatcher()
        _ = dispatcher.intent(for: KeyEvent(key: "ACT06", action: .down), now: t0)
        dispatcher.reset()
        expect(
            dispatcher.intent(
                for: KeyEvent(key: "ACT06", action: .down), now: t0.addingTimeInterval(0.01)
            ) != nil
        )
    }
    test("a key with a long binding reports the press, not the action") {
        // Tap or hold is not known yet; the controller times it (ActionPressTracker).
        var dispatcher = KeyDispatcher()
        dispatcher.longPressKeys = ["ACT07"]
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ACT07", action: .down), now: t0),
            .actionPressed(key: "ACT07")
        )
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ACT07", action: .up), now: t0.addingTimeInterval(0.2)),
            .release(key: "ACT07")
        )
    }

    test("a long-only key still reports the press") {
        // NEW is unassigned on tap (D1) but holds to quick-create in Superset.
        var dispatcher = KeyDispatcher(actions: [:])
        dispatcher.longPressKeys = ["ACT11"]
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ACT11", action: .down), now: t0),
            .actionPressed(key: "ACT11")
        )
    }

    test("a key without a long binding still fires its action on press") {
        var dispatcher = KeyDispatcher()
        dispatcher.longPressKeys = ["ACT07"]
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ACT06", action: .down), now: t0),
            .action(.approve, key: "ACT06")
        )
    }

    test("a long-bound key is still debounced") {
        var dispatcher = KeyDispatcher()
        dispatcher.longPressKeys = ["ACT07"]
        expect(dispatcher.intent(for: KeyEvent(key: "ACT07", action: .down), now: t0) != nil)
        expect(
            dispatcher.intent(for: KeyEvent(key: "ACT07", action: .down), now: t0.addingTimeInterval(0.1)) == nil
        )
    }

    test("agent keys are unchanged by long bindings") {
        // Jump on press, release discarded — even if a config names an agent key.
        var dispatcher = KeyDispatcher()
        dispatcher.longPressKeys = ["AG00", "ACT07"]
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "AG00", action: .down), now: t0),
            .jump(slot: 1)
        )
        expect(dispatcher.intent(for: KeyEvent(key: "AG00", action: .up), now: t0.addingTimeInterval(0.6)) == nil)
    }

    test("the encoder click is unchanged by long bindings") {
        var dispatcher = KeyDispatcher()
        dispatcher.longPressKeys = ["ENC_CLK"]
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ENC_CLK", action: .down), now: t0),
            .encoderPressed
        )
    }
}
