import Foundation

/**
 Everything the user can change, in the file they already have.

 `~/.claude/openboard/config.json` — the **same path and same schema** the Node version
 wrote, so an existing configuration is picked up unchanged. That is not a nicety: this
 machine's file already carries a white `idle` at 0.2, `working` and `awaiting` on
 shallow-breath, `idle_prompt` mapped to `idle`, and `ACT11` explicitly unassigned. A
 rewrite that quietly ignored all of it would look like the app was broken.

 Named `Preferences` rather than `Settings` because SwiftUI owns that name for the
 settings *scene*, and the collision is silent until it is not.

 ## Stored documents are partial, and merged field by field

 The file holds **overrides only** — `lib/config.cjs` deep-merges it over the built-in
 defaults, so a state may specify just `effect` and inherit its color, brightness and
 speed. Anything less granular would turn a one-line override into a half-configured
 state.

 ## Colors are numbers on disk

 The Node version stored `0xRRGGBB` as a JSON number, so `16777215` is white. Hex
 strings are accepted too, because they are what a person types when hand-editing, and
 numbers are written back so the file stays readable by either implementation.
 */
/// Which sessions the six keys show while Superset is in front.
public enum PadScope: String, Equatable, Sendable, CaseIterable {
    /// Only the workspace you are looking at, plus a borrowed key for anything urgent
    /// elsewhere. See `PadView`.
    case focusedWorkspace
    /// Every session on its registry slot — the board before workspaces.
    case all
}

public struct Preferences: Equatable, Sendable {
    public var states: [String: Appearance]
    /// Action key bindings. A key present with `nil` is *explicitly* unassigned, which
    /// is different from a key that is absent and inherits its default.
    public var actionKeys: [String: KeyAction?]
    public var snippets: [String: String]
    /// Chords for keys bound to `.shortcut`, keyed like `snippets` — plus `ENC`,
    /// `ENC.long` and `JOY.up`… for the controls whose bindings share one name.
    public var shortcuts: [String: Shortcut]
    /// Keycap icon per key. New in the app; absent from Node documents, which is fine.
    public var caps: [String: String]
    /**
     What you call your pad, by hardware serial.

     Every Codex Micro reports the same product name, so "Connected to Codex Micro"
     says nothing to someone with two of them — and macOS's own disambiguation is a
     pairing counter, "#1" and "#3", which is about this Mac's pairing history rather
     than about the object.

     Keyed by `kIOHIDSerialNumberKey` because that is the only identifier that belongs
     to the device: it survives re-pairing, moving between machines, and the switch
     between Bluetooth and USB.
     */
    public var deviceNames: [String: String]
    /**
     Harnesses that have ever reported an event, by id.

     Not "connected right now" — that is answerable from the hooks and the process
     table. This is the weaker, more useful question for a settings window: has this
     thing *ever* worked here? A harness that has never sent an event has nothing to
     say about its own behaviour, so the pane shows setup instead of tables describing
     events it has not seen.

     Written the first time one arrives and never cleared. A harness that worked last
     month and is quiet today is set up; it is simply not running.
     */
    public var harnessesSeen: [String]
    public var events: [String: Bool]
    /**
     Which surfaces the board listens to, by `ProcessAncestry.Host` raw value.

     **Absent means listening**, the same rule `events` uses, and for the same reason: a
     document written by an older build knows about fewer surfaces, and a missing key
     that meant "off" would silently stop the board watching a host it had always
     watched. New surfaces therefore arrive switched on, which is what someone who has
     not opened this pane expects.

     Muting a surface is not cosmetic — a session there is refused a key, and one
     already holding a key gives it up. Six keys is a scarce budget, and someone who
     runs an editor terminal all day may simply not want it competing for them.

     Surfaces that never get a key by design (subagents, embedded SDK clients, anything
     remote) are not represented here: there is nothing to turn off.
     */
    public var surfaces: [String: Bool]
    public var notifications: [String: SessionState?]
    public var encoder: Encoder
    public var joystick: Joystick
    public var ambient: Ambient
    public var countdown: Countdown
    public var entrypoints: [String]
    public var scrollLines: Int
    public var staleHours: Int
    public var doneDecaySeconds: Int
    /// Whether a session waiting on you keeps its color until the prompt is answered.
    ///
    /// Replaced `attentionTimeoutSeconds`, which asked how many minutes to wait before
    /// giving up on a prompt — a question with no good answer, about an event that
    /// should not happen. Off restores the old safety net at a fixed 15 minutes.
    public var holdAttention: Bool
    public var maxHoldSeconds: Int
    /// Whether the voice keys drive dictation through the `voice:pushToTalk`
    /// keybinding chord (⌃Y) instead of tapping space. Space is overloaded — with
    /// text in the chat input it types a space instead of starting dictation — and
    /// a bound chord types nothing, ever. Off by default because it only works once
    /// the chord is added to `~/.claude/keybindings.json`.
    public var voiceChord: Bool
    /// Default `focusedWorkspace`. Outside Superset it changes nothing: any other
    /// surface in front shows every session, exactly as before.
    public var padScope: PadScope
    /// The light a workspace switch plays. See `TransitionPlanner`.
    public var workspaceTransition: WorkspaceTransition
    /// Each workspace's transient color. See `WorkspaceColors`.
    public var workspaceIdentity: WorkspaceIdentity
    /// How the borrowed key looks. See `OverflowLook`.
    public var overflow: Overflow
    /// The host-service connection (F3).
    public var superset: Superset
    /**
     Per-app overrides, by bundle id of the app in front (F2).

     Only what a profile names is overridden; everything else inherits the base
     bindings. Their chords live in `shortcuts` under `<key>@<bundle>`.
     */
    public var profiles: [String: AppProfile]
    /// What holding an action cap does, keyed like `actionKeys`. Present with `nil` is
    /// explicitly unassigned; absent inherits the default.
    public var actionKeysLong: [String: KeyAction?]
    /// How long is "held" for an action cap, in milliseconds.
    public var actionLongPressMs: Int
    /// The two-step confirmation window and its light (F4).
    public var confirm: Confirm
    /// Remote sends and interrupts aimed at one agent (F7).
    public var targeted: Targeted
    /// Which agents NEW and the handoff start (F5, F8).
    public var launch: Launch
    /// Let a snippet through even when it looks like a destructive command. Off: the
    /// key that typed `/clear` into the wrong window is why.
    public var snippetsAllowDangerous: Bool
    /// Themes the user saved, duplicated or imported, in the order they were added.
    /// Absent in the file means none. See `CustomTheme` and `ThemeFile`.
    public var customThemes: [CustomTheme]

    public struct Encoder: Equatable, Sendable {
        /// `scroll-up` or `scroll-down`, per direction.
        public var cw: String
        public var cc: String
        public var click: KeyAction?
        /// What holding the dial does. The dial is the one control you reach for
        /// without looking, so it is worth more than a single binding.
        public var longPress: KeyAction?
        /// How long is "held", in milliseconds.
        public var longPressMs: Int

        public init(
            cw: String = "scroll-up",
            cc: String = "scroll-down",
            click: KeyAction? = .popover,
            longPress: KeyAction? = .settings,
            longPressMs: Int = 450
        ) {
            self.cw = cw
            self.cc = cc
            self.click = click
            self.longPress = longPress
            self.longPressMs = longPressMs
        }

        public var longPressInterval: TimeInterval { Double(longPressMs) / 1000 }

        /// The two directions collapsed to the one bit the dispatcher needs.
        ///
        /// Only `cw` is consulted. The schema stores both, but a document setting them
        /// to the same direction describes a dial that scrolls one way whichever way it
        /// is turned — so `cc` is treated as the mirror of `cw` rather than obeyed
        /// literally into a state no one would want.
        public var clockwiseScrollsUp: Bool {
            get { cw != "scroll-down" }
            set {
                cw = newValue ? "scroll-up" : "scroll-down"
                cc = newValue ? "scroll-down" : "scroll-up"
            }
        }
    }

    /// The joystick: four directions, each bindable, plus the orientation needed to
    /// know which reported angle is which physical direction.
    public struct Joystick: Equatable, Sendable {
        public var up: KeyAction?
        public var down: KeyAction?
        public var left: KeyAction?
        public var right: KeyAction?
        /// The angle the stick reports when pushed up. Not guessable from the numbers —
        /// the four cardinals are evenly spaced, so which is "up" is a fact about the
        /// hardware, and getting it wrong swaps the axes.
        public var northAngle: Double
        public var clockwise: Bool
        public var threshold: Double

        public init(
            up: KeyAction? = .arrowUp,
            down: KeyAction? = .arrowDown,
            left: KeyAction? = .tabBack,
            right: KeyAction? = .tabForward,
            northAngle: Double = 0,
            clockwise: Bool = true,
            threshold: Double = 0.5
        ) {
            self.up = up
            self.down = down
            self.left = left
            self.right = right
            self.northAngle = northAngle
            self.clockwise = clockwise
            self.threshold = threshold
        }

        public func action(for direction: OpenBoardKit.Joystick.Direction) -> KeyAction? {
            switch direction {
            case .up: up
            case .down: down
            case .left: left
            case .right: right
            }
        }
    }

    public struct Ambient: Equatable, Sendable {
        /// `events` · `aggregate` · `fixed` · `off`
        public var mode: String
        public var completionLap: Bool
        public var questionLap: Bool
        public var errorPulse: Bool
        /// Spin the ring while dictation is believed to be running. Overrides every
        /// mode, including `off` — see `BoardController.ambientSide`.
        public var voiceRainbow: Bool
        /// What `fixed` mode holds. Without this the mode is documented, selectable and
        /// silently dark — the resolver has nothing to return.
        public var fixed: Appearance

        public init(
            mode: String = "events",
            completionLap: Bool = true,
            questionLap: Bool = true,
            errorPulse: Bool = true,
            voiceRainbow: Bool = true,
            fixed: Appearance = Appearance(
                color: RGB(0x2E4A6B), effect: .solid, brightness: 0.35, speed: 0
            )
        ) {
            self.mode = mode
            self.completionLap = completionLap
            self.questionLap = questionLap
            self.errorPulse = errorPulse
            self.voiceRainbow = voiceRainbow
            self.fixed = fixed
        }
    }

    /**
     The light a Superset workspace switch plays: a sweep on the ring and the keys
     lighting one after another, so the count reads without reading anything.

     An event, not a state — nothing here holds a light after the transition ends. The
     timings are the design (`docs`: "Barrido + recuento"), kept as settings because the
     ring speed in particular still has to be calibrated on the pad.
     */
    public struct WorkspaceTransition: Equatable, Sendable {
        public enum Style: String, Equatable, Sendable, CaseIterable {
            /// The ring sweeps once and the keys count up.
            case sweepCascade = "sweep-cascade"
            /// Every key at once, the ring a brief solid in the workspace color.
            case cut
            /// One write, nothing on the ring.
            case off
        }

        public var style: Style
        /// Honor macOS's Reduce Motion: a switch then paints directly, like `off`.
        public var respectReduceMotion: Bool
        /// A switch superseded within this long plays nothing — cycling through
        /// workspaces with the shortcut only animates where you stop.
        public var debounceMs: Int
        /// A switch this soon after the last transition paints directly.
        public var rapidWindowMs: Int
        public var keyStaggerMs: Int
        public var firstKeyDelayMs: Int
        public var overflowDelayMs: Int
        public var ringSweep: Bool
        /// Calibrate on the pad: the target is about one lap in `ringHoldMs`.
        public var ringSpeed: Double
        public var ringBrightness: Double
        public var ringHoldMs: Int
        public var ringFadeSteps: Int
        public var ringFadeStepMs: Int
        /// The keys still count up inside this window; only the ring sits it out.
        public var minSweepIntervalMs: Int

        public init(
            style: Style = .sweepCascade,
            respectReduceMotion: Bool = true,
            debounceMs: Int = 150,
            rapidWindowMs: Int = 1500,
            keyStaggerMs: Int = 70,
            firstKeyDelayMs: Int = 80,
            overflowDelayMs: Int = 150,
            ringSweep: Bool = true,
            ringSpeed: Double = 0.55,
            ringBrightness: Double = 0.8,
            ringHoldMs: Int = 900,
            ringFadeSteps: Int = 8,
            ringFadeStepMs: Int = 60,
            minSweepIntervalMs: Int = 4000
        ) {
            self.style = style
            self.respectReduceMotion = respectReduceMotion
            self.debounceMs = debounceMs
            self.rapidWindowMs = rapidWindowMs
            self.keyStaggerMs = keyStaggerMs
            self.firstKeyDelayMs = firstKeyDelayMs
            self.overflowDelayMs = overflowDelayMs
            self.ringSweep = ringSweep
            self.ringSpeed = ringSpeed
            self.ringBrightness = ringBrightness
            self.ringHoldMs = ringHoldMs
            self.ringFadeSteps = ringFadeSteps
            self.ringFadeStepMs = ringFadeStepMs
            self.minSweepIntervalMs = minSweepIntervalMs
        }
    }

    /**
     A color per workspace, shown only in passing — the sweep and the borrowed key's
     wink, never held on a key.

     The palette keeps its distance from every state hue: a hash landing on orange
     would read as a prompt. See `WorkspaceColors`.
     */
    public struct WorkspaceIdentity: Equatable, Sendable {
        public static let defaultPalette: [RGB] = [
            RGB(0x9B30FF), // violet
            RGB(0x00C9A7), // turquoise
            RGB(0xB4E600), // lime
            RGB(0xD6E4FF), // cool white
        ]

        public var palette: [RGB]
        /// Workspace id → color, chosen by hand. Wins over the palette.
        public var colors: [String: RGB]

        public init(palette: [RGB] = defaultPalette, colors: [String: RGB] = [:]) {
            self.palette = palette
            self.colors = colors
        }
    }

    /// The key lent to another workspace's urgent session. Still, where every local
    /// key breathes: here "still" means "not from here".
    public struct Overflow: Equatable, Sendable {
        public var enabled: Bool
        public var effect: LEDEffect
        public var brightness: Double
        public var winkEveryMs: Int
        public var winkMs: Int
        /// Flash the origin workspace's color now and then, so the key says where.
        public var winkOriginColor: Bool

        public init(
            enabled: Bool = true,
            effect: LEDEffect = .solid,
            brightness: Double = 0.6,
            winkEveryMs: Int = 3000,
            winkMs: Int = 250,
            winkOriginColor: Bool = true
        ) {
            self.enabled = enabled
            self.effect = effect
            self.brightness = brightness
            self.winkEveryMs = winkEveryMs
            self.winkMs = winkMs
            self.winkOriginColor = winkOriginColor
        }
    }

    /// The host-service client. Defaults: Plan §2.5; D8 for the mismatch policy.
    public struct Superset: Equatable, Sendable {
        public enum HostClient: String, Equatable, Sendable, CaseIterable {
            /// Use the host-service whenever a manifest is found.
            case auto
            /// Hooks and deep links only, as before F3.
            case off
        }

        /// What a Superset version other than the tested one gets.
        public enum MismatchPolicy: String, Equatable, Sendable, CaseIterable {
            /// Queries only, until someone has looked. D8.
            case readOnly = "read-only"
            case full
        }

        public var hostClient: HostClient
        /// `nil` means the one org under `~/.superset/host` with a manifest. Only the
        /// id is ever stored here — never the token.
        public var orgID: String?
        public var testedVersion: String
        public var onVersionMismatch: MismatchPolicy
        /// Subscribe to `/events`.
        public var events: Bool
        /// `Start` arrives on every tool use; this groups them.
        public var startDebounceMs: Int
        /// The same event from our hook and from the bus counts once inside this.
        public var dedupeWindowMs: Int
        /// At most one pad write per window.
        public var padWriteCoalesceMs: Int
        public var reconcileOnLaunch: Bool

        public init(
            hostClient: HostClient = .auto,
            orgID: String? = nil,
            testedVersion: String = "1.30.0",
            onVersionMismatch: MismatchPolicy = .readOnly,
            events: Bool = true,
            startDebounceMs: Int = 200,
            dedupeWindowMs: Int = 1500,
            padWriteCoalesceMs: Int = 90,
            reconcileOnLaunch: Bool = true
        ) {
            self.hostClient = hostClient
            self.orgID = orgID
            self.testedVersion = testedVersion
            self.onVersionMismatch = onVersionMismatch
            self.events = events
            self.startDebounceMs = startDebounceMs
            self.dedupeWindowMs = dedupeWindowMs
            self.padWriteCoalesceMs = padWriteCoalesceMs
            self.reconcileOnLaunch = reconcileOnLaunch
        }
    }

    /**
     One app's overrides.

     Three levels of "nothing", and all three mean something: a direction absent from
     `joystick` inherits the base binding, one present with `nil` is explicitly
     unbound in this app, and one present with an action overrides. `encoderLongPress`
     is the same thing for a single value, hence the double optional.
     */
    public struct AppProfile: Equatable, Sendable {
        public var joystick: [OpenBoardKit.Joystick.Direction: KeyAction?]
        public var encoderLongPress: KeyAction??
        public var actionKeysLong: [String: KeyAction?]

        public init(
            joystick: [OpenBoardKit.Joystick.Direction: KeyAction?] = [:],
            encoderLongPress: KeyAction?? = nil,
            actionKeysLong: [String: KeyAction?] = [:]
        ) {
            self.joystick = joystick
            self.encoderLongPress = encoderLongPress
            self.actionKeysLong = actionKeysLong
        }
    }

    /// The "are you sure?" light. White, not amber: amber already means a session is
    /// waiting on you (D3).
    public struct Confirm: Equatable, Sendable {
        public var windowMs: Int
        public var color: RGB
        public var effect: LEDEffect
        public var brightness: Double

        public init(
            windowMs: Int = 3000,
            color: RGB = RGB(0xFFFFFF),
            effect: LEDEffect = .breath,
            brightness: Double = 0.8
        ) {
            self.windowMs = windowMs
            self.color = color
            self.effect = effect
            self.brightness = brightness
        }
    }

    public struct Targeted: Equatable, Sendable {
        /// How a remote send is aimed. D10.
        public enum Mode: String, Equatable, Sendable, CaseIterable {
            /// FAST held arms it, REJ turns it into an interrupt, an agent key fires it
            /// without jumping.
            case armed
            /// Hold an agent key and press REJ or FAST. Delays every jump to the
            /// release, so it is not the default.
            case chord
        }

        public var mode: Mode
        /// How long an armed send waits for its agent key.
        public var windowMs: Int
        public var snapshotLines: Int
        /// A send goes only to an agent that has stopped. Shown locked in the UI: a
        /// safety rule, not a preference.
        public var requireStopForSend: Bool
        public var maxSendBytes: Int
        public var defaultSnippet: String
        /// Extra named snippets. D6: none by default.
        public var snippets: [String: String]

        public init(
            mode: Mode = .armed,
            windowMs: Int = 3000,
            snapshotLines: Int = 20,
            requireStopForSend: Bool = true,
            maxSendBytes: Int = 4096,
            defaultSnippet: String = "sigue",
            snippets: [String: String] = [:]
        ) {
            self.mode = mode
            self.windowMs = windowMs
            self.snapshotLines = snapshotLines
            self.requireStopForSend = requireStopForSend
            self.maxSendBytes = maxSendBytes
            self.defaultSnippet = defaultSnippet
            self.snippets = snippets
        }
    }

    public struct Launch: Equatable, Sendable {
        /// `claude`, `codex`, or a preset UUID from Superset's agent configs.
        public var newAgent: String
        public var handoffAgent: String
        /// `nil` until the host-service's own maximum has been verified.
        public var handoffContextChars: Int?
        /// A second NEW inside this is dropped (D2: debounce, no confirmation).
        public var createCooldownMs: Int

        public init(
            newAgent: String = "claude",
            handoffAgent: String = "codex",
            handoffContextChars: Int? = nil,
            createCooldownMs: Int = 2000
        ) {
            self.newAgent = newAgent
            self.handoffAgent = handoffAgent
            self.handoffContextChars = handoffContextChars
            self.createCooldownMs = createCooldownMs
        }
    }

    public struct Countdown: Equatable, Sendable {
        /// Fires each cue early, to cancel a ~86ms ring write plus audio latency.
        public var leadMs: Int
        public var introFlashSec: Double
        public var introFlashColor: RGB
        /// The pre-flash countdown bar on the keys.
        ///
        /// Cold and dim on purpose: it has to build toward the flash and then lose to
        /// it, so it must never approach the reveal's brightness or its hue.
        public var introEnabled: Bool
        public var introColorKeys: RGB
        public var introBrightness: Double
        public var introTrail: Double
        /// Lifts every brightness in the show for a lit room. See `Countdown.lift` for
        /// why this is a gamma curve and not a multiplier.
        ///
        /// No longer has a control. It was a slider nobody moves twice — the answer is
        /// "bright enough for the room you are in", which is one decision per room, not
        /// per viewing. Fixed at the value this pad was tuned to, and still readable
        /// from `config.json` for a genuinely darker or brighter one.
        public var gain: Double
        /// Where the video and its analysis live. Empty means "work it out" — beside
        /// the app, then the source tree it was built from.
        public var mediaDir: String

        public init(
            leadMs: Int = 70,
            introFlashSec: Double = 13.2,
            introFlashColor: RGB = RGB(0xFF2D95),
            introEnabled: Bool = true,
            introColorKeys: RGB = RGB(0x1B2A6B),
            // 0.6, matching `Countdown.introFrame`'s own default and the reasoning in
            // its comment. This shipped as 0.3 — the value lib/countdown.cjs passed —
            // and at 0.3 the bar renders *backwards* on offbeats: the leading key is
            // 0.3 x 0.6 = 0.18 against a 0.2 trail, so the front edge is dimmer than
            // its own tail on half the frames. At 0.6 the lead, the trail and the empty
            // keys land in three different `step()` buckets on every frame.
            introBrightness: Double = 0.6,
            introTrail: Double = 0.2,
            // 2, not the authored 1. The show is watched in a lit room with the pad an
            // arm's length away, and at 1 the quiet passages are invisible from there.
            // The curve is what makes this safe to raise: it lifts the quiet end without
            // crushing the loud one, so the dynamics survive. See `Countdown.lift`.
            gain: Double = 2,
            mediaDir: String = ""
        ) {
            self.leadMs = leadMs
            self.introFlashSec = introFlashSec
            self.introFlashColor = introFlashColor
            self.introEnabled = introEnabled
            self.introColorKeys = introColorKeys
            self.introBrightness = introBrightness
            self.introTrail = introTrail
            self.gain = gain
            self.mediaDir = mediaDir
        }
    }

    /// The look of a session restored from disk and not yet confirmed by Superset. A
    /// flag on the entry rather than a `SessionState` (D11), so it is keyed by name.
    public static let unconfirmedKey = "unconfirmed"
    public static let unconfirmedDefault = Appearance(
        color: RGB(0x2E4A6B), effect: .solid, brightness: 0.3, speed: 0
    )

    /// The Superset desktop app, whose profile ships built in.
    public static let supersetBundleID = "com.superset.desktop"

    /**
     Superset's own shortcuts, bound in its profile (Plan §2.6): workspaces on ⌘⌥↑↓,
     tabs on ⌘⌥←→, the command palette on ⌘⇧K, the diff viewer on ⌘⇧L and quick
     workspace creation on ⌘⇧N. Editable, because Superset lets people remap them.
     */
    public static let supersetShortcuts: [String: Shortcut] = {
        let b = supersetBundleID
        return [
            "JOY.up@\(b)": Shortcut(keyCode: 126, modifiers: [.command, .option], key: "↑"),
            "JOY.down@\(b)": Shortcut(keyCode: 125, modifiers: [.command, .option], key: "↓"),
            "JOY.left@\(b)": Shortcut(keyCode: 123, modifiers: [.command, .option], key: "←"),
            "JOY.right@\(b)": Shortcut(keyCode: 124, modifiers: [.command, .option], key: "→"),
            "ENC.long@\(b)": Shortcut(keyCode: 40, modifiers: [.command, .shift], key: "K"),
            "ACT09.long@\(b)": Shortcut(keyCode: 37, modifiers: [.command, .shift], key: "L"),
            "ACT11.long@\(b)": Shortcut(keyCode: 45, modifiers: [.command, .shift], key: "N"),
        ]
    }()

    /**
     The clone's caps (FAST APPR REJ BRANCH MIC NEW CODEX), not the upstream layout of
     `KeyAction.defaults`: this fork is for that pad, and the long presses below are
     written for these caps — holding APPR must land on the cap that approves.

     D1: NEW and CODEX ship explicitly unassigned. ACT11 typed `/clear` and ACT12 sent
     ⏎ into whatever was in front, and together they cleared a session.
     */
    public static let cloneActionKeys: [String: KeyAction?] = [
        "ACT06": .shortcut,
        "ACT07": .approve,
        "ACT08": .reject,
        "ACT09": .nextSession,
        "ACT10": .voiceTalk,
        "ACT11": KeyAction?.none,
        "ACT12": KeyAction?.none,
        "ENC": KeyAction.defaults["ENC"],
    ]

    /// FAST's tap: ⇧⇥, Claude Code's permission-mode toggle. Reversible, so safe on a key.
    public static let fastShortcut = Shortcut(keyCode: 48, modifiers: [.shift], key: "⇥")

    public static let `default` = Preferences(
        states: Dictionary(
            uniqueKeysWithValues: SessionState.allCases.map { ($0.rawValue, $0.defaultAppearance) }
        ).merging([unconfirmedKey: unconfirmedDefault]) { old, _ in old },
        actionKeys: cloneActionKeys,
        // No default key types a snippet, so none ships.
        snippets: [:],
        shortcuts: supersetShortcuts.merging(["ACT06": fastShortcut]) { old, _ in old },
        caps: KeycapCatalog.defaultCaps,
        deviceNames: [:],
        harnessesSeen: [],
        events: [:],
        surfaces: [:],
        notifications: EventMapper.defaultNotifications.mapValues { Optional($0) },
        encoder: Encoder(),
        joystick: Joystick(),
        ambient: Ambient(),
        countdown: Countdown(),
        entrypoints: Array(Eligibility.defaultEntrypoints).sorted(),
        scrollLines: 3,
        staleHours: 12,
        // 0 means never: green holds until you go back to that session and send
        // something. See SessionRegistry.decay.
        doneDecaySeconds: 0,
        holdAttention: true,
        maxHoldSeconds: 60,
        profiles: [
            supersetBundleID: AppProfile(
                joystick: Dictionary(
                    uniqueKeysWithValues: OpenBoardKit.Joystick.Direction.allCases.map { ($0, KeyAction?.some(.shortcut)) }
                ),
                encoderLongPress: .some(.shortcut)
            ),
        ],
        // D7: APPR held jumps to whoever has waited longest. D4/D10: FAST held arms
        // the targeted mode. Keyed by the clone's caps — see `cloneActionKeys`.
        actionKeysLong: [
            "ACT06": .targetedArm,
            // F8: CODEX held hands the focused terminal off to `launch.handoffAgent`.
            "ACT12": .supersetHandoff,
            "ACT07": .jumpOldestWaiting,
            "ACT08": .interruptFocused,
            "ACT09": .shortcut,
            "ACT11": .shortcut,
        ]
    )

    public init(
        states: [String: Appearance],
        actionKeys: [String: KeyAction?],
        snippets: [String: String],
        shortcuts: [String: Shortcut] = [:],
        caps: [String: String],
        deviceNames: [String: String] = [:],
        harnessesSeen: [String] = [],
        events: [String: Bool],
        surfaces: [String: Bool] = [:],
        notifications: [String: SessionState?],
        encoder: Encoder,
        joystick: Joystick,
        ambient: Ambient,
        countdown: Countdown,
        entrypoints: [String],
        scrollLines: Int,
        staleHours: Int,
        doneDecaySeconds: Int,
        holdAttention: Bool = true,
        maxHoldSeconds: Int,
        voiceChord: Bool = false,
        padScope: PadScope = .focusedWorkspace,
        workspaceTransition: WorkspaceTransition = WorkspaceTransition(),
        workspaceIdentity: WorkspaceIdentity = WorkspaceIdentity(),
        overflow: Overflow = Overflow(),
        superset: Superset = Superset(),
        profiles: [String: AppProfile] = [:],
        actionKeysLong: [String: KeyAction?] = [:],
        actionLongPressMs: Int = 500,
        confirm: Confirm = Confirm(),
        targeted: Targeted = Targeted(),
        launch: Launch = Launch(),
        snippetsAllowDangerous: Bool = false,
        customThemes: [CustomTheme] = []
    ) {
        self.states = states
        self.actionKeys = actionKeys
        self.snippets = snippets
        self.shortcuts = shortcuts
        self.caps = caps
        self.deviceNames = deviceNames
        self.harnessesSeen = harnessesSeen
        self.events = events
        self.surfaces = surfaces
        self.notifications = notifications
        self.encoder = encoder
        self.joystick = joystick
        self.ambient = ambient
        self.countdown = countdown
        self.entrypoints = entrypoints
        self.scrollLines = scrollLines
        self.staleHours = staleHours
        self.doneDecaySeconds = doneDecaySeconds
        self.holdAttention = holdAttention
        self.maxHoldSeconds = maxHoldSeconds
        self.voiceChord = voiceChord
        self.padScope = padScope
        self.workspaceTransition = workspaceTransition
        self.workspaceIdentity = workspaceIdentity
        self.overflow = overflow
        self.superset = superset
        self.profiles = profiles
        self.actionKeysLong = actionKeysLong
        self.actionLongPressMs = actionLongPressMs
        self.confirm = confirm
        self.targeted = targeted
        self.launch = launch
        self.snippetsAllowDangerous = snippetsAllowDangerous
        self.customThemes = customThemes
    }

    // MARK: - typed accessors

    public func appearance(for state: SessionState) -> Appearance {
        states[state.rawValue] ?? state.defaultAppearance
    }

    public mutating func setAppearance(_ appearance: Appearance, for state: SessionState) {
        states[state.rawValue] = appearance
    }

    /// Bindings that are actually set. An explicit `nil` drops out here, which is what
    /// "unassigned" means to a caller looking one up.
    public var keyActions: [String: KeyAction] {
        actionKeys.compactMapValues { $0 }
    }

    /// `states["unconfirmed"]`, or its default. See `unconfirmedKey`.
    public var unconfirmedAppearance: Appearance {
        states[Self.unconfirmedKey] ?? Self.unconfirmedDefault
    }

    /// Long-press bindings that are actually set, like `keyActions`.
    public var keyActionsLong: [String: KeyAction] {
        actionKeysLong.compactMapValues { $0 }
    }

    public var notificationStates: [String: SessionState] {
        notifications.compactMapValues { $0 }
    }

    public var staleInterval: TimeInterval { TimeInterval(staleHours) * 3600 }

    /**
     Whether a session hosted by this app may hold a key.

     Absent means yes — see `surfaces`. `.unknown` is always yes and is deliberately not
     offered in the UI: a session whose host could not be identified is still a real
     session someone is sitting in front of, and a switch that silently covered
     "everything I could not name" would be the opposite of the fail-closed rule it
     looks like.
     */
    public func listens(to host: ProcessAncestry.Host) -> Bool {
        guard host != .unknown else { return true }
        return surfaces[host.rawValue] ?? true
    }
}

// MARK: - JSON, in the Node document's shape

extension Preferences {
    /**
     Merge a stored document over the defaults, field by field.

     Mirrors `lib/config.cjs`'s `deepMerge`: a nested object merges into its default
     rather than replacing it, so `{"states":{"working":{"effect":"shallow-breath"}}}`
     keeps working's color, brightness and speed.
     */
    public static func merging(
        _ json: [String: Any],
        over base: Preferences = .default
    ) -> Preferences {
        var result = base

        if let states = json["states"] as? [String: Any] {
            for (name, raw) in states {
                // Known states, plus the one look that is not a state (D11). Anything
                // else is a typo, and keeping it would only be carried around forever.
                guard let fields = raw as? [String: Any],
                      let fallback = SessionState(rawValue: name)?.defaultAppearance
                        ?? (name == unconfirmedKey ? unconfirmedDefault : nil)
                else { continue }
                var appearance = result.states[name] ?? fallback
                if let color = parseColor(fields["color"]) { appearance.color = color }
                if let effect = fields["effect"] as? String,
                   let parsed = LEDEffect(rawValue: effect) { appearance.effect = parsed }
                if let brightness = fields["brightness"] as? Double {
                    appearance.brightness = min(max(brightness, 0), 1)
                }
                if let speed = fields["speed"] as? Double {
                    appearance.speed = min(max(speed, 0), 1)
                }
                result.states[name] = appearance
            }
        }

        if let keys = json["actionKeys"] as? [String: Any] {
            for (key, raw) in keys {
                // `null` is an explicit unassign and must survive as one, or the key
                // silently reverts to its default on the next launch.
                if raw is NSNull { result.actionKeys[key] = KeyAction?.none; continue }
                guard let name = raw as? String,
                      let action = KeyAction(rawValue: name) else { continue }
                result.actionKeys[key] = action
            }
        }

        if let snippets = json["snippets"] as? [String: String] {
            result.snippets.merge(snippets) { _, new in new }
        }
        if let shortcuts = json["shortcuts"] as? [String: Any] {
            // An entry without a key code is skipped, not fatal — like an unknown
            // action name in `actionKeys`.
            for (key, raw) in shortcuts {
                // `null` removes one — the way a built-in Superset chord stays deleted.
                if raw is NSNull { result.shortcuts[key] = nil; continue }
                guard let fields = raw as? [String: Any],
                      let shortcut = Shortcut(json: fields) else { continue }
                result.shortcuts[key] = shortcut
            }
        }
        if let caps = json["caps"] as? [String: String] {
            result.caps.merge(caps) { _, new in new }
        }
        if let names = json["deviceNames"] as? [String: String] {
            result.deviceNames.merge(names) { _, new in new }
        }
        if let seen = json["harnessesSeen"] as? [String] {
            // Merged rather than replaced, like everything else here: a document
            // written by an older build knows about fewer harnesses, and forgetting one
            // would put a working harness back into its empty state.
            result.harnessesSeen = Array(Set(result.harnessesSeen).union(seen)).sorted()
        }
        if let events = json["events"] as? [String: Bool] {
            result.events.merge(events) { _, new in new }
        }
        // Merged, not replaced: see `surfaces` — an older document naming fewer hosts
        // must not switch off the ones it never knew about.
        if let surfaces = json["surfaces"] as? [String: Bool] {
            result.surfaces.merge(surfaces) { _, new in new }
        }

        if let notifications = json["notifications"] as? [String: Any] {
            for (kind, raw) in notifications {
                if raw is NSNull { result.notifications[kind] = SessionState?.none; continue }
                guard let name = raw as? String,
                      let state = SessionState(rawValue: name) else { continue }
                result.notifications[kind] = state
            }
        }

        if let encoder = json["encoder"] as? [String: Any] {
            if let cw = encoder["cw"] as? String { result.encoder.cw = cw }
            if let cc = encoder["cc"] as? String { result.encoder.cc = cc }
            if encoder["click"] is NSNull {
                result.encoder.click = nil
            } else if let click = encoder["click"] as? String {
                result.encoder.click = KeyAction(rawValue: click)
            }
            if encoder["longPress"] is NSNull {
                result.encoder.longPress = nil
            } else if let long = encoder["longPress"] as? String {
                result.encoder.longPress = KeyAction(rawValue: long)
            }
            if let ms = encoder["longPressMs"] as? Int {
                // Bounded: below ~150ms an ordinary click trips it, and above a couple
                // of seconds the hold feels like the app has hung.
                result.encoder.longPressMs = min(2000, max(150, ms))
            }
        }

        if let stick = json["joystick"] as? [String: Any] {
            for (name, path) in [
                ("up", \Joystick.up), ("down", \Joystick.down),
                ("left", \Joystick.left), ("right", \Joystick.right),
            ] as [(String, WritableKeyPath<Joystick, KeyAction?>)] {
                if stick[name] is NSNull {
                    result.joystick[keyPath: path] = nil
                } else if let raw = stick[name] as? String {
                    result.joystick[keyPath: path] = KeyAction(rawValue: raw)
                }
            }
            if let angle = stick["northAngle"] as? Double {
                result.joystick.northAngle = angle
            }
            if let cw = stick["clockwise"] as? Bool { result.joystick.clockwise = cw }
            if let t = stick["threshold"] as? Double {
                result.joystick.threshold = min(0.95, max(0.1, t))
            }
        }

        if let ambient = json["ambient"] as? [String: Any] {
            if let mode = ambient["mode"] as? String { result.ambient.mode = mode }
            if let lap = ambient["completionLap"] as? Bool { result.ambient.completionLap = lap }
            if let lap = ambient["questionLap"] as? Bool { result.ambient.questionLap = lap }
            if let pulse = ambient["errorPulse"] as? Bool { result.ambient.errorPulse = pulse }
            if let spin = ambient["voiceRainbow"] as? Bool { result.ambient.voiceRainbow = spin }
            // Same partial-override rule as a state: a document naming only the color
            // keeps the default effect and brightness.
            if let fields = ambient["fixed"] as? [String: Any] {
                if let color = parseColor(fields["color"]) { result.ambient.fixed.color = color }
                if let effect = fields["effect"] as? String,
                   let parsed = LEDEffect(rawValue: effect) { result.ambient.fixed.effect = parsed }
                if let value = fields["brightness"] as? Double {
                    result.ambient.fixed.brightness = value
                }
                if let value = fields["speed"] as? Double { result.ambient.fixed.speed = value }
            }
        }

        if let countdown = json["countdown"] as? [String: Any] {
            if let lead = countdown["leadMs"] as? Int { result.countdown.leadMs = lead }
            if let sec = countdown["introFlashSec"] as? Double {
                result.countdown.introFlashSec = sec
            }
            if let color = parseColor(countdown["introFlashColor"]) {
                result.countdown.introFlashColor = color
            }
            // Clamped on the way in: a stored 0 would blank the entire show, and a
            // hand-edited 20 would flatten it to maximum on every beat.
            if let value = countdown["gain"] as? Double, value > 0 {
                result.countdown.gain = min(4, max(0.25, value))
            }
            // Nested one level down, matching lib/countdown.cjs's `cfg.intro`.
            if let intro = countdown["intro"] as? [String: Any] {
                if let enabled = intro["enabled"] as? Bool { result.countdown.introEnabled = enabled }
                if let color = parseColor(intro["color"]) { result.countdown.introColorKeys = color }
                if let value = intro["brightness"] as? Double {
                    result.countdown.introBrightness = value
                }
                if let value = intro["trail"] as? Double { result.countdown.introTrail = value }
            }
            if let dir = countdown["mediaDir"] as? String {
                result.countdown.mediaDir = dir
            }
        }

        if let entrypoints = json["entrypoints"] as? [String] { result.entrypoints = entrypoints }
        if let value = json["scrollLines"] as? Int { result.scrollLines = value }
        if let value = json["staleHours"] as? Int { result.staleHours = value }
        if let value = json["doneDecaySeconds"] as? Int { result.doneDecaySeconds = value }
        if let value = json["holdAttention"] as? Bool { result.holdAttention = value }
        /*
         An old document's timeout, read as the decision it encoded.

         Only a value that *differs* from the old shipped default is one. Almost every
         existing file carries 900 because that is what was written on first launch, not
         because anyone chose it — migrating those to "expire" would hand the entire
         installed base the opposite of the new behaviour on the strength of a number
         they never typed. 0 already meant never expire.
        */
        let oldDefault = 900
        if json["holdAttention"] == nil, let legacy = json["attentionTimeoutSeconds"] as? Int {
            result.holdAttention = legacy <= 0 || legacy == oldDefault
        }
        if let value = json["maxHoldSeconds"] as? Int { result.maxHoldSeconds = value }
        if let value = json["voiceChord"] as? Bool { result.voiceChord = value }
        if let raw = json["padScope"] as? String, let value = PadScope(rawValue: raw) {
            result.padScope = value
        }
        mergeWorkspace(json, into: &result)
        mergeSuperset(json, into: &result)

        return result
    }

    /// An action name, `null` as an explicit unassign, and anything else as absent.
    private static func bindingValue(_ raw: Any?) -> KeyAction?? {
        if raw is NSNull { return .some(nil) }
        guard let name = raw as? String, let action = KeyAction(rawValue: name) else { return nil }
        return .some(action)
    }

    private static func bindingJSON(_ value: KeyAction?) -> Any { value?.rawValue ?? NSNull() }

    /// The Superset groups (Plan §2.5), field by field. Clamped where a value would
    /// break the thing it times; the ranges match the settings window's controls.
    private static func mergeSuperset(_ json: [String: Any], into result: inout Preferences) {
        func int(_ raw: Any?, _ range: ClosedRange<Int>) -> Int? {
            (raw as? Int).map { min(max($0, range.lowerBound), range.upperBound) }
        }
        func unit(_ raw: Any?) -> Double? {
            (raw as? NSNumber).map { min(max($0.doubleValue, 0), 1) }
        }

        if let fields = json["superset"] as? [String: Any] {
            var s = result.superset
            if let raw = fields["hostClient"] as? String, let value = Superset.HostClient(rawValue: raw) {
                s.hostClient = value
            }
            if fields["orgId"] is NSNull {
                s.orgID = nil
            } else if let value = fields["orgId"] as? String {
                s.orgID = value.isEmpty ? nil : value
            }
            if let value = fields["testedVersion"] as? String, !value.isEmpty { s.testedVersion = value }
            // Unknown policy text is ignored, never read as `full`.
            if let raw = fields["onVersionMismatch"] as? String,
               let value = Superset.MismatchPolicy(rawValue: raw) { s.onVersionMismatch = value }
            if let value = fields["events"] as? Bool { s.events = value }
            if let value = int(fields["startDebounceMs"], 0...5000) { s.startDebounceMs = value }
            if let value = int(fields["dedupeWindowMs"], 0...10000) { s.dedupeWindowMs = value }
            if let value = int(fields["padWriteCoalesceMs"], 0...1000) { s.padWriteCoalesceMs = value }
            if let value = fields["reconcileOnLaunch"] as? Bool { s.reconcileOnLaunch = value }
            result.superset = s
        }

        if let profiles = json["profiles"] as? [String: Any] {
            for (bundle, raw) in profiles {
                // `null` deletes one, so a removed built-in profile stays removed.
                if raw is NSNull { result.profiles[bundle] = nil; continue }
                guard let fields = raw as? [String: Any] else { continue }
                // Replaced, not merged over the built-in one: inside a profile, absent
                // means "inherit the base binding", so a merge could never express
                // "stop overriding this direction" — it would come back on every launch.
                var profile = AppProfile()
                if let stick = fields["joystick"] as? [String: Any] {
                    for direction in OpenBoardKit.Joystick.Direction.allCases {
                        if let value = bindingValue(stick[direction.rawValue]) {
                            profile.joystick[direction] = value
                        }
                    }
                }
                if let encoder = fields["encoder"] as? [String: Any],
                   let value = bindingValue(encoder["longPress"]) {
                    profile.encoderLongPress = value
                }
                if let keys = fields["actionKeysLong"] as? [String: Any] {
                    for (key, raw) in keys {
                        if let value = bindingValue(raw) { profile.actionKeysLong[key] = value }
                    }
                }
                result.profiles[bundle] = profile
            }
        }

        if let keys = json["actionKeysLong"] as? [String: Any] {
            for (key, raw) in keys {
                if let value = bindingValue(raw) { result.actionKeysLong[key] = value }
            }
        }
        if let value = int(json["actionLongPressMs"], 250...1500) { result.actionLongPressMs = value }

        if let fields = json["confirm"] as? [String: Any] {
            var c = result.confirm
            if let value = int(fields["windowMs"], 1000...10000) { c.windowMs = value }
            if let color = parseColor(fields["color"]) { c.color = color }
            if let raw = fields["effect"] as? String, let effect = LEDEffect(rawValue: raw) { c.effect = effect }
            if let value = unit(fields["brightness"]) { c.brightness = value }
            result.confirm = c
        }

        if let fields = json["targeted"] as? [String: Any] {
            var t = result.targeted
            if let raw = fields["mode"] as? String, let mode = Targeted.Mode(rawValue: raw) { t.mode = mode }
            if let value = int(fields["windowMs"], 500...10000) { t.windowMs = value }
            if let value = int(fields["snapshotLines"], 1...200) { t.snapshotLines = value }
            if let value = fields["requireStopForSend"] as? Bool { t.requireStopForSend = value }
            if let value = int(fields["maxSendBytes"], 1...16384) { t.maxSendBytes = value }
            if let value = fields["defaultSnippet"] as? String { t.defaultSnippet = value }
            if let raw = fields["snippets"] as? [String: Any] {
                for (name, value) in raw {
                    if value is NSNull { t.snippets[name] = nil; continue }
                    if let text = value as? String { t.snippets[name] = text }
                }
            }
            result.targeted = t
        }

        if let fields = json["launch"] as? [String: Any] {
            var l = result.launch
            if let value = fields["newAgent"] as? String, !value.isEmpty { l.newAgent = value }
            if let value = fields["handoffAgent"] as? String, !value.isEmpty { l.handoffAgent = value }
            if fields["handoffContextChars"] is NSNull {
                l.handoffContextChars = nil
            } else if let value = int(fields["handoffContextChars"], 1...1_000_000) {
                l.handoffContextChars = value
            }
            if let value = int(fields["createCooldownMs"], 0...60000) { l.createCooldownMs = value }
            result.launch = l
        }

        // A real boolean only: a hand-typed "true" string does not unlock it.
        if let value = json["snippetsAllowDangerous"] as? Bool {
            result.snippetsAllowDangerous = value
        }

        // Replaced, not merged: the list is the user's, in their order. An entry that
        // does not decode is dropped on its own rather than costing the others.
        if let raw = json["customThemes"] as? [Any] {
            result.customThemes = raw.compactMap { ($0 as? [String: Any]).flatMap(ThemeFile.custom(fromEntry:)) }
        }
    }

    /// The three workspace groups, field by field like every other group. Timings are
    /// clamped to what the transition can survive: a negative delay is a crash in
    /// `Task.sleep`, and a zero fade step count is a sweep that never ends.
    private static func mergeWorkspace(_ json: [String: Any], into result: inout Preferences) {
        func int(_ raw: Any?, _ range: ClosedRange<Int>) -> Int? {
            (raw as? Int).map { min(max($0, range.lowerBound), range.upperBound) }
        }
        func unit(_ raw: Any?) -> Double? {
            (raw as? NSNumber).map { min(max($0.doubleValue, 0), 1) }
        }

        if let fields = json["workspaceTransition"] as? [String: Any] {
            var t = result.workspaceTransition
            // An unknown style is ignored rather than guessed — "wave" was designed and
            // not built, and must not silently mean "off".
            if let raw = fields["style"] as? String, let style = WorkspaceTransition.Style(rawValue: raw) {
                t.style = style
            }
            if let value = fields["respectReduceMotion"] as? Bool { t.respectReduceMotion = value }
            if let value = int(fields["debounceMs"], 0...2000) { t.debounceMs = value }
            if let value = int(fields["rapidWindowMs"], 0...10000) { t.rapidWindowMs = value }
            if let value = int(fields["keyStaggerMs"], 0...1000) { t.keyStaggerMs = value }
            if let value = int(fields["firstKeyDelayMs"], 0...1000) { t.firstKeyDelayMs = value }
            if let value = int(fields["overflowDelayMs"], 0...1000) { t.overflowDelayMs = value }
            if let value = fields["ringSweep"] as? Bool { t.ringSweep = value }
            if let value = unit(fields["ringSpeed"]) { t.ringSpeed = value }
            if let value = unit(fields["ringBrightness"]) { t.ringBrightness = value }
            if let value = int(fields["ringHoldMs"], 0...5000) { t.ringHoldMs = value }
            if let value = int(fields["ringFadeSteps"], 1...20) { t.ringFadeSteps = value }
            if let value = int(fields["ringFadeStepMs"], 10...500) { t.ringFadeStepMs = value }
            if let value = int(fields["minSweepIntervalMs"], 0...60000) { t.minSweepIntervalMs = value }
            result.workspaceTransition = t
        }

        if let fields = json["workspaceIdentity"] as? [String: Any] {
            // Replaced, not merged: a palette is an ordered list, and merging two would
            // move every workspace's color.
            if let raw = fields["palette"] as? [Any] {
                let palette = raw.compactMap(parseColor)
                if !palette.isEmpty { result.workspaceIdentity.palette = palette }
            }
            if let raw = fields["colors"] as? [String: Any] {
                for (id, value) in raw {
                    if value is NSNull { result.workspaceIdentity.colors[id] = nil; continue }
                    if let color = parseColor(value) { result.workspaceIdentity.colors[id] = color }
                }
            }
        }

        if let fields = json["overflow"] as? [String: Any] {
            var o = result.overflow
            if let value = fields["enabled"] as? Bool { o.enabled = value }
            if let raw = fields["effect"] as? String, let effect = LEDEffect(rawValue: raw) {
                o.effect = effect
            }
            if let value = unit(fields["brightness"]) { o.brightness = value }
            if let value = int(fields["winkEveryMs"], 500...60000) { o.winkEveryMs = value }
            if let value = int(fields["winkMs"], 50...2000) { o.winkMs = value }
            if let value = fields["winkOriginColor"] as? Bool { o.winkOriginColor = value }
            result.overflow = o
        }
    }

    /// A color is a packed number on disk, but a hand-editor reaches for hex.
    private static func parseColor(_ raw: Any?) -> RGB? {
        if raw is NSNull { return nil }
        if let number = raw as? NSNumber {
            let value = number.intValue
            guard value >= 0, value <= 0xFF_FFFF else { return nil }
            return RGB(UInt32(value))
        }
        if let text = raw as? String { return RGB(hex: text) }
        return nil
    }

    /// The document to write. Numbers for colors, matching what Node wrote, so the
    /// file stays readable by either implementation.
    public var json: [String: Any] {
        var states: [String: Any] = [:]
        for (name, appearance) in self.states {
            states[name] = [
                "color": Int(appearance.color.value),
                "effect": appearance.effect.rawValue,
                "brightness": appearance.brightness,
                "speed": appearance.speed,
            ]
        }

        var keys: [String: Any] = [:]
        for (key, action) in actionKeys { keys[key] = action?.rawValue ?? NSNull() }

        var notifications: [String: Any] = [:]
        for (kind, state) in self.notifications {
            notifications[kind] = state?.rawValue ?? NSNull()
        }

        return [
            "states": states,
            "actionKeys": keys,
            "snippets": snippets,
            "shortcuts": shortcutsJSON,
            "caps": caps,
            "deviceNames": deviceNames,
            "harnessesSeen": harnessesSeen,
            "events": events,
            "surfaces": surfaces,
            "notifications": notifications,
            "encoder": [
                "cw": encoder.cw,
                "cc": encoder.cc,
                "click": encoder.click?.rawValue ?? NSNull(),
                "longPress": encoder.longPress?.rawValue ?? NSNull(),
                "longPressMs": encoder.longPressMs,
            ],
            "joystick": [
                "up": joystick.up?.rawValue ?? NSNull(),
                "down": joystick.down?.rawValue ?? NSNull(),
                "left": joystick.left?.rawValue ?? NSNull(),
                "right": joystick.right?.rawValue ?? NSNull(),
                "northAngle": joystick.northAngle,
                "clockwise": joystick.clockwise,
                "threshold": joystick.threshold,
            ],
            "ambient": [
                "mode": ambient.mode,
                "completionLap": ambient.completionLap,
                "questionLap": ambient.questionLap,
                "errorPulse": ambient.errorPulse,
                "voiceRainbow": ambient.voiceRainbow,
                "fixed": [
                    "color": Int(ambient.fixed.color.value),
                    "effect": ambient.fixed.effect.rawValue,
                    "brightness": ambient.fixed.brightness,
                    "speed": ambient.fixed.speed,
                ],
            ],
            "countdown": [
                "leadMs": countdown.leadMs,
                "introFlashSec": countdown.introFlashSec,
                "introFlashColor": Int(countdown.introFlashColor.value),
                "gain": countdown.gain,
                "mediaDir": countdown.mediaDir,
                "intro": [
                    "enabled": countdown.introEnabled,
                    "color": Int(countdown.introColorKeys.value),
                    "brightness": countdown.introBrightness,
                    "trail": countdown.introTrail,
                ],
            ],
            "entrypoints": entrypoints,
            "scrollLines": scrollLines,
            "staleHours": staleHours,
            "doneDecaySeconds": doneDecaySeconds,
            "holdAttention": holdAttention,
            "maxHoldSeconds": maxHoldSeconds,
            "voiceChord": voiceChord,
            "padScope": padScope.rawValue,
            "workspaceTransition": [
                "style": workspaceTransition.style.rawValue,
                "respectReduceMotion": workspaceTransition.respectReduceMotion,
                "debounceMs": workspaceTransition.debounceMs,
                "rapidWindowMs": workspaceTransition.rapidWindowMs,
                "keyStaggerMs": workspaceTransition.keyStaggerMs,
                "firstKeyDelayMs": workspaceTransition.firstKeyDelayMs,
                "overflowDelayMs": workspaceTransition.overflowDelayMs,
                "ringSweep": workspaceTransition.ringSweep,
                "ringSpeed": workspaceTransition.ringSpeed,
                "ringBrightness": workspaceTransition.ringBrightness,
                "ringHoldMs": workspaceTransition.ringHoldMs,
                "ringFadeSteps": workspaceTransition.ringFadeSteps,
                "ringFadeStepMs": workspaceTransition.ringFadeStepMs,
                "minSweepIntervalMs": workspaceTransition.minSweepIntervalMs,
            ],
            "workspaceIdentity": [
                "palette": workspaceIdentity.palette.map { Int($0.value) },
                "colors": workspaceIdentity.colors.mapValues { Int($0.value) },
            ],
            "overflow": [
                "enabled": overflow.enabled,
                "effect": overflow.effect.rawValue,
                "brightness": overflow.brightness,
                "winkEveryMs": overflow.winkEveryMs,
                "winkMs": overflow.winkMs,
                "winkOriginColor": overflow.winkOriginColor,
            ],
            "superset": [
                "hostClient": superset.hostClient.rawValue,
                "orgId": superset.orgID.map { $0 as Any } ?? NSNull(),
                "testedVersion": superset.testedVersion,
                "onVersionMismatch": superset.onVersionMismatch.rawValue,
                "events": superset.events,
                "startDebounceMs": superset.startDebounceMs,
                "dedupeWindowMs": superset.dedupeWindowMs,
                "padWriteCoalesceMs": superset.padWriteCoalesceMs,
                "reconcileOnLaunch": superset.reconcileOnLaunch,
            ],
            "profiles": profilesJSON,
            "actionKeysLong": actionKeysLong.mapValues(Self.bindingJSON),
            "actionLongPressMs": actionLongPressMs,
            "confirm": [
                "windowMs": confirm.windowMs,
                "color": Int(confirm.color.value),
                "effect": confirm.effect.rawValue,
                "brightness": confirm.brightness,
            ],
            "targeted": [
                "mode": targeted.mode.rawValue,
                "windowMs": targeted.windowMs,
                "snapshotLines": targeted.snapshotLines,
                "requireStopForSend": targeted.requireStopForSend,
                "maxSendBytes": targeted.maxSendBytes,
                "defaultSnippet": targeted.defaultSnippet,
                "snippets": targeted.snippets,
            ],
            "launch": [
                "newAgent": launch.newAgent,
                "handoffAgent": launch.handoffAgent,
                "handoffContextChars": launch.handoffContextChars.map { $0 as Any } ?? NSNull(),
                "createCooldownMs": launch.createCooldownMs,
            ],
            "snippetsAllowDangerous": snippetsAllowDangerous,
            "customThemes": customThemes.map(ThemeFile.entry),
        ]
    }

    /// Every chord, plus a `null` for each built-in one that was deleted — without the
    /// tombstone the merge over the defaults brings it straight back.
    private var shortcutsJSON: [String: Any] {
        var out: [String: Any] = shortcuts.mapValues(\.json)
        for key in Self.default.shortcuts.keys where shortcuts[key] == nil { out[key] = NSNull() }
        return out
    }

    /// Only what each profile names; an inherited binding stays absent. A deleted
    /// built-in profile is written as `null`, for the same reason as `shortcutsJSON`.
    private var profilesJSON: [String: Any] {
        var out: [String: Any] = [:]
        for (bundle, profile) in profiles {
            var fields: [String: Any] = [:]
            if !profile.joystick.isEmpty {
                var stick: [String: Any] = [:]
                for (direction, value) in profile.joystick { stick[direction.rawValue] = Self.bindingJSON(value) }
                fields["joystick"] = stick
            }
            if let value = profile.encoderLongPress {
                fields["encoder"] = ["longPress": Self.bindingJSON(value)]
            }
            if !profile.actionKeysLong.isEmpty {
                fields["actionKeysLong"] = profile.actionKeysLong.mapValues(Self.bindingJSON)
            }
            out[bundle] = fields
        }
        for bundle in Self.default.profiles.keys where profiles[bundle] == nil { out[bundle] = NSNull() }
        return out
    }
}

/**
 Reads and writes `config.json`.

 Atomic, debounced, and mode `0600` — the same as the Node version and the calibration
 record beside it. A brightness slider emits a change per pixel; undebounced that is a
 file write per frame, and without atomicity a crash mid-write leaves a truncated
 document, which for the file that controls everything means coming back with nothing
 configured.
 */
public final class PreferencesStore: @unchecked Sendable {
    public static let shared = PreferencesStore()

    private let queue = DispatchQueue(label: "com.openboard.preferences")
    private var pendingWrite: DispatchWorkItem?
    private var cached: Preferences?

    public init() {}

    public static func url(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        // config.json, not settings.json: this is the file the Node version wrote and
        // the one users already have.
        Calibration.defaultStateDirectory(env: env).appendingPathComponent("config.json")
    }

    @discardableResult
    public func load(url: URL? = nil) -> Preferences {
        let target = url ?? Self.url()
        if let cached, url == nil { return cached }

        guard let data = try? Data(contentsOf: target),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            // No file, or an unreadable one. Defaults, written out so there is always a
            // real document to open rather than settings that exist only in code.
            let fresh = Preferences.default
            save(fresh, url: target, immediately: true)
            if url == nil { cached = fresh }
            return fresh
        }

        let merged = Preferences.merging(json)
        if url == nil { cached = merged }
        return merged
    }

    /// Queue a write. Coalesced, so dragging a slider costs one write rather than fifty.
    public func save(_ preferences: Preferences, url: URL? = nil, immediately: Bool = false) {
        let target = url ?? Self.url()
        if url == nil { cached = preferences }

        pendingWrite?.cancel()

        // Synchronously when asked, so "immediately" means the file exists on return.
        // Dispatching async here once made first-run creation race its own caller.
        if immediately {
            pendingWrite = nil
            queue.sync { Self.write(preferences, to: target) }
            return
        }

        let work = DispatchWorkItem { Self.write(preferences, to: target) }
        pendingWrite = work
        queue.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
    }

    private static func write(_ preferences: Preferences, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONSerialization.data(
            withJSONObject: preferences.json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        // Atomic, or a crash mid-write truncates the file that controls everything.
        try? data.write(to: url, options: [.atomic])
        // 0600, matching the Node version and the calibration record. An atomic write
        // replaces the inode, so the mode is reapplied after every save.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func reset(url: URL? = nil) -> Preferences {
        let fresh = Preferences.default
        save(fresh, url: url, immediately: true)
        cached = fresh
        return fresh
    }
}
