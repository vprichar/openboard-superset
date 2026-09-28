import Foundation
import OpenBoardKit

/**
 Keys that type into a live session.

 A snippet is typed straight into whatever Claude Code session has focus, and the
 config that holds snippets is plain, editable JSON. One slash command is enough to
 throw away a session's context — so the guard refuses the destructive ones in code,
 whatever the config says, unless the config explicitly opts out.
 */
func runSnippetGuardTests() {
    let dangerous = ["/clear", "/reset", "/exit", "/quit", "/logout"]

    test("destructive slash commands are refused") {
        for command in dangerous {
            guard case .block = SnippetGuard.check(command, allowDangerous: false) else {
                expect(false, "\(command) was allowed")
                continue
            }
        }
    }

    test("leading whitespace or capitals do not get a destructive command through") {
        for text in ["   /clear", "\t/reset", "\n/exit", "/QUIT", "  /LogOut", "/Clear now"] {
            guard case .block = SnippetGuard.check(text, allowDangerous: false) else {
                expect(false, "\(text.debugDescription) was allowed")
                continue
            }
        }
    }

    test("a destructive command on a later line is refused too") {
        // Typing a newline submits the line before it, so the second line arrives as
        // a command of its own.
        guard case .block = SnippetGuard.check("looks fine\n  /clear", allowDangerous: false)
        else { return expect(false, "a /clear on the second line was allowed") }
    }

    test("ordinary snippets and harmless slash commands pass") {
        for text in ["/start-ticket", "please continue", "run the tests", "/review", ""] {
            expectEqual(SnippetGuard.check(text, allowDangerous: false), .allow, text)
        }
    }

    test("the block says which command it caught") {
        guard case let .block(reason) = SnippetGuard.check("  /exit", allowDangerous: false)
        else { return expect(false, "/exit was allowed") }
        expect(reason.contains("/exit"), "reason does not name the command: \(reason)")
    }

    test("allowDangerous lets everything through") {
        for command in dangerous + ["  /CLEAR", "/start-ticket"] {
            expectEqual(SnippetGuard.check(command, allowDangerous: true), .allow, command)
        }
    }
}

/**
 `enter` is not blind.

 A bare ⏎ right after a snippet submits whatever the snippet typed — including a
 half-typed command nobody reviewed. Inside the window it is refused.
 */
func runEnterGuardTests() {
    let base = Date(timeIntervalSince1970: 1_790_000_000)

    test("enter with no snippet before it is allowed") {
        let guardian = EnterGuard()
        expect(guardian.allowsEnter(now: base))
    }

    test("enter 3s after a snippet is refused") {
        var guardian = EnterGuard()
        guardian.noteSnippet(now: base)
        expectEqual(guardian.allowsEnter(now: base.addingTimeInterval(3)), false)
    }

    test("enter 11s after a snippet is allowed") {
        var guardian = EnterGuard()
        guardian.noteSnippet(now: base)
        expect(guardian.allowsEnter(now: base.addingTimeInterval(11)))
    }

    test("the window is measured from the latest snippet") {
        var guardian = EnterGuard(window: 10)
        guardian.noteSnippet(now: base)
        guardian.noteSnippet(now: base.addingTimeInterval(8))
        expectEqual(guardian.allowsEnter(now: base.addingTimeInterval(12)), false,
                    "only 4s since the second snippet")
        expect(guardian.allowsEnter(now: base.addingTimeInterval(18.5)))
    }

    test("the window is configurable") {
        var guardian = EnterGuard(window: 2)
        guardian.noteSnippet(now: base)
        expectEqual(guardian.allowsEnter(now: base.addingTimeInterval(1)), false)
        expect(guardian.allowsEnter(now: base.addingTimeInterval(3)))
    }
}
