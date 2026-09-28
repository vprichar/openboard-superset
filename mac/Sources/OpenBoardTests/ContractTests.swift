import Foundation
import OpenBoardKit

/**
 The contracts every Superset package programs against.

 These are the fences, not the features: the closed list of host-service procedures,
 the two control bytes `writeInput` may carry, a token that cannot be printed, and the
 new key actions with the metadata the picker groups them by. Each test here fails the
 day someone widens a fence without meaning to — a procedure added to the enum, a third
 control byte, a `description` that leaks.
 */
func runContractTests() {
    test("new KeyAction raw values decode") {
        // The strings are the config file's vocabulary (Plan §2.5 + D10). A rename here
        // silently unbinds every key a hand-edited document assigned.
        let expected: [String: KeyAction] = [
            "superset-new-agent": .supersetNewAgent,
            "superset-handoff": .supersetHandoff,
            "jump-oldest-waiting": .jumpOldestWaiting,
            "interrupt-focused": .interruptFocused,
            "targeted-arm": .targetedArm,
        ]
        for (raw, action) in expected {
            expectEqual(KeyAction(rawValue: raw), action, raw)
            // And through the document reader, which is the path that matters.
            let prefs = Preferences.merging(["actionKeys": ["ACT11": raw]])
            expectEqual(prefs.keyActions["ACT11"], action, "\(raw) via actionKeys")
        }
    }

    test("every KeyAction has a category and a label") {
        for action in KeyAction.allCases {
            expect(!action.short.isEmpty, "\(action.rawValue) has no short label")
            expect(!action.long.isEmpty, "\(action.rawValue) has no long label")
            expect(KeyAction.Category.allCases.contains(action.category))
        }
        // Every category the picker shows a header for has at least one action under it.
        for category in KeyAction.Category.allCases {
            expect(
                KeyAction.allCases.contains { $0.category == category },
                "category \(category.rawValue) is an empty header"
            )
        }
        // The new ones read as what they are.
        for action: KeyAction in [.supersetNewAgent, .supersetHandoff, .interruptFocused, .targetedArm] {
            expectEqual(action.category, .superset, action.rawValue)
            expect(action.requiresSuperset, "\(action.rawValue) should require Superset")
        }
        // Nothing that predates the host client claims to need it.
        for action in KeyAction.allCases where action.category != .superset {
            expect(!action.requiresSuperset, "\(action.rawValue) claims to need Superset")
        }
    }

    test("new Superset actions carry their safeguard") {
        // D2: NEW is debounce only. The handoff is the two-step one (Plan §4), and
        // everything that writes to a terminal reads it first.
        expectEqual(KeyAction.supersetNewAgent.safeguard, .debounce)
        expectEqual(KeyAction.supersetHandoff.safeguard, .twoStep)
        expectEqual(KeyAction.interruptFocused.safeguard, .snapshotFirst)
        expectEqual(KeyAction.targetedArm.safeguard, .snapshotFirst)
        expectEqual(KeyAction.jumpOldestWaiting.safeguard, KeyAction.Safeguard.none)
        expectEqual(KeyAction.approve.safeguard, KeyAction.Safeguard.none)
    }

    test("SupersetProcedure is exactly the 11 of Plan §4") {
        let expected: Set<String> = [
            "health.check",
            "terminalAgents.list",
            "terminalAgents.listByWorkspace",
            "workspace.list",
            "project.list",
            "terminal.snapshot",
            "terminal.transcript",
            "agents.run",
            "terminal.writeInput",
            "terminal.send",
            "terminalAgents.clearWorkspaceStatuses",
        ]
        expectEqual(SupersetProcedure.allCases.count, 11)
        expectEqual(Set(SupersetProcedure.allCases.map(\.rawValue)), expected)

        let writers: Set<SupersetProcedure> = [
            .agentsRun, .terminalWriteInput, .terminalSend, .clearWorkspaceStatuses,
        ]
        for procedure in SupersetProcedure.allCases {
            expectEqual(procedure.writes, writers.contains(procedure), procedure.rawValue)
            expectEqual(
                procedure.kind == .mutation, procedure.writes,
                "\(procedure.rawValue): kind and writes disagree"
            )
            expect(SupersetAllowlist.permits(procedure.rawValue), procedure.rawValue)
        }
    }

    test("every forbidden name of Plan §4 is not permitted") {
        let forbidden = [
            "workspace.delete", "workspaceCleanup.destroy", "github.mergePR",
            "github.markPullRequestReady", "github.updatePullRequestBranch",
            "git.commit", "git.push", "git.discardChanges", "git.discardAll",
            "git.discardAllChanges", "terminal.killSession",
            "terminal.disposeWorkspaceSessions", "disposeWorkspaceSessions",
            "usage.removeAccount", "usage.restartAccountSessions", "usage.setDefaultAccount",
            "usage.quota", "git.getBranchSyncStatus", "refreshByWorkspaces",
            "settings.update", "automations.create", "pages.publish", "plugins.install",
            // Near misses: case, whitespace and prefixes are not the name.
            "Health.check", " health.check", "health.check ", "health", "",
            "terminal.writeInput.raw",
        ]
        for name in forbidden {
            expect(!SupersetAllowlist.permits(name), "\(name) must not be permitted")
        }
    }

    test("every SupersetCall names its own procedure") {
        let calls: [(SupersetCall, SupersetProcedure)] = [
            (.healthCheck, .healthCheck),
            (.listAgents(workspaceID: nil), .terminalAgentsList),
            (.listAgents(workspaceID: "w"), .terminalAgentsListByWorkspace),
            (.listWorkspaces, .workspaceList),
            (.listProjects, .projectList),
            (.snapshot(terminalID: "t", workspaceID: "w", maxLines: 20), .terminalSnapshot),
            (.transcript(terminalID: "t", workspaceID: "w", maxChars: 100), .terminalTranscript),
            (.runAgent(workspaceID: "w", agent: "claude", launch: .bare), .agentsRun),
            (.runAgent(workspaceID: "w", agent: "codex", launch: .prompt("handoff")), .agentsRun),
            (.writeInput(terminalID: "t", workspaceID: "w", data: .escape), .terminalWriteInput),
            (.send(terminalID: "t", workspaceID: "w", text: "sigue", submit: true), .terminalSend),
            (.clearStatuses(workspaceID: "w", terminalID: "t"), .clearWorkspaceStatuses),
        ]
        for (call, procedure) in calls {
            expectEqual(call.procedure, procedure, "\(call)")
        }
    }

    test("SecretToken prints as «redacted»") {
        let raw = "sk-live-0123456789abcdefghijklmnop"
        let token = SecretToken(raw)
        expectEqual("\(token)", "«redacted»")
        expectEqual(String(describing: token), "«redacted»")
        expectEqual(String(reflecting: token), "«redacted»")
        var dumped = ""
        dump(token, to: &dumped)
        expect(!dumped.contains(raw), "dump leaked the token")
        // Nested inside something that is printed whole — the way it would actually leak.
        let manifest = SupersetManifest(
            endpoint: URL(string: "http://example.invalid")!, organizationID: "org", token: token
        )
        expect(!"\(manifest)".contains(raw), "a manifest printed its token")
        expect(!String(reflecting: manifest).contains(raw), "a manifest debug-printed its token")
        // And the one door still opens.
        expectEqual(token.withRaw { $0 }, raw)
    }

    test("writeInput accepts only ⎋ and ⏎") {
        // By type: there is no case to put anything else in.
        expectEqual(ControlInput.allCases.count, 2)
        expectEqual(ControlInput.escape.rawValue, "\u{1b}")
        expectEqual(ControlInput.carriageReturn.rawValue, "\r")
        expect(ControlInput(rawValue: "rm -rf /\r") == nil)
    }
}
