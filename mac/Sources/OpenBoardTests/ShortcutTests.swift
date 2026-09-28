import Foundation
import OpenBoardKit

/**
 The recorded chord: how it prints, how it is stored, and that the two actions built
 on it are wired into the picker.
 */
func runShortcutTests() {
    test("the label prints modifiers in the order macOS does") {
        let all = Shortcut(keyCode: 49, modifiers: [.command, .control, .option, .shift], key: "Space")
        expectEqual(all.label, "⌃⌥⇧⌘Space")
        expectEqual(Shortcut(keyCode: 96, modifiers: [.function], key: "F5").label, "fn F5")
        expectEqual(Shortcut(keyCode: 16, key: "Y").label, "Y")
    }

    test("a modifier on its own shows just its symbol") {
        // A lone right ⌥ has no key name; "key 61" would be a number nobody recognises.
        expectEqual(Shortcut(keyCode: 61, modifiers: [.option], key: "").label, "⌥")
        expectEqual(Shortcut(keyCode: 63, modifiers: [.function], key: "").label, "fn")
        expectEqual(Shortcut(keyCode: 200, key: "").label, "key 200")
    }

    test("a shortcut round-trips through JSON with a stable modifier order") {
        let chord = Shortcut(keyCode: 16, modifiers: [.command, .control], key: "Y", mode: .hold)
        expectEqual(Shortcut(json: chord.json), chord)
        // A Set has no order; the file must not be rewritten differently each save.
        expectEqual(chord.json["modifiers"] as? [String], ["control", "command"])
        expectEqual(chord.json["mode"] as? String, "hold")
    }

    test("a document without a key code is not a shortcut") {
        expect(Shortcut(json: ["modifiers": ["command"], "key": "Y"]) == nil)
        // Neither is one whose key code cannot be a CGKeyCode — sending it would
        // trap on the UInt16 conversion, at key-press time.
        expect(Shortcut(json: ["keyCode": -1]) == nil)
        expect(Shortcut(json: ["keyCode": 70000]) == nil)
    }

    test("unknown modifiers and modes degrade rather than fail") {
        let chord = Shortcut(json: ["keyCode": 49, "modifiers": ["command", "hyper"], "mode": "toggle"])
        expectEqual(chord?.modifiers, [.command])
        expectEqual(chord?.mode, .tap)
        expectEqual(chord?.key, "")
    }

    test("space is what push-to-talk holds") {
        expectEqual(Shortcut.space.keyCode, 49)
        expectEqual(Shortcut.space.mode, .hold)
        expect(Shortcut.space.modifiers.isEmpty)
    }

    test("the two new actions are wired into the pickers") {
        expectEqual(KeyAction(rawValue: "enter"), .enter)
        expectEqual(KeyAction(rawValue: "shortcut"), .shortcut)
        expectEqual(KeyAction.enter.hint, "⏎", "the keycap glyph approve already uses")
        expect(KeyAction.shortcut.needsShortcut)
        expect(!KeyAction.enter.needsShortcut)
        expect(!KeyAction.shortcut.needsSnippetText)
        expect(KeyAction.forJoystick.contains(.enter))
        expect(KeyAction.forJoystick.contains(.shortcut))
    }

    // MARK: - repeat (⎋⎋ from one press)

    test("repeat: absent reads as once, and once is not written back") {
        let esc = try Harness.require(Shortcut(json: ["keyCode": 53, "key": "⎋", "mode": "tap"]))
        expectEqual(esc.repeats, 1)
        expect(esc.json["repeat"] == nil, "a default of 1 must not be written into every chord")
        expectEqual(Shortcut(json: esc.json), esc)
    }

    test("repeat: a stored count round-trips") {
        let twice = try Harness.require(Shortcut(json: ["keyCode": 53, "key": "⎋", "mode": "tap", "repeat": 2]))
        expectEqual(twice.repeats, 2)
        expectEqual(twice.json["repeat"] as? Int, 2)
        expectEqual(Shortcut(json: twice.json), twice)
        expect(twice != Shortcut(keyCode: 53, key: "⎋"), "the count is part of the chord")
    }

    test("repeat: clamped to 1…5, and anything that is not a number is once") {
        func count(_ raw: Any) -> Int? { Shortcut(json: ["keyCode": 53, "key": "⎋", "repeat": raw])?.repeats }
        expectEqual(count(0), 1)
        expectEqual(count(-3), 1)
        expectEqual(count(9), 5)
        expectEqual(count(5), 5)
        expectEqual(count("2"), 1)
        expectEqual(count(2.7), 1)
        expectEqual(Shortcut(keyCode: 53, key: "⎋", repeats: 12).repeats, 5)
        expectEqual(Shortcut(keyCode: 53, key: "⎋", repeats: 0).repeats, 1)
    }

    test("repeat: a tap is sent N times in order, a fixed short gap apart; a hold once") {
        let twice = Shortcut(keyCode: 53, key: "⎋", mode: .tap, repeats: 2)
        expectEqual(twice.sendDelays, [0, Shortcut.repeatGap])
        expectEqual(Shortcut(keyCode: 53, key: "⎋", repeats: 3).sendDelays, [0, Shortcut.repeatGap, Shortcut.repeatGap])
        expectEqual(Shortcut(keyCode: 53, key: "⎋").sendDelays, [0])
        // A held chord stays down until release; repeating it means nothing.
        expectEqual(Shortcut(keyCode: 49, key: "Space", mode: .hold, repeats: 3).sendDelays, [0])
        // Short enough to read as one gesture, long enough for the TUI to see two keys.
        expect(Shortcut.repeatGap >= 0.03 && Shortcut.repeatGap <= 0.1)
    }
}
