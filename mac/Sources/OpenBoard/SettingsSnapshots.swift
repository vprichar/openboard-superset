import AppKit
import OpenBoardKit
import SwiftUI

/**
 Renders the settings panes to PNG and exits, for reviewing the UI without a screen.

 Run with `OPENBOARD_RENDER_SNAPSHOTS=<dir>` **and** `OPENBOARD_HOME=<scratch dir>`.
 The second is required, not advised: `BoardModel()` loads — and on a first run
 writes — the configuration, and the only configuration this may ever touch is a
 throwaway one. Without it the harness refuses and exits non-zero.

 Nothing else starts. The guard runs before `BoardController` exists, so there is no
 HID manager, no hook socket, no pad write and no repaint loop — just views drawn into
 bitmaps.

 Offscreen, with no Screen Recording permission: each pane is hosted in an
 `NSHostingView` inside a borderless window that is never ordered front, the window's
 `appearance` is forced to Aqua or Dark Aqua, and the view is drawn with
 `cacheDisplay(in:to:)`. Checked to render the AppKit-backed controls (pickers, text
 fields, toggles, sliders) as well as SwiftUI shapes. Toggles draw with an inactive
 track, since the window is never key.
 */
@MainActor
enum SettingsSnapshots {
    static let environmentKey = "OPENBOARD_RENDER_SNAPSHOTS"

    /// The output directory, when this launch is a snapshot run.
    static func requestedDirectory(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let raw = env[environmentKey], !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    /// One picture: a name, the view it shows, and what to change on the fixture
    /// first. Every shot starts again from `fixture()`, so one shot's change never
    /// leaks into the next.
    struct Shot {
        let name: String
        let size: NSSize
        let view: AnyView
        var prepare: @MainActor (BoardModel) -> Void = { _ in }
    }

    /// The width the settings window's detail side is reviewed at.
    static let paneSize = NSSize(width: 820, height: 760)
    /// The Board pane with an inspector open runs long; tall enough not to clip it.
    static let boardSize = NSSize(width: 820, height: 1180)
    static let virtualPadSize = NSSize(width: 340, height: 440)
    static let popoverSize = NSSize(width: 376, height: 760)
    static let sheetSize = NSSize(width: 560, height: 640)

    /**
     The configuration every shot starts from: the defaults with this pad's own
     mapping (the clone's, not upstream's) — FAST, APPR, REJ on ACT06–08, next session
     and hold-to-dictate on ACT09–10, ACT11/12 unassigned.

     Written out here rather than read from the real config: the harness never opens
     the user's file, and a fixture that changed whenever the user did would make two
     runs of the same code disagree.
     */
    static func fixture() -> Preferences {
        var p = Preferences.default
        p.actionKeys = [
            "ACT06": .shortcut,
            "ACT07": .approve,
            "ACT08": .reject,
            "ACT09": .nextSession,
            "ACT10": .voiceTalk,
            "ACT11": nil,
            "ACT12": nil,
            "ENC": .settings,
        ]
        p.caps.merge([
            "ACT06": "FAST", "ACT07": "APPR", "ACT08": "REJ", "ACT09": "BRANCH",
            "ACT10": "MIC", "ACT11": "NEW", "ACT12": "CODEX", "ENC": "SETUP",
        ]) { _, fixture in fixture }
        // FAST is ⇧⇥ (D4).
        p.shortcuts["ACT06"] = Shortcut(keyCode: 48, modifiers: [.shift], key: "⇥")
        return p
    }

    /**
     Render every shot in light and dark into `directory`, then return the exit code.

     Returns rather than exiting so the caller decides; the app delegate exits with it.
     */
    static func run(
        into directory: URL,
        board: @autoclosure () -> BoardModel,
        updater: Updater,
        setup: @autoclosure () -> SetupState,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        guard let home = env["OPENBOARD_HOME"], !home.isEmpty else {
            FileHandle.standardError.write(Data(
                "snapshots: refusing to run without OPENBOARD_HOME (it would read the real config)\n".utf8
            ))
            return 2
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("snapshots: cannot create \(directory.path): \(error)\n".utf8))
            return 1
        }

        // Only now, after the OPENBOARD_HOME check: building the model loads the config.
        let board = board()
        let setup = setup()
        // Built but never started: the popover only reads it.
        let battery = BatteryMonitor()
        var written = 0
        var failed = 0

        // Both interface languages, forced through the override so the user's stored
        // choice is neither read nor written.
        defer { UIStrings.override = nil }
        for language in UILanguage.allCases {
            UIStrings.override = language
            for shot in shots() {
                board.apply(fixture())
                board.apply(slots: fixtureSlots(board))
                board.supersetLink = .off
                shot.prepare(board)
                for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let root = shot.view
                        .environmentObject(board)
                        .environmentObject(updater)
                        .environmentObject(setup)
                        .environmentObject(battery)
                        .environment(\.boardCommands, BoardCommands())
                        .tint(SystemColors.selectedRow)
                    let url = directory.appendingPathComponent("\(shot.name)-\(language.rawValue)-\(suffix).png")
                    if render(root, size: shot.size, appearance: appearanceName, to: url) {
                        written += 1
                        print("snapshots: wrote \(url.lastPathComponent)")
                    } else {
                        failed += 1
                        FileHandle.standardError.write(Data("snapshots: failed \(url.lastPathComponent)\n".utf8))
                    }
                }
            }
        }
        print("snapshots: \(written) written, \(failed) failed, home=\(home)")
        return failed == 0 ? 0 : 1
    }

    /// The two agent keys in the top row lit green (finished, not yet visited), as in
    /// the photo of the pad this is drawn from; the other four empty.
    static func fixtureSlots(_ board: BoardModel) -> [SlotView] {
        SlotView.emptyBoard.map { slot in
            guard slot.slot <= 2 else { return slot }
            var lit = slot
            lit.state = .done
            lit.sessionID = "fixture-\(slot.slot)"
            lit.title = "fixture"
            lit.emitting = board.appearances[.done]
            return lit
        }
    }

    /**
     What gets pictured: every pane, and the Board pane in the states its review
     asks for (§2 UI-A): ACT07 on Tap and on Hold, the stick in the Superset context
     with its "S" badge, an agent key's Remote block, a blocked snippet — plus the
     Superset pane in each connection state and the virtual pad.
     */
    static func shots() -> [Shot] {
        let superset = Preferences.supersetBundleID
        return [
            Shot(name: "board", size: boardSize, view: AnyView(BoardPane())),
            Shot(name: "board-ACT07-tap", size: boardSize, view: AnyView(BoardPane(selected: "ACT07"))),
            Shot(name: "board-ACT07-hold", size: boardSize, view: AnyView(BoardPane(selected: "ACT07", gesture: .hold))),
            Shot(
                name: "board-ACT09-hold-superset", size: boardSize,
                view: AnyView(BoardPane(selected: "ACT09", context: superset, gesture: .hold)),
                prepare: { board in
                    board.updatePreferences {
                        SettingsEditing.setAction(.targetedArm, for: .action("ACT09"), gesture: .hold, profile: superset, in: &$0)
                    }
                }
            ),
            Shot(name: "board-JOY-superset", size: boardSize, view: AnyView(BoardPane(selected: "JOY", context: superset))),
            Shot(name: "board-ENC-superset", size: boardSize, view: AnyView(BoardPane(selected: "ENC", context: superset))),
            Shot(name: "board-AG00-remote", size: boardSize, view: AnyView(BoardPane(selected: "AG00"))),
            Shot(
                name: "board-ACT11-dangerous-snippet", size: boardSize,
                view: AnyView(BoardPane(selected: "ACT11")),
                prepare: { board in
                    board.actions["ACT11"] = .snippet
                    board.snippets["ACT11"] = "/clear"
                }
            ),
            Shot(name: "board-ACT06-shortcut", size: boardSize, view: AnyView(BoardPane(selected: "ACT06"))),
        ] + [480, 640, 720, 820].map { width in
            // Narrower than the window's usual pane: the inspector must drop under the
            // pad rather than overlap it, and three context chips must wrap, not clip.
            Shot(
                name: "board-ACT06-chrome-w\(width)", size: NSSize(width: CGFloat(width), height: 1500),
                view: AnyView(BoardPane(selected: "ACT06")),
                prepare: { board in
                    board.updatePreferences { SettingsEditing.addProfile(bundleID: "com.google.Chrome", in: &$0) }
                }
            )
        } + [
            Shot(name: "popover", size: popoverSize, view: AnyView(PopoverView())),
            Shot(name: "setup", size: sheetSize, view: AnyView(SetupSheet())),
            Shot(name: "calibration", size: sheetSize, view: AnyView(CalibrationSheet())),
            Shot(name: "colors", size: paneSize, view: AnyView(ColorsPane())),
            Shot(name: "device", size: paneSize, view: AnyView(DevicePane())),
            Shot(
                name: "superset-connected", size: paneSize, view: AnyView(SupersetPane()),
                prepare: { $0.supersetLink = .connected(version: "1.30.0", readOnly: false) }
            ),
            Shot(
                name: "superset-readonly", size: paneSize, view: AnyView(SupersetPane()),
                prepare: { $0.supersetLink = .versionMismatch(found: "1.31.0", tested: "1.30.0") }
            ),
            Shot(
                name: "superset-unreachable", size: paneSize, view: AnyView(SupersetPane()),
                prepare: { $0.supersetLink = .unreachable(reason: "host-service not running") }
            ),
            Shot(
                name: "superset-off", size: paneSize, view: AnyView(SupersetPane()),
                prepare: { $0.supersetLink = .off }
            ),
            Shot(name: "workspaces", size: paneSize, view: AnyView(WorkspacePane())),
            // UI-B's custom themes: a duplicated built-in renamed, an imported-style theme
            // whose awaiting clashes (the ⚠︎), and a hand edit (the "Custom" state).
            Shot(
                name: "workspaces-temas", size: NSSize(width: 820, height: 1400),
                view: AnyView(WorkspacePane()),
                prepare: { board in
                    board.updatePreferences { p in
                        let office = SettingsEditing.duplicateTheme(.claude, in: &p)
                        SettingsEditing.renameTheme(id: office.id, to: "Oficina", in: &p)

                        var sunset = CustomTheme(from: .pop, id: CustomTheme.newID(), name: "Atardecer")
                        sunset.states[.awaiting]?.color = RGB(0x3CB371)
                        SettingsEditing.addTheme(sunset, in: &p)

                        var working = p.appearance(for: .working)
                        working.color = RGB(0x3355FF)
                        p.setAppearance(working, for: .working)
                    }
                }
            ),
            Shot(
                name: "virtualpad", size: virtualPadSize,
                view: AnyView(VirtualPadView(state: VirtualPadState(), pad: VirtualPad()))
            ),
        ]
    }

    /// Draw `view` offscreen at `size` under `appearance` and write it as PNG.
    static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) -> Bool {
        let theme = NSAppearance(named: appearance)
        let content = view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = theme

        // Never ordered front: it exists so the hosting view has a window, a backing
        // scale and an effective appearance, which AppKit controls need to draw.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = theme
        window.contentView = hosting

        var image: NSBitmapImageRep?
        // Draw under the chosen appearance so dynamic colors resolve to it.
        (theme ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            hosting.layoutSubtreeIfNeeded()
            // Let SwiftUI commit its first update and lay out AppKit subviews.
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            image = rep
        }
        window.close()

        guard let image, let data = image.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }
}
