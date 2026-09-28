import Foundation
import OpenBoardKit
import SwiftUI

/**
 The part that makes it an app rather than a set of parts.

 Owns the registry, listens on the hook socket, paints the pad, and publishes what the
 menu bar and settings window read. One object, so there is a single answer to "what is
 the board doing" and the three surfaces cannot disagree.

 Two behaviours carried over from the Node version because they were the difference
 between a board you trust and one you don't:

 - **Re-assert on an interval.** There is no lighting readback — device state can only
   be asserted, never queried — and the ChatGPT app repaints these LEDs on its own
   schedule. A single write is correct only at the instant it lands.
 - **Poll faster while the pad is missing.** ~2s while absent so a reconnect is caught
   promptly, ~10s while present where it is only drift repair. On Bluetooth LE, which
   is how this pad attaches, disappearing and reappearing is normal rather than
   exceptional.
 */
@MainActor
final class BoardController: ObservableObject {
    private let model: BoardModel
    private let device: PadTransport
    /// `HIDDevice.survey()` unless a virtual pad answers instead. Injected separately
    /// from the transport because the real one is static — it asks the bus, not a
    /// handle — and a protocol cannot carry it.
    private let surveyPad: @Sendable () -> HIDDevice.Survey
    private let hooks = HookServer()

    private var registry = SessionRegistry()
    private var dispatcher = KeyDispatcher()
    private var reassertTask: Task<Void, Never>?
    /// The `Liveness` sweep (`startLiveness`).
    private var livenessTask: Task<Void, Never>?
    /// Holds the calibration legend on the keys while the capture sheet is open.
    private var calibrationTask: Task<Void, Never>?
    /// Fun mode, while it owns the pad.
    private var countdown: CountdownPlayer?
    private lazy var pushToTalk = PushToTalk(log: { Log.write($0) })
    private var focusWatcher: FocusWatcher?
    /// What is in front of you — a Terminal tab by tty, a cmux surface by id, or a VS
    /// Code window by title. Drives `viewing`, and is never written into the registry —
    /// see `Viewing`.
    private var focused: FocusedSurface = .elsewhere
    /// Tab titles by tty. Claude Code writes a summary of the session there, and it
    /// stays current as the work changes — unlike anything in the transcript.
    private var terminalTitles: [String: String] = [:]
    /// cmux surfaces by the pid running in them. One read answers both questions the
    /// board asks of cmux — what a session's surface is, and what that surface is
    /// called — so they cannot disagree with each other.
    private var cmuxSurfaces: [Int: Cmux.Surface] = [:]
    /**
     What the six keys show right now — see `PadView`. Recomputed by `publish` and
     `paint` from the registry and `boardContext`, never edited: a key press is
     translated through it back to a registry slot, so the two cannot disagree about
     which session a lit key means.
     */
    private(set) var padView = PadView() {
        didSet { refreshQuestionMode(padView) }
    }
    /// The visible session waiting on a prompt that has the stick sending bare arrows,
    /// if any (`QuestionMode`).
    private var questionTrigger: QuestionMode.Trigger?
    /// Which sessions the pad is showing. `.all` until Superset says otherwise.
    private var boardContext: BoardContext = .all
    /// Which app is in front, as far as the pad's context is concerned.
    private var front: SupersetFocus.Front = .other
    /// Attach, prompt and jump signals; the newest names the workspace.
    private var supersetFocus = SupersetFocus.Resolver()
    /// Superset's host database, read-only. Opened on first need and kept open.
    private var supersetDB: SupersetHostDatabase?
    private var supersetDBRetryAt: Date = .distantPast
    /// Workspace id → worktree path, for entries without a workspace id.
    private var supersetWorktrees: [String: String] = [:]
    private var lastSupersetLog: String?
    /// How to show the settings window. Injected by the delegate that owns it.
    var openSettings: (() -> Void)?
    /// Press versus press-and-hold on the dial.
    private var encoderClick = EncoderClick()
    private var encoderHoldTask: Task<Void, Never>?
    /**
     Everything the key dispatch consults, for the app in front — see `ControlMap`.
     Rebuilt by `applyPreferences()` on every settings edit and by `frontmostChanged`
     when another app comes forward; nothing else holds a copy of a binding.
     */
    private var controlMap = ControlMap.make(prefs: .default)
    /// The app in front, by bundle id, for the per-app profiles (F2).
    private var frontBundleID: String?
    /// Tap versus hold on the action caps that have a long press (F2).
    private var pressTracker = ActionPressTracker(threshold: 0.5)
    /// One timer per cap held down, waiting for the hold threshold.
    private var holdTasks: [String: Task<Void, Never>] = [:]
    /// ⏎ is refused right after a snippet (F1).
    private var enterGuard = EnterGuard()

    // MARK: Two-step confirmation (F4) and NEW (F5)

    /// While an action waits for APPR, the pad belongs to it — see `PendingConfirmation`.
    private var pendingConfirmation = PendingConfirmation(window: 3)
    private var confirmExpiryTask: Task<Void, Never>?
    /// NEW's debounce (D2): a bouncy press never opens two terminals.
    private var launchCooldown = LaunchCooldown(cooldown: 2)
    private var launchCooldownMs = 2000

    // MARK: Targeted control (F7, armed mode)

    /// FAST held arms it; the next agent key fires without jumping. See `TargetedRun`.
    private var targetArming = TargetArming(window: 3)
    private var targetExpiryTask: Task<Void, Never>?

    // MARK: Superset host-service (F3)

    /// The live connection, while `superset.hostClient` is `auto`. Rebuilt when the
    /// settings it was made from change; nil while off.
    private var superset: SupersetLink?
    private struct SupersetLink {
        let config: Preferences.Superset
        let transport: SupersetConnection
        let client: SupersetHostClient
        let events: SupersetEventStream?
    }
    private var supersetHealthTask: Task<Void, Never>?
    /// Bus and hook lifecycle events → states: `Start` debounce and hook/bus dedupe.
    private var lifecycle = LifecycleMapper(startDebounce: 0.2, dedupeWindow: 1.5)
    private var lifecycleFlushTask: Task<Void, Never>?
    private var bindingsRefreshTask: Task<Void, Never>?
    /// The launch reconciliation runs once, on the first successful health check.
    private var reconciledAtLaunch = false
    private var lastLinkLog: String?
    /**
     Agents whose sessions our own hooks report. The bus never gives these a key:
     their `SessionStart` does, and a second key for the same terminal would follow.
     Everything else (Codex, …) is keyed by its terminal from the bus.
     */
    private static let hookedAgents: Set<String> = ["claude"]

    /// At most one bus-driven repaint per `superset.padWriteCoalesceMs`.
    private var padCoalescer = PadWriteCoalescer(interval: 0.09)
    private var padCoalesceMs = 90
    private var busPaintSeq = 0
    private var busDrainTask: Task<Void, Never>?
    /// What the last successful paint put on the keys and ring, so a bus event that
    /// changes nothing visible costs no write at all.
    private var lastPaintedLooks: [Int: Appearance]?
    /// A key that changed state shows its new color solid for a moment — `StateFlash`.
    private var stateFlash = StateFlash()
    /// The repaint that ends the flash in progress, and when it is due.
    private var flashEndTask: Task<Void, Never>?
    private var flashEndsAt: Date?
    private var lastPaintedRing: [SessionState?]?
    /// Accumulated so one turn logs one line rather than one per tick.
    private var scrolledLines = 0
    private var scrollSummary: Task<Void, Never>?
    /// Raw capture, for discovering what an unmapped control actually emits.
    private var joystick = Joystick()
    private var captureUntil: Date?
    private var captureCount = 0
    private var deviceIsOpen = false
    /// Last logged values, so a 10s poll does not fill the log with "still fine".
    private var lastOpenLog: String?
    private var lastPresenceLog: String?
    private var lastCmuxLog: String?
    /// Processes already found to belong to a muted surface, so the walk up the process
    /// tree is paid once per session rather than once per hook. Cleared whenever the
    /// setting changes, because the answer then does too.
    private var mutedPIDs: Set<Int> = []
    private var lastPaintLog: String?
    private var lastAmbientLog: String?
    private var lastPresenceReason: String?
    /// `paint` is async and reentrant; these serialise it. See the comment there.
    private var isPainting = false
    private var repaintWanted = false

    /**
     Whether dictation is believed to be running — believed, and now corroborated.

     Claude Code still reports nothing back: the press is the only way to know
     recording was *asked for*. What changed is that the ring is painted from the
     microphone's own running state (`MicActivity`, the truth behind the orange
     menu-bar dot), gated by the belief. A tap never lights the ring by itself —
     the rainbow arrives when the mic actually starts, and leaves the moment it
     stops, however it was stopped. The conjunction and its bounds live in
     `VoiceSignal`; this class owns the wiring and the repaints.
     */
    private var voice = VoiceSignal()
    private let micActivity = MicActivity()
    /// Sweeps a belief whose grace window expired with the mic never starting — the
    /// tap typed a space. Nothing was lit, so this is bookkeeping, not a repaint.
    private var voiceGraceTask: Task<Void, Never>?

    private var voiceIsActive: Bool {
        // A held custom shortcut is not dictation; only the voice key's hold counts.
        // The hold says so itself: looking its key up in the actions map instead
        // missed the long-press keys, whose "ENC.long" is not a key the map has.
        if pushToTalk.isDictation { return true }
        return voice.isActive()
    }

    private func setVoice(_ active: Bool, why: String) {
        let was = voiceIsActive
        voiceGraceTask?.cancel()
        if active {
            voice.begin()
            // A mic already running counts as confirmation now: dictation joining an
            // ongoing recording cannot flip a flag that is already up, so this is the
            // only chance to see it. The cost is the old degraded bounds if the tap
            // failed — never worse than the belief-only version.
            if micActivity.isRunning { _ = voice.micChanged(running: true) }
            scheduleVoiceGraceSweep()
            Log.write(
                voice.micConfirmed
                    ? "voice: on (\(why), mic already running)"
                    : "voice: believed (\(why)) — awaiting mic"
            )
        } else {
            voice.end()
            Log.write("voice: off (\(why))")
        }
        guard was != voiceIsActive else { return }
        yieldRingToVoice()
        Task { await paint() }
    }

    /// Whether the ring is dictation's right now — the rainbow, which outranks every show.
    private var voiceOwnsRing: Bool {
        model.preferences.ambient.voiceRainbow && voiceIsActive
    }

    /// Dictation starting cuts off whatever show is playing, so the rainbow appears
    /// at once rather than when a lap happens to end.
    private func yieldRingToVoice() {
        guard voiceOwnsRing, let running = runningShow else { return }
        Log.write("show \(running): cut off by dictation")
        showToken += 1
        runningShow = nil
        runningShowPriority = nil
        model.runningShow = nil
        ringBusyUntil = .distantPast
    }

    private func scheduleVoiceGraceSweep() {
        let grace = voice.grace
        voiceGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace) + .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            guard self.voice.since != nil, !self.voice.micConfirmed else { return }
            self.voice.end()
            Log.write("voice: belief expired (mic never started — the tap typed a space)")
        }
    }

    /// While a show owns the ring, the re-assert loop must leave it alone: each step
    /// is asserted once and re-sending restarts the firmware's animation from the
    /// beginning, which turns a 4s lap into flashing.
    private var ringBusyUntil: Date = .distantPast
    private var runningShow: String?
    /// The running show's rank, for `ShowArbiter`.
    private var runningShowPriority: ShowPriority?
    /// Bumped whenever a show is cut off by a higher one, so the one cut off neither
    /// keeps writing nor hands the ring back from under its successor.
    private var showToken = 0
    /// Which workspace switch is current, and when the last one played. See
    /// `TransitionTracker`.
    private var transitions = TransitionTracker()
    /// Flashes the borrowed key's origin color now and then. See `OverflowLook`.
    private var overflowWinkTask: Task<Void, Never>?


    /// While absent, a reconnect should be noticed in about this long.
    private let absentInterval: Duration = .seconds(2)
    /// While present this is drift repair, and can be lazy.
    private let presentInterval: Duration = .seconds(10)

    init(
        model: BoardModel,
        device: PadTransport = HIDDevice(),
        surveyPad: @escaping @Sendable () -> HIDDevice.Survey = HIDDevice.survey
    ) {
        self.model = model
        self.device = device
        self.surveyPad = surveyPad
    }

    /// Re-read anything the settings window can change.
    ///
    /// The dispatcher holds its own copy of the bindings, and the debounce history is
    /// cleared so a rebind is not swallowed by the previous key's window.
    func bindingsChanged() {
        applyPreferences()
        // On, off or reconfigured live: no restart needed to change `superset.*`.
        configureSuperset()

        // Muting a surface is retroactive: the sessions already holding its keys give
        // them up here, before the repaint below, so the switch has a visible effect
        // rather than one that arrives whenever those sessions happen to end.
        //
        // The cache goes first: a surface switched back on must be able to claim again,
        // and a pid remembered as muted would keep being refused.
        mutedPIDs.removeAll()
        sweepUnlistened()
        // `padScope` may have changed; a context change repaints on its own.
        updateBoardContext()
        publish()

        // Every write saves immediately; the debounce lives in the store, so dragging
        // a slider costs one file write rather than one per frame.
        model.persist()
        Task { await paint() }
    }

    /**
     Show one state across all six keys for a moment, then restore the board.

     Brightness and effect only mean anything on the hardware — an emissive key at 55%
     is not a swatch at 55% opacity — so this is the only preview that tells the truth.
     */
    func preview(_ state: SessionState) {
        preview(model.appearances[state] ?? state.defaultAppearance, named: state.rawValue)
    }

    /// The restored-and-unconfirmed look (F1), from `states["unconfirmed"]`.
    func previewUnconfirmed() {
        preview(model.preferences.unconfirmedAppearance, named: Preferences.unconfirmedKey)
    }

    /// The order a theme is shown in, one state per key (slot 1…6).
    private static let themePreviewStates: [SessionState] = [.working, .awaiting, .done, .error, .idle, .stalled]

    /**
     Show a color theme on the pad before choosing it: one state per key, the ring in
     the theme's first palette color, for 3 s, then the real board. Writes nothing to the
     preferences — choosing is the Colors pane's job.
     */
    func previewTheme(_ theme: ColorTheme) {
        previewTheme(theme, then: nil)
    }

    /// The theme preview in flight, so a newer one can cut it short.
    private var themePreviewTask: Task<Void, Never>?

    /**
     The same preview, then `done` — for "preview, then apply" in the Colors pane.

     `done` runs exactly once, on every path: at once with no pad open; after the 3 s
     otherwise, *before* the board is repainted (so the applied theme is what the
     repaint shows); and, when a newer preview cuts this one short, at the cut — without
     repainting, because the newer preview owns the pad now. Every theme preview, with
     or without `done`, cancels the one in flight.
     */
    func previewTheme(_ theme: ColorTheme, then done: (@MainActor () -> Void)?) {
        let finish = CallOnce(done)
        themePreviewTask?.cancel()
        themePreviewTask = nil
        guard deviceIsOpen else {
            finish.run()
            return
        }
        let calibration = model.calibration
        var looks: [Int: Appearance] = [:]
        for (index, state) in Self.themePreviewStates.enumerated() where index < BoardLayout.slotCount {
            looks[index + 1] = theme.appearance(for: state)
        }
        let ring = theme.palette.first.map {
            CodexProtocol.LightingSide(color: $0, brightness: 0.6, effect: .solid, speed: 0)
        } ?? .off

        themePreviewTask = Task { [weak self] in
            // Every exit calls `done` — the once-guard makes a second call a no-op.
            defer { finish.run() }
            guard let self, !Task.isCancelled else { return }
            // One write: the ring config and the six keys together.
            var batch: [[Data]] = []
            batch.append(self.device.prepare(
                lighting: CodexProtocol.LightingConfig(keys: .off, ambient: ring)
            ))
            batch += PadPaint.keyBatch(looks, calibration: calibration, transport: self.device).batch
            try? await self.device.write(batch: batch)
            Log.write("preview: theme \(theme.id)\(done == nil ? "" : " then apply")")
            try? await Task.sleep(for: .seconds(3))
            // Cut short by a newer preview: it owns the pad; only `done` runs (defer).
            guard !Task.isCancelled else { return }
            self.themePreviewTask = nil
            finish.run()
            // Always hand the board back, or the preview becomes the board.
            await self.paint()
        }
    }

    private func preview(_ appearance: Appearance, named name: String) {
        guard deviceIsOpen else { return }
        let calibration = model.calibration

        Task { [weak self] in
            guard let self else { return }
            var batch: [[Data]] = []
            batch.append(self.device.prepare(
                lighting: CodexProtocol.LightingConfig(keys: .off, ambient: .off)
            ))
            let every = Dictionary(uniqueKeysWithValues: (1...BoardLayout.slotCount).map { ($0, appearance) })
            batch += PadPaint.keyBatch(every, calibration: calibration, transport: self.device).batch
            try? await self.device.write(batch: batch)
            Log.write("preview: \(name)")
            try? await Task.sleep(for: .seconds(2))
            // Always hand the board back, or the preview becomes the board.
            await self.paint()
        }
    }

    /**
     Paint the calibration legend and hold it.

     Deliberately **bypasses the calibration mapping**: physical key *n* is painted the
     color of logical slot *n*, because the mapping is the thing being established. Any
     existing record must not influence the capture, or a wrong mapping would confirm
     itself — the pad would light in the order the record already claims.

     It is also the only paint path that runs before a calibration exists, so it cannot
     take the usual "no calibration, do not write" guard.

     Held rather than flashed: Codex repaints these LEDs on its own schedule, so a single
     write can be overwritten within a second or two, leaving someone staring at a pad
     that has gone dark mid-capture. Reasserting every second is what makes the colors
     stay put long enough to read them off.
     */
    func beginCalibrationCapture() {
        guard deviceIsOpen else { return }
        calibrationTask?.cancel()
        calibrationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                var batch: [[Data]] = []
                batch.append(self.device.prepare(
                    lighting: CodexProtocol.LightingConfig(keys: .off, ambient: .off)
                ))
                for entry in CalibrationCapture.legend {
                    guard let thread = try? CodexProtocol.ThreadState(
                        physicalSlot: entry.slot,
                        color: entry.color,
                        // Full brightness, solid: the operator has to distinguish six
                        // hues by eye, and a breathing key at 40% is genuinely hard to
                        // name against another that is mid-fade.
                        brightness: 1.0,
                        effect: .solid,
                        speed: 0
                    ) else { continue }
                    batch.append(self.device.prepare(threads: [thread]))
                }
                try? await self.device.write(batch: batch)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Log.write("calibration: painting legend")
    }

    /// Stop the capture and hand the board back.
    func endCalibrationCapture() {
        calibrationTask?.cancel()
        calibrationTask = nil
        Task { await paint() }
    }

    /// Record what the operator saw, and adopt it immediately.
    func saveCalibration(observed: [Int]) -> Bool {
        guard let record = try? CalibrationCapture.record(observed: observed) else { return false }
        do { try record.save() } catch {
            Log.write("calibration: save failed — \(error.localizedDescription)")
            return false
        }
        model.calibration = record
        Log.write("calibration: saved \(record.rows.map { $0.map(String.init).joined(separator: ",") }.joined(separator: " / "))")
        endCalibrationCapture()
        return true
    }

    /**
     Seed the board from sessions that are already running.

     A hook only fires when a session *does* something, so a session sitting idle in
     another tab would be invisible until you went and typed in it — backwards for a
     board whose job is to tell you what is happening without being asked.
     */
    func reconnect() {
        let found = Discovery.runningSessions()
        // Counted rather than inferred: "9 found, 9 added" and "9 found, 6 added, 3 not
        // listened to" are the same line without this, and the difference is whether a
        // switch in Settings is doing anything at all.
        var skipped = 0
        let added = registry.reconnect(found, isListening: { host in
            let listening = self.model.preferences.listens(to: host)
            if !listening { skipped += 1 }
            return listening
        })
        Log.write(
            "reconnect: \(found.count) running session(s), \(added) added"
                + (skipped > 0 ? ", \(skipped) not listened to" : "")
        )
        // The backfill inside `reconnect` is the first time a restored entry's host is
        // known, so a muted surface can only be recognised here — not when the switch
        // was flipped.
        sweepUnlistened()
        publish()
        Task { await paint() }
    }

    /// Free any key held by a surface that is no longer listened to, and say so.
    ///
    /// Called after discovery and after a settings edit, which are the two moments the
    /// answer can change: one learns a host, the other changes the rule.
    private func sweepUnlistened() {
        let freed = registry.releaseUnlistened { self.model.preferences.listens(to: $0) }
        guard !freed.isEmpty else { return }
        Log.write(
            "surfaces: freed slot\(freed.count == 1 ? "" : "s") "
                + freed.map(String.init).joined(separator: ", ")
                + " — not listening to that surface"
        )
    }

    /// Push configured values into the parts that hold their own copies.
    ///
    /// The dispatcher and the registry cache theirs so their logic stays pure and
    /// testable, which means a config change has to be pushed rather than read.
    private func applyPreferences() {
        let prefs = model.preferences
        // `settings`, not `preferences`: the tap bindings the UI edits live in the
        // model's mirrored state until they are folded back.
        controlMap = ControlMap.make(
            prefs: model.settings, frontBundleID: frontBundleID, questionMode: questionTrigger != nil
        )
        // Replaces every binding and clears the debounce history, so a rebind is not
        // swallowed by the previous binding's window.
        controlMap.configure(&dispatcher)
        // A press in flight was timed against the old bindings; let it go silently
        // rather than fire whatever the cap means now.
        cancelHoldTimers()
        pressTracker = ActionPressTracker(threshold: controlMap.longPressThreshold)
        pushToTalk.maxHoldSeconds = prefs.maxHoldSeconds
        registry.staleInterval = prefs.staleInterval
        if prefs.launch.createCooldownMs != launchCooldownMs {
            launchCooldownMs = prefs.launch.createCooldownMs
            launchCooldown = LaunchCooldown(cooldown: Double(launchCooldownMs) / 1000)
        }
        if prefs.superset.padWriteCoalesceMs != padCoalesceMs {
            padCoalesceMs = prefs.superset.padWriteCoalesceMs
            padCoalescer = PadWriteCoalescer(interval: Double(padCoalesceMs) / 1000)
        }
    }

    /// Another app came forward: the profile may differ. Only the map changes — the
    /// debounce history and a press in flight are kept, because switching apps is not
    /// an edit and must not eat a keypress.
    private func frontProfileChanged() {
        let next = ControlMap.make(
            prefs: model.settings, frontBundleID: frontBundleID, questionMode: questionTrigger != nil
        )
        guard next != controlMap else { return }
        controlMap = next
        dispatcher.longPressKeys = next.longPressKeys
        Log.write(
            "profile: \(frontBundleID.flatMap { model.preferences.profiles[$0] != nil ? $0 : nil } ?? "base")"
                + " — holds on \(next.longPressKeys.sorted().joined(separator: ","))"
        )
    }

    /**
     A visible session started or stopped waiting on a prompt: swap the stick between
     bare arrows and the profile. Only the joystick changes — the taps, holds and the
     dispatcher's state are left exactly as they are.
     */
    private func refreshQuestionMode(_ view: PadView) {
        let trigger = QuestionMode.next(
            current: questionTrigger, entries: registry.entries, padKeys: view.keys, overflowKey: view.overflowKey
        )
        guard (trigger != nil) != (questionTrigger != nil) else {
            questionTrigger = trigger
            return
        }
        questionTrigger = trigger
        controlMap.joystick = ControlMap.make(
            prefs: model.settings, frontBundleID: frontBundleID, questionMode: trigger != nil
        ).joystick
        Log.write(QuestionMode.logLine(trigger))
    }

    /// Question mode as of now: the pad may not have been repainted since the prompt
    /// appeared or was answered.
    private func currentQuestion() -> QuestionMode.Trigger? {
        refreshQuestionMode(composePadView())
        return questionTrigger
    }

    /// FAST and CODEX while a prompt waits: logged and dropped (`QuestionMode.ignoredCaps`).
    private func ignoredInQuestionMode(_ cap: String) -> Bool {
        guard QuestionMode.ignores(cap: cap, active: currentQuestion() != nil) else { return false }
        Log.write(QuestionMode.ignoredLogLine(cap: cap))
        return true
    }

    /// Space or Tab from the dial, in question mode.
    private func sendQuestionKey(_ shortcut: Shortcut, from control: String) {
        let result = Actions.press(shortcut)
        Log.write(result.ok ? "key \(control): \(shortcut.key) (question mode)" : "key \(control): \(result.detail)")
    }

    private func cancelHoldTimers() {
        holdTasks.values.forEach { $0.cancel() }
        holdTasks.removeAll()
        pressTracker.reset()
    }

    func start() {
        // Say what was loaded, not just that something was. A config read from the
        // wrong path or merged wrongly is otherwise indistinguishable from defaults.
        let prefs = model.preferences
        Log.write(
            "OpenBoard starting (calibration: \(model.isCalibrationConfirmed ? "recorded" : "assumed"))"
        )
        Log.write(
            "config \(PreferencesStore.url().path): "
                + "idle=\(prefs.appearance(for: .idle).color.hex)/"
                + "\(prefs.appearance(for: .idle).effect.rawValue)@"
                + "\(Int(prefs.appearance(for: .idle).brightness * 100))%, "
                + "working=\(prefs.appearance(for: .working).effect.rawValue), "
                + "notifications=\(prefs.notificationStates.map { "\($0.key)->\($0.value.rawValue)" }.sorted().joined(separator: " ")), "
                + "muted=\(prefs.events.filter { !$0.value }.keys.sorted().joined(separator: ",") ) , "
                + "scroll=\(prefs.scrollLines)/"
                + "\(prefs.encoder.clockwiseScrollsUp ? "cw-up" : "cw-down") "
                + "stale=\(prefs.staleHours)h"
        )

        // Asked once at launch and logged, because these are the failures that look
        // like a broken app rather than a missing permission — and because a probe
        // that reports the wrong process's state (as the old AppleScript one did) is
        // only caught by comparing this line against what actually happens next.
        let permissions = PermissionProbe.inspect()
        Log.write(
            "permissions: input-monitoring=\(permissions.inputMonitoring.rawValue) "
                + "accessibility=\(permissions.accessibility.rawValue) "
                + "bluetooth=\(permissions.bluetooth.rawValue) "
                + permissions.automation
                    .map { "automation[\($0.key)]=\($0.value.rawValue)" }
                    .sorted().joined(separator: " ")
        )

        // The wiring the whole system depends on, and the only one that fails without
        // any symptom at all: a hook pointing at a moved bundle still looks configured.
        let audit = HookInstall.audit(
            settings: HookInstall.loadSettings(),
            expectedCommand: HookInstall.hookCommandPath()
        )
        Log.write(
            audit.isHealthy
                ? "hooks: all \(HookInstall.events.count) wired to this build"
                : "hooks: PROBLEM — \(audit.problems.map { "\($0) \(audit.statuses[$0].map(String.init(describing:)) ?? "?")" }.joined(separator: ", "))"
        )

        // Only when the preference asks for the chord: a missing binding then means
        // the voice key does nothing at all, which reads as a dead key, not a
        // missing line in a file the user may never have opened.
        if prefs.voiceChord {
            let chord = KeybindingInstall.audit(document: KeybindingInstall.load())
            Log.write(
                chord.isHealthy
                    ? "keybinding: ⌃Y wired to \(KeybindingInstall.action)"
                    : "keybinding: PROBLEM — ⌃Y \(chord.status), voice key is dead until repaired in Settings"
            )
        }

        applyPreferences()

        // Restore the board before anything reads it, so a session keeps the key it
        // had. Entries that cannot still be true are dropped rather than trusted —
        // see RegistryStore.
        //
        // Superset's own terminal table is asked about each restored Superset session
        // (read-only): one it disposed or ended comes back ended, not in the state the
        // file saved. The rest come back unconfirmed until a live event says otherwise.
        let liveness: (String) -> TerminalLiveness? = prefs.superset.reconcileOnLaunch
            ? { [weak self] id in self?.openSupersetDB()?.terminalLiveness(id) }
            : { _ in nil }
        registry = RegistryStore.load(staleInterval: prefs.staleInterval, liveness: liveness)
        registry.staleInterval = prefs.staleInterval
        if !registry.entries.isEmpty {
            Log.write(
                "registry: restored \(registry.entries.count) session(s) — "
                    + registry.entries
                        .sorted { $0.slot < $1.slot }
                        .map { "\($0.slot):\($0.state.rawValue)\($0.isUnconfirmed ? "?" : "")" }
                        .joined(separator: " ")
            )
        }

        startFocusWatcher()
        startKeyInterception()
        startMicWatcher()
        startHookServer()
        // After the registry is restored: the first health check reconciles it.
        configureSuperset()
        startResident()
        startOverflowWink()
        reconnect()
    }

    /// Feed mic transitions into the voice belief. The callback arrives on
    /// MicActivity's own queue; everything stateful happens back on the main actor.
    private func startMicWatcher() {
        micActivity.watch { [weak self] running in
            Task { @MainActor in
                guard let self else { return }
                let was = self.voiceIsActive
                let reason = self.voice.micChanged(running: running)
                let now = self.voiceIsActive
                guard now != was else { return }
                Log.write("voice: \(now ? "on" : "off") (\(reason ?? "mic"))")
                self.yieldRingToVoice()
                await self.paint()
            }
        }
    }

    // MARK: - key interception

    /**
     Give the pad's keys meaning.

     Layer 1's keycodes are locked by the Codex app and cannot be remapped — but the
     device broadcasts every press on the vendor channel, so meaning is assigned here
     instead. Nothing on the pad has to be reconfigured.

     Registered once, against the device's line stream. The stream survives
     reconnects because the resident reopens the handle, and the handler is attached
     to this object rather than to any particular handle.
     */
    private func startKeyInterception() {
        device.onLine { [weak self] line in
            // A control reporting under a method this app does not know is invisible
            // here — `KeyEvent.parse` returns nil and the guard below drops it. That is
            // how the joystick went unnoticed for months. `openboard-probe --listen`
            // prints the raw stream when a new control needs identifying.
            // The stick shares the stream with the keys but speaks a different
            // method, which is why it looked inert for so long.
            if let sample = Joystick.parse(line) {
                Task { @MainActor in
                    self?.handle(stickAngle: sample.angle, deflection: sample.deflection)
                }
                return
            }

            guard let event = KeyEvent.parse(line) else { return }
            Task { @MainActor in self?.handle(key: event) }
        }
    }


    /// One push of the stick is one action, however many samples it emits.
    private func handle(stickAngle angle: Double, deflection: Double) {
        joystick.northAngle = model.preferences.joystick.northAngle
        joystick.clockwise = model.preferences.joystick.clockwise
        joystick.threshold = model.preferences.joystick.threshold

        guard let direction = joystick.update(angle: angle, deflection: deflection) else {
            return
        }
        if pendingConfirmation.pending != nil {
            resolveConfirmation(pendingConfirmation.handle(.other(key: "JOY.\(direction.rawValue)"), now: Date()))
            return
        }
        let step = targetArming.otherKey(now: Date())
        if step != .none {
            handleTargeting(step)
            return
        }
        // The pad may not have been repainted since the prompt appeared or was answered.
        refreshQuestionMode(composePadView())
        // Per app: with Superset in front the stick switches workspaces and tabs —
        // unless a visible session is waiting on a prompt, then it sends bare arrows.
        let resolved = controlMap.joystick[direction]
        guard let resolved, let action = resolved.action else {
            Log.write("stick \(direction.rawValue): unbound")
            return
        }
        // The angle is logged because the mapping from angle to direction is the one
        // part that cannot be verified by reading the code — it depends on how the
        // hardware is oriented.
        Log.write(String(format: "stick %@ (a=%.3f)", direction.rawValue, angle))
        perform(action, key: resolved.payloadKey)
    }

    private func handle(key event: KeyEvent) {
        guard let intent = dispatcher.intent(for: event) else { return }
        // A pending confirmation owns the pad: APPR confirms, any other key cancels
        // and does not do its own thing (F4). Releases and the dial's turn pass.
        if pendingConfirmation.pending != nil, let input = confirmationInput(for: intent) {
            resolveConfirmation(pendingConfirmation.handle(input, now: Date()))
            return
        }
        // Armed (F7): the key aims or cancels, and does not do its own thing — above all
        // an agent key does not jump.
        if case let .consumed(step) = TargetedRun.route(
            intent, arming: &targetArming, taps: controlMap.taps, now: Date()
        ) {
            handleTargeting(step)
            return
        }
        switch intent {
        case let .jump(key):
            // A pad key, not a registry slot: in a workspace context key 1 is the
            // workspace's first session, wherever it sits in the registry.
            jump(fromPadKey: key)
        case let .action(action, key):
            if ignoredInQuestionMode(key) { return }
            perform(action, key: key)
        case .encoderPressed:
            encoderPressed()
        case let .actionPressed(key):
            actionPressed(key)

        case let .release(key):
            // A cap waiting to tell a tap from a hold resolves here if it was short.
            actionReleased(key)
            // Otherwise only push-to-talk cares about the release edge, and only when
            // the key that was released is the one holding it — any other key's
            // release would end the dictation.
            if key == "ENC_CLK" {
                encoderReleased()
            } else if pushToTalk.heldBy == key {
                pushToTalk.end()
                Task { await paint() }
            }
        case let .scroll(lines):
            // In question mode a detent is one arrow through the options — except on a
            // plan, which has to be scrolled to be read.
            if let question = currentQuestion(),
               case let .arrow(direction) = QuestionMode.dial(.turn(lines: lines), pendingTool: question.pendingTool) {
                let result = Actions.arrow(direction)
                Log.write(result.ok ? "key ENC: arrow \(direction.rawValue) (question mode)" : "key ENC: \(result.detail)")
                return
            }
            Actions.scroll(lines: lines)
            noteScroll(lines)
        }
    }

    private func jump(fromPadKey key: Int) {
        guard let sessionID = padView.sessionID(forKey: key),
              let entry = registry.entry(forSession: sessionID) else {
            Log.write("key: pad key \(key) has no session")
            return
        }
        if entry.slot != key || padView.context != .all {
            Log.write("key: pad key \(key) is slot \(entry.slot)"
                + (padView.overflowKey == key ? " (borrowed from another workspace)" : ""))
        }
        jump(to: entry.slot)
    }

    private func jump(to slot: Int) {
        guard let view = model.slots.first(where: { $0.slot == slot }), view.isOccupied else {
            Log.write("key: slot \(slot) has no session")
            return
        }
        // Going to a workspace is the strongest word on which one you are in — ahead
        // of Superset's own attach, which follows a second later.
        // A key whose process is gone leads to a tab with no session in it. Refuse
        // with the amber blink and let the key go dark, rather than raise a ghost.
        if let sessionID = view.sessionID,
           case let .dead(ended) = registry.checkBeforeJump(sessionID: sessionID) {
            Log.write("key: jump to \(describeKey(slot: slot)) refused — " + Liveness.endedLogLine(ended))
            _ = play(show: Shows.refused(), priority: .confirm)
            publish()
            Task { await paint() }
            return
        }
        if let workspace = view.supersetWorkspaceID {
            noteSupersetSignal(.init(workspaceID: workspace, at: Date(), source: .jump))
        }
        let outcome = Focus.raise(view)
        Log.write("key: jump to \(describeKey(slot: slot)) -> \(outcome)")
    }

    /**
     APPR/REJ for a session in another Superset workspace: raise it now, then send the
     key only once Superset's attach says that workspace is in front.

     `Actions.respond` confirms that Superset is the app in front, which the deep link
     makes true at once — the switch itself lands later. Seen live: "approve sent to
     key 6" on a borrowed key, and the prompt still open, because the ⏎ reached the
     workspace being left. The wait suspends rather than sleeps, so the main actor
     keeps serving hooks and keys while it runs.

     Returns false when the ordinary path applies: nothing single pending, no
     workspace, the workspace already in front, or no host database to confirm from.
     */
    private func respondAcrossWorkspaces(
        _ decision: Actions.Decision, slots: [SlotView], action: KeyAction, key: String
    ) -> Bool {
        let pressedAt = Date()
        guard case let .one(target) = Actions.pendingPick(slots),
              let workspace = target.supersetWorkspaceID,
              SupersetFocus.mustAwaitWorkspace(target: workspace, active: supersetFocus.winner?.workspaceID)
        else { return false }
        guard let db = openSupersetDB() else {
            Log.write("respond: workspace \(workspace.prefix(8)) cannot be confirmed (no host.db) — answering as before")
            return false
        }
        let raised = Focus.raise(target)
        guard case .raised = raised else {
            logRespond(.focusFailed(slot: target.slot, reason: "\(raised)"), action: action, key: key)
            return true
        }
        Log.write("respond: waiting for workspace \(workspace.prefix(8)) to come forward")
        Task { [weak self] in
            let sent = await SupersetFocus.awaitWorkspace(
                .init(workspaceID: workspace, since: pressedAt),
                latestAttach: { db.latestAttach() },
                sleep: { try? await Task.sleep(for: .seconds($0)) }
            ) {
                guard let self else { return }
                self.logRespond(Actions.respond(decision, slots: slots), action: action, key: key)
            }
            guard !sent, let self else { return }
            Log.write(SupersetFocus.didNotComeForwardLogLine(workspaceID: workspace))
            _ = self.play(show: Shows.refused(), priority: .confirm)
        }
        return true
    }

    private func logRespond(_ outcome: Actions.RespondOutcome, action: KeyAction, key: String) {
        switch outcome {
        case let .sent(slot):
            Log.write("key \(key): \(action.rawValue) sent to \(describeKey(slot: slot))")
        case .nothingPending:
            Log.write("key \(key): nothing is waiting")
        case let .ambiguous(slots):
            // Refusing is the feature. Guessing would answer a prompt the user
            // never read.
            Log.write(
                "key \(key): refused — \(slots.map { describeKey(slot: $0) }.joined(separator: ", ")) "
                    + "are all waiting; press one of those keys"
            )
        case let .focusFailed(slot, reason):
            Log.write("key \(key): \(describeKey(slot: slot)) never came forward (\(reason)) — not sent")
        case let .failed(detail):
            Log.write("key \(key): \(detail)")
        }
    }

    /// A press whose key is still down when it fires: an action cap can hold, the dial
    /// and the stick cannot.
    private func perform(_ action: KeyAction, key: String) {
        let isCap = BoardLayout.cells.contains { $0.isAction && $0.id == key }
        perform(action, key: key, holdKey: isCap ? key : nil)
    }

    /**
     - Parameter key: the payload key — a cap ("ACT06"), "ACT09.long@<bundle>",
       "JOY.up@<bundle>", "ENC.long" — which is what shortcuts and snippets are
       looked up by.
     - Parameter holdKey: the physical cap still down, whose release ends a hold. Nil
       when nothing can be held: the release already happened (a tap resolved on
       the way up) or the control has no release edge.
     */
    private func perform(_ action: KeyAction, key: String, holdKey: String?) {
        Log.write("key \(key) -> \(action.rawValue)")
        switch action {
        case .sync:
            Task { await paint() }
        case .settings:
            openSettingsWindow()
        case .reset:
            forgetAllSessions()
        case .off:
            Task { await allKeysOff() }
        case .approve, .reject:
            // Reject doubles as the cancel while fun mode runs, and cancelling wins.
            // The pad is showing a light show rather than the board, so there is no
            // prompt visible to answer — sending ⎋ to whatever is behind the video
            // would reject something the user cannot see.
            if action == .reject, countdown?.isRunning == true {
                Log.write("key \(key): cancelling fun mode")
                countdown?.cancel()
                return
            }
            let decision: Actions.Decision = action == .approve ? .approve : .reject
            // In question mode the answer goes to the session the stick is moving
            // through, even with another waiting too. It does not end the mode: only
            // the hook saying the session moved on does (`QuestionMode.next`).
            var slots = model.slots
            if let target = QuestionMode.answerTarget(for: action, trigger: currentQuestion()) {
                slots = slots.filter { $0.sessionID == target }
                Log.write("key \(key): question mode — answering \(target.prefix(8))")
            }
            if respondAcrossWorkspaces(decision, slots: slots, action: action, key: key) { return }
            logRespond(Actions.respond(decision, slots: slots), action: action, key: key)

        case .snippet:
            let text = model.snippets[key]
                ?? model.snippets[ProfileResolver.baseKey(of: key)]
                ?? model.snippet
            // The config is hand-editable; a key that would end or wipe the session in
            // front is refused here, whatever the file says (F1).
            if case let .block(reason) = SnippetGuard.check(
                text, allowDangerous: model.preferences.snippetsAllowDangerous
            ) {
                Log.write("key \(key): snippet blocked — \(reason)")
                return
            }
            let result = Actions.typeSnippet(text)
            if result.ok { enterGuard.noteSnippet(now: Date()) }
            Log.write(result.ok ? "key \(key): typed \(text)" : "key \(key): \(result.detail)")

        case .enter:
            // Not blind: ⏎ right after a snippet would submit it unread (F1).
            guard enterGuard.allowsEnter(now: Date()) else {
                Log.write(
                    "key \(key): ⏎ refused — a snippet was typed less than "
                        + "\(Int(enterGuard.window))s ago"
                )
                return
            }
            let result = Actions.pressEnter()
            Log.write(result.ok ? "key \(key): sent ⏎" : "key \(key): \(result.detail)")

        case .shortcut:
            // `<key>@<bundle>` first, then the bare key: a per-app chord wins.
            guard let shortcut = ProfileResolver.shortcut(forPayloadKey: key, prefs: model.preferences) else {
                Log.write("key \(key): no shortcut recorded")
                return
            }
            // Hold needs a release edge, and only a cap still down delivers one. The
            // file is hand-editable, so a hold on the dial or the stick — or on a cap
            // already released — is sent as a tap rather than left to the 60s backstop.
            if shortcut.mode == .hold, let holdKey {
                pushToTalk.begin(shortcut, key: holdKey)
            } else {
                if shortcut.mode == .hold { Log.write("key \(key): cannot hold here — tapping") }
                sendShortcut(shortcut, key: key)
            }

        case .newtab:
            let result = Actions.newTerminalTab()
            Log.write(result.ok ? "key \(key): opened a Terminal tab" : "key \(key): \(result.detail)")

        case .newtabCmux:
            let result = Actions.newCmuxTab()
            Log.write(
                result.ok
                    ? "key \(key): opened a cmux tab — \(result.detail)"
                    : "key \(key): \(result.detail)"
            )

        case .newWorkspaceCmux:
            let result = Actions.newCmuxWorkspace()
            Log.write(
                result.ok
                    ? "key \(key): opened a cmux workspace — \(result.detail)"
                    : "key \(key): \(result.detail)"
            )

        case .voiceTap:
            // The chord invokes `voice:pushToTalk` directly and types nothing; space
            // is the fallback that also types spaces when the input is not empty.
            let chord = model.preferences.voiceChord
            let result = chord ? Actions.tapVoiceChord() : Actions.tapVoice()
            Log.write(
                result.ok
                    ? "key \(key): voice tap (\(chord ? "⌃Y" : "space"))"
                    : "key \(key): \(result.detail)"
            )
            // The same tap starts and stops it, so the belief flips with the key.
            if result.ok { setVoice(!voiceIsActive, why: "tapped") }

        case .voiceTalk:
            // The release edge ends it — see PushToTalk for why this is never trusted
            // to happen on its own.
            guard let holdKey else {
                // The cap has a long press, so its tap only arrives on the way up —
                // too late to hold anything.
                Log.write("key \(key): voice-talk needs the key held, and it was released — nothing sent")
                return
            }
            pushToTalk.begin(key: holdKey, dictation: true)

        case .voiceToggle:
            let result = Actions.toggleVoice()
            Log.write(result.ok ? "key \(key): toggled voice" : "key \(key): \(result.detail)")
            if result.ok { setVoice(!voiceIsActive, why: "/voice") }

        case .popover:
            openMenuBarPopover()

        case .tabForward:
            let result = Actions.nextTab()
            Log.write(result.ok ? "key \(key): next tab" : "key \(key): \(result.detail)")

        case .tabBack:
            let result = Actions.previousTab()
            Log.write(result.ok ? "key \(key): previous tab" : "key \(key): \(result.detail)")

        case .prevSession, .nextSession:
            stepSession(forward: action == .nextSession)

        case .arrowUp, .arrowDown, .arrowLeft, .arrowRight:
            let direction: Joystick.Direction = switch action {
            case .arrowUp: .up
            case .arrowDown: .down
            case .arrowLeft: .left
            default: .right
            }
            let result = Actions.arrow(direction)
            Log.write(result.ok ? "key \(key): arrow \(direction.rawValue)"
                                : "key \(key): \(result.detail)")

        case .countdown:
            // Pressing it again stops it, so the key that starts the show can always
            // end it — `playCountdown` toggles.
            playCountdown()

        case .jumpOldestWaiting:
            jumpOldestWaiting(key: key)

        case .supersetNewAgent:
            launchNewAgent(key: key)

        case .targetedArm:
            armTargeting(key: key)

        case .interruptFocused:
            interruptFocused(key: key)

        case .supersetHandoff:
            armHandoff(key: key)
        }
    }

    /**
     Send a tapped chord `repeats` times, `Shortcut.repeatGap` apart (⎋⎋ from one press).
     The first goes out at once, exactly as before; the rest follow on a task, in order,
     and stop at the first failure. The sequence is `Shortcut.sendDelays`.
     */
    private func sendShortcut(_ shortcut: Shortcut, key: String) {
        let delays = shortcut.sendDelays
        let first = Actions.press(shortcut)
        guard first.ok else {
            Log.write("key \(key): \(first.detail)")
            return
        }
        guard delays.count > 1 else {
            Log.write("key \(key): sent \(shortcut.label)")
            return
        }
        Task { @MainActor in
            var sent = 1
            for delay in delays.dropFirst() {
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                let result = Actions.press(shortcut)
                guard result.ok else {
                    Log.write("key \(key): sent \(shortcut.label) ×\(sent), then \(result.detail)")
                    return
                }
                sent += 1
            }
            Log.write("key \(key): sent \(shortcut.label) ×\(sent)")
        }
    }

    /**
     What the ring should be showing, as the device wants it.

     Dark in `events` mode, which is the default: the ring is a notification surface,
     not a second status display. A lap fires on a transition and it goes back to
     nothing — that is what makes a lap mean something.
     */
    /**
     Watch which session is in front of you.

     Started once, from `start()`. It was briefly created in `bindingsChanged()`
     instead, which never runs at launch and runs on every settings edit — so the
     indicator never appeared and each edit leaked another observer and poll loop.
     */
    private func startFocusWatcher() {
        let watcher = FocusWatcher(onChange: { [weak self] surface in
            guard let self, self.focused != surface else { return }
            self.focused = surface
            // Which slot it matched, not just what was in front. A handle that matches
            // nothing looks identical in the log to one that matches — and "the
            // indicator does not work" is usually the session having no recorded tty or
            // no name yet, not the watcher.
            let matched = self.registry.entries.first {
                self.isFocused($0, name: self.name(of: $0))
            }
            // Including what the key is told to emit: "the pulse is the wrong color" is
            // otherwise indistinguishable in the log from "focus never matched".
            let emitted = matched.map { entry -> String in
                let shown = Viewing.display(entry.state, isFocused: true)
                let look = Viewing.appearance(shown, isFocused: true, from: self.model.appearances)
                return " -> slot \(entry.slot) (\(shown.rawValue)) "
                    + "\(look.color.hex)/\(look.effect.rawValue)@\(Int(look.brightness * 100))%"
            }
            Log.write("focus: \(Self.describe(surface))" + (emitted ?? ""))
            self.publish()
            Task { await self.paint() }
        }, onFrontmost: { [weak self] bundleID in
            self?.frontmostChanged(bundleID)
        }, onSupersetPoll: { [weak self] in
            self?.readSupersetAttach()
            self?.updateBoardContext()
        })
        focusWatcher = watcher
        watcher.start()
    }

    // MARK: - workspace context

    /// Surfaces whose sessions live outside any Superset workspace. With one of these
    /// in front, filtering by a workspace would hide the sessions you are using.
    private static let terminalHostBundleIDs: Set<String> = [
        "com.apple.Terminal", Cmux.bundleID, VSCodeWindows.bundleID, "com.googlecode.iterm2",
    ]

    private func frontmostChanged(_ bundleID: String?) {
        if frontBundleID != bundleID {
            frontBundleID = bundleID
            frontProfileChanged()
        }
        front = switch bundleID {
        case Focus.supersetBundleID?: .superset
        case let id? where Self.terminalHostBundleIDs.contains(id): .terminalHost
        default: .other
        }
        if front == .superset, model.preferences.padScope == .focusedWorkspace {
            // Coming back is when a workspace created meanwhile is worth learning.
            supersetWorktrees = openSupersetDB()?.worktrees() ?? supersetWorktrees
            readSupersetAttach()
        }
        updateBoardContext()
    }

    /// The database, opened on first need. A failure is retried, but not every poll:
    /// discovery lists a directory, and a Superset that is not installed never will be.
    private func openSupersetDB() -> SupersetHostDatabase? {
        if let supersetDB { return supersetDB }
        guard Date() >= supersetDBRetryAt else { return nil }
        supersetDBRetryAt = Date().addingTimeInterval(30)
        guard let url = SupersetFocus.databaseURL(),
              let db = SupersetHostDatabase(url: url) else {
            lastSupersetLog = Log.changed(
                "superset", last: lastSupersetLog,
                to: "host.db not found or unreadable — the pad shows every session"
            )
            return nil
        }
        supersetDB = db
        supersetWorktrees = db.worktrees()
        lastSupersetLog = Log.changed("superset", last: lastSupersetLog, to: "reading \(url.path)")
        return db
    }

    private func readSupersetAttach() {
        guard model.preferences.padScope == .focusedWorkspace else { return }
        if let signal = openSupersetDB()?.latestAttach() { supersetFocus.note(signal) }
    }

    private func noteSupersetSignal(_ signal: SupersetFocus.Signal) {
        supersetFocus.note(signal)
        updateBoardContext()
    }

    /// Recompute the context and act on a change. Cheap enough to call on every poll:
    /// nothing happens unless the answer moves.
    private func updateBoardContext() {
        let scope = model.preferences.padScope
        let winner = supersetFocus.winner
        if scope == .focusedWorkspace, front == .superset, winner == nil {
            lastSupersetLog = Log.changed(
                "superset", last: lastSupersetLog,
                to: "no workspace signal yet — the pad shows every session"
            )
        }
        let next = SupersetFocus.context(
            scope: scope, front: front, resolved: winner?.workspaceID, previous: boardContext
        )
        guard next != boardContext else { return }
        let previous = boardContext
        boardContext = next
        if case .superset = next, let winner {
            Log.write("pad: \(Self.describe(previous)) -> \(Self.describe(next)) (by \(winner.source.rawValue))")
        } else {
            Log.write("pad: \(Self.describe(previous)) -> \(Self.describe(next))")
        }
        workspaceContextChanged(from: previous, to: next)
    }

    /**
     The pad is about to show a different set of sessions.

     Plays the transition — "Barrido + recuento": the ring sweeps once in the
     workspace's color and the keys light one after another. What plays and when is
     decided by `TransitionTracker` and `TransitionPlayback`; this only sleeps and
     writes. It always ends in `paint()`, which draws from `boardContext` — already
     set to `to` by the time this runs — so the animation decides the order things
     appear in, never what they end up showing.
     */
    func workspaceContextChanged(from previous: BoardContext, to next: BoardContext) {
        publish()
        let generation = transitions.contextChanged()
        Task { await playTransition(generation: generation, to: next) }
    }

    private func playTransition(generation: Int, to next: BoardContext) async {
        let settings = model.preferences.workspaceTransition
        // Cycling through workspaces with the shortcut animates only where you stop.
        if settings.debounceMs > 0 {
            try? await Task.sleep(for: .milliseconds(settings.debounceMs))
        }
        guard transitions.isCurrent(generation) else { return }
        // Whatever owns the pad instead — a capture, fun mode, no pad — `paint` already
        // knows how to stand down for.
        guard deviceIsOpen, calibrationTask == nil, countdown?.isRunning != true else {
            await paint()
            return
        }
        // One writer: wait out a repaint already in flight rather than interleave.
        while isPainting {
            try? await Task.sleep(for: .milliseconds(20))
            guard transitions.isCurrent(generation) else { return }
        }

        padView = composePadView()
        let looks = keyLooks()
        let mode = Ambient.Mode(rawValue: model.preferences.ambient.mode) ?? .events
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let plan = transitions.plan(
            generation: generation,
            now: Date(),
            to: next,
            roles: looks.mapValues { TransitionPlanner.role(of: $0.state) },
            overflowKey: padView.overflowKey,
            settings: settings,
            reduceMotion: reduceMotion,
            ringFree: TransitionPlanner.ringFree(
                mode: mode, ringStates: padView.ringStates,
                appearances: model.appearances, voiceActive: voiceOwnsRing
            )
        ) else { return }

        if plan.ring != .none, case let .superset(workspaceID) = next {
            let color = WorkspaceColors.color(
                for: workspaceID,
                identity: model.preferences.workspaceIdentity,
                stateColors: model.appearances.values.map(\.color)
            )
            // Through the arbiter like any lap: it never cuts off a prompt or a failure.
            play(
                show: plan.ring == .sweep
                    ? Shows.workspaceSweep(color: color, settings: settings)
                    : Shows.workspaceCut(color: color),
                priority: .workspace
            )
        }
        guard plan.kind == .cascade else {
            await paint()
            return
        }

        // The cascade holds the paint lane: a hook or the resident loop asking for a
        // repaint meanwhile is coalesced into the one below, not interleaved.
        isPainting = true
        let start = ContinuousClock.now
        var playback = TransitionPlayback(plan)
        var outcome = "played"
        cascade: while true {
            switch playback.next(isCurrent: transitions.isCurrent(generation) && deviceIsOpen) {
            case let .wait(untilMs):
                try? await Task.sleep(until: start + .milliseconds(untilMs), clock: .continuous)
            case let .write(frame):
                var frameLooks: [Int: Appearance] = [:]
                for (key, look) in frame.keys {
                    frameLooks[key] = look == .final ? (looks[key]?.look ?? .off) : .off
                }
                let batch = PadPaint.keyBatch(frameLooks, calibration: model.calibration, transport: device).batch
                guard !batch.isEmpty else { continue }
                do {
                    try await device.write(batch: batch)
                } catch {
                    // `paint` below meets the same failure and owns what it means.
                    outcome = "write failed"
                    break cascade
                }
            case .abort:
                outcome = "interrupted"
                break cascade
            case .finish, .done:
                break cascade
            }
        }
        isPainting = false
        repaintWanted = false
        Log.write(
            "pad: transition \(outcome) (\(plan.frames.count) writes, ring \(plan.ring))"
        )
        await paint()
    }

    /**
     What each pad key shows right now, from `padView` — the one place a key's final
     look is decided, so `paint` and the transition cannot disagree about it.

     `state` is the session's own, before the focus overlay: the transition asks it
     whether a key needs a human.
     */
    private func keyLooks() -> [Int: (look: Appearance, state: SessionState?, sessionID: String?)] {
        var looks: [Int: (look: Appearance, state: SessionState?, sessionID: String?)] = [:]
        for key in 1...BoardLayout.slotCount {
            let entry = padView.sessionID(forKey: key).flatMap { registry.entry(forSession: $0) }
            // A free slot and a finished session both mean "nothing to look at".
            // `viewing` is applied here rather than stored — see Viewing.
            let viewing = entry.map { isFocused($0, name: name(of: $0)) } ?? false
            let state = entry.map { Viewing.display($0.state, isFocused: viewing) } ?? .ended
            var look = Viewing.appearance(state, isFocused: viewing, from: model.appearances)
            // Still, where every local key breathes: not from here.
            // Restored from disk and not yet confirmed by a live event: not trusted
            // enough to shout, so it gets the dim "unconfirmed" look (F1, D11).
            if let entry, entry.isUnconfirmed, !viewing {
                look = model.preferences.unconfirmedAppearance
            }
            if key == padView.overflowKey {
                look = OverflowLook.appearance(look, settings: model.preferences.overflow)
            }
            // How fast it moves is a factor applied here, never written into the colors.
            look = model.preferences.animationSpeed.look(look)
            looks[key] = (look, entry?.state, entry?.sessionID)
        }
        return looks
    }

    /**
     Every few seconds the borrowed key shows, for a moment, the color of the workspace
     its prompt lives in — "urgent, and over there".

     Two writes each time, taken inside the paint lane like any other; skipped
     outright when the lane is busy rather than queued, because a wink is never worth
     delaying a real repaint for.
     */
    private func startOverflowWink() {
        overflowWinkTask?.cancel()
        overflowWinkTask = Task { [weak self] in
            while !Task.isCancelled {
                let every = self?.model.preferences.overflow.winkEveryMs ?? 3000
                try? await Task.sleep(for: .milliseconds(every))
                guard let self, !Task.isCancelled else { return }
                await self.winkOverflowKey()
            }
        }
    }

    private func winkOverflowKey() async {
        let overflow = model.preferences.overflow
        guard OverflowLook.winkAllowed(
            settings: overflow,
            transition: model.preferences.workspaceTransition,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ) else { return }
        guard deviceIsOpen, !isPainting, calibrationTask == nil, countdown?.isRunning != true,
              let key = padView.overflowKey,
              let entry = padView.sessionID(forKey: key).flatMap({ registry.entry(forSession: $0) }),
              let origin = PadView.workspace(of: entry, worktrees: supersetWorktrees)
        else { return }
        let color = WorkspaceColors.color(
            for: origin,
            identity: model.preferences.workspaceIdentity,
            stateColors: model.appearances.values.map(\.color)
        )
        let calibration = model.calibration

        isPainting = true
        let wink = PadPaint.keyBatch(
            [key: OverflowLook.wink(origin: color, settings: overflow)],
            calibration: calibration, transport: device
        ).batch
        let back = PadPaint.keyBatch(
            [key: keyLooks()[key]?.look ?? .off], calibration: calibration, transport: device
        ).batch
        if (try? await device.write(batch: wink)) != nil {
            try? await Task.sleep(for: .milliseconds(overflow.winkMs))
            try? await device.write(batch: back)
        }
        isPainting = false
        // Anything that changed during the wink — the key may no longer be borrowed.
        if repaintWanted {
            repaintWanted = false
            await paint()
        }
    }

    private func composePadView() -> PadView {
        PadView.compose(
            entries: registry.entries, context: boardContext, worktrees: supersetWorktrees,
            borrowOverflow: model.preferences.overflow.enabled
        )
    }

    private static func describe(_ context: BoardContext) -> String {
        switch context {
        case .all: return "all sessions"
        case let .superset(workspaceID): return "workspace \(workspaceID.prefix(8))"
        }
    }

    /**
     Move to the next or previous lit key, and raise it (BRANCH).

     Walks the keys the pad is showing — `padView.nextKey` — not the registry: in a
     workspace context stepping through every slot would walk out of the workspace in
     front. Wraps, skips dark keys and never lands on the key lent to another
     workspace.

     Starts from the key of whatever is focused, so it walks from where you are rather
     than from key 1 every time.
     */
    private func stepSession(forward: Bool) {
        // The published flag rather than a second comparison of its own: this used to
        // match a tty by suffix while `publish` matched it exactly, so the two could
        // disagree about which slot you were in, and only one of them painted.
        let focusedSession = model.slots.first { $0.isLive && $0.cwd != nil && $0.isFocused }?.sessionID
        let current = focusedSession.flatMap { id in padView.keys.first { $0.value == id }?.key }
        guard let next = padView.nextKey(from: current, forward: forward) else {
            Log.write("key BRANCH: no sessions to step to")
            return
        }
        Log.write("key BRANCH: \(current.map { "key \($0)" } ?? "nothing focused") -> key \(next)")
        jump(fromPadKey: next)
    }

    /**
     APPR held: go to the session that has waited on you the longest, in any
     workspace (F6 v1 — from the registry's own transitions).

     A restored, still-unconfirmed session is not a candidate: its "waiting" is what
     the file said before the restart, and jumping to it would be trusting exactly
     what the unconfirmed look is there to distrust.
     */
    private func jumpOldestWaiting(key: String) {
        // v2: with the host-service up, a bus session (no hooks) is dated by the
        // moment Superset saw its prompt or failure — `lastEventAt` — rather than by
        // when this app first heard of it, which after a launch sync is "just now".
        guard let client = superset?.client else {
            pickOldestWaiting(key: key, busSince: [:])
            return
        }
        Task { [weak self] in
            let bindings = (try? await client.agents(workspaceID: nil)) ?? []
            var since: [String: Date] = [:]
            for binding in bindings where binding.lastEventType == .permissionRequest || binding.lastEventType == .failed {
                if let at = binding.lastEventAt { since[binding.terminalID] = at }
            }
            self?.pickOldestWaiting(key: key, busSince: since)
        }
    }

    private func pickOldestWaiting(key: String, busSince: [String: Date]) {
        let candidates = registry.entries
            .filter { !$0.isUnconfirmed }
            .map { entry in
                let since = entry.isBusBorn
                    ? entry.supersetTerminalID.flatMap { busSince[$0] } ?? entry.stateSince
                    : entry.stateSince
                return OldestWaiting.Candidate(sessionID: entry.sessionID, state: entry.state, since: since)
            }
        guard let pick = OldestWaiting.pick(candidates),
              let entry = registry.entry(forSession: pick.sessionID) else {
            Log.write("key \(key): nothing is waiting")
            return
        }
        let waited = Int(Date().timeIntervalSince(pick.since))
        Log.write("key \(key): oldest waiting is \(describeKey(slot: entry.slot)) (\(pick.state.rawValue) for \(waited)s)")
        jump(to: entry.slot)
    }

    // MARK: - two-step confirmation (F4)

    /// What a key means to a pending confirmation; nil lets it through (a release,
    /// the dial's turn), which must never be swallowed.
    private func confirmationInput(for intent: KeyDispatcher.Intent) -> PendingConfirmation.Input? {
        switch intent {
        case let .action(action, key):
            return action == .approve ? .approve : .other(key: key)
        case let .actionPressed(key):
            // APPR has a long press, so it arrives here: the press alone confirms.
            return controlMap.taps[key] == .approve ? .approve : .other(key: key)
        case let .jump(slot):
            return .other(key: "AG\(slot)")
        case .encoderPressed:
            return .other(key: "ENC_CLK")
        case .release, .scroll:
            return nil
        }
    }

    /**
     Ask "are you sure?" on the ring for `confirm.windowMs`. Only one at a time: arming
     another replaces the first. Lapsing does nothing but put the ring back.
     */
    private func armConfirmation(_ action: PendingAction) {
        let look = model.preferences.confirm
        pendingConfirmation = PendingConfirmation(window: Double(look.windowMs) / 1000)
        pendingConfirmation.arm(action, now: Date())
        Log.write("confirm: \(Self.describe(action)) armed for \(look.windowMs)ms — APPR confirms, any other key cancels")
        play(
            show: Shows.confirm(color: look.color, effect: look.effect, brightness: look.brightness, milliseconds: look.windowMs),
            priority: .confirm
        )
        confirmExpiryTask?.cancel()
        confirmExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(look.windowMs + 20))
            guard let self, !Task.isCancelled else { return }
            if let lapsed = self.pendingConfirmation.expire(now: Date()) {
                Log.write("confirm: \(Self.describe(lapsed)) lapsed — nothing ran")
                self.endConfirmShow()
            }
        }
    }

    private func resolveConfirmation(_ outcome: PendingConfirmation.Outcome) {
        confirmExpiryTask?.cancel()
        confirmExpiryTask = nil
        switch outcome {
        case .passThrough:
            return
        case let .confirmed(action):
            endConfirmShow()
            Log.write("confirm: \(Self.describe(action)) confirmed")
            execute(action)
        case let .cancelled(action):
            endConfirmShow()
            Log.write("confirm: \(Self.describe(action)) cancelled — the key did nothing else")
        }
    }

    private func execute(_ action: PendingAction) {
        switch action {
        case .probe:
            Log.write("confirm: probe — a test, nothing runs")
        case .handoff:
            runHandoff(action)
        }
    }

    /// The question is gone: the ring must stop asking it.
    private func endConfirmShow() { endShow(named: "confirm") }

    /// Stop a show early if it is the one running, and hand the ring back.
    private func endShow(named name: String) {
        guard runningShow == name else { return }
        showToken += 1
        runningShow = nil
        runningShowPriority = nil
        model.runningShow = nil
        ringBusyUntil = .distantPast
        Task { await paint() }
    }

    private static func describe(_ action: PendingAction) -> String {
        switch action {
        case .probe: "probe"
        case let .handoff(terminal, _, agent): "handoff to \(agent) [\(terminal.prefix(8))]"
        }
    }

    /// "Try on the pad": plays the confirmation light and arms the harmless probe, so
    /// APPR / another key / waiting can all be tried without anything running.
    func previewConfirm() {
        guard deviceIsOpen else { return }
        armConfirmation(.probe)
    }

    /// "Try the sweep": the ring part of a workspace switch, in the current
    /// workspace's color (or the palette's first), with the configured style.
    func previewWorkspaceSweep() {
        let settings = model.preferences.workspaceTransition
        let workspace: String? = if case let .superset(id) = boardContext { id } else { supersetFocus.winner?.workspaceID }
        let color = workspace.map {
            WorkspaceColors.color(
                for: $0, identity: model.preferences.workspaceIdentity,
                stateColors: model.appearances.values.map(\.color)
            )
        } ?? model.preferences.workspaceIdentity.palette.first ?? RGB(0xFFFFFF)
        let show = settings.style == .cut
            ? Shows.workspaceCut(color: color)
            : Shows.workspaceSweep(color: color, settings: settings)
        Log.write("preview: workspace \(settings.style.rawValue)")
        _ = play(show: show, priority: .workspace)
    }

    // MARK: - targeted control (F7)

    /// FAST held (D10): arm a send of `targeted.defaultSnippet` for the next agent key.
    private func armTargeting(key: String) {
        let targeted = model.preferences.targeted
        guard targeted.mode == .armed else {
            // Chord mode would delay every jump to the release; not built (D10).
            Log.write("key \(key): targeted mode '\(targeted.mode.rawValue)' is not available — use 'armed'")
            return
        }
        targetArming = TargetArming(window: Double(targeted.windowMs) / 1000, snippet: targeted.defaultSnippet)
        handleTargeting(targetArming.arm(now: Date()))
    }

    private func handleTargeting(_ step: TargetArming.Step) {
        switch step {
        case .none:
            return
        case let .armed(intent):
            let targeted = model.preferences.targeted
            let color = intent == .interrupt
                ? (model.appearances[.error] ?? SessionState.error.defaultAppearance).color
                : model.preferences.confirm.color
            // The text is not logged: only which kind is armed.
            Log.write("targeted: armed \(Self.describe(intent)) — press an agent key\(intent == .interrupt ? "" : " (REJ: interrupt instead)")")
            endShow(named: "targeted")
            _ = play(
                show: Shows.targetArmed(color: color, brightness: model.preferences.confirm.brightness, milliseconds: targeted.windowMs),
                priority: .confirm
            )
            targetExpiryTask?.cancel()
            targetExpiryTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(targeted.windowMs + 20))
                guard let self, !Task.isCancelled else { return }
                if self.targetArming.expire(now: Date()) == .cancelled {
                    Log.write("targeted: lapsed — nothing sent")
                    self.endShow(named: "targeted")
                }
            }
        case let .fire(intent, padKey):
            targetExpiryTask?.cancel()
            endShow(named: "targeted")
            fireTargeted(intent, padKey: padKey)
        case .cancelled:
            targetExpiryTask?.cancel()
            endShow(named: "targeted")
            Log.write("targeted: cancelled — the key did nothing else")
        }
    }

    private static func describe(_ intent: TargetedControl.Intent) -> String {
        switch intent {
        case .interrupt: "interrupt"
        case .send: "send"
        }
    }

    /// An agent key while armed: aim at that key's session, without jumping to it.
    private func fireTargeted(_ intent: TargetedControl.Intent, padKey: Int) {
        guard let entry = padView.sessionID(forKey: padKey).flatMap({ registry.entry(forSession: $0) }) else {
            refuseTargeted("key \(padKey) has no session")
            return
        }
        target(intent, at: entry, label: describeKey(slot: entry.slot))
    }

    /// REJ held: interrupt the session in front of you.
    private func interruptFocused(key: String) {
        guard let focused = model.slots.first(where: { $0.isLive && $0.isFocused }),
              let sessionID = focused.sessionID,
              let entry = registry.entry(forSession: sessionID) else {
            refuseTargeted("\(key): no focused session to interrupt")
            return
        }
        target(.interrupt, at: entry, label: describeKey(slot: entry.slot))
    }

    /**
     Snapshot, plan and send through the host-service (`TargetedRun.fire`). Only the
     outcome is logged — "sent N bytes to key K" — never the snapshot or the text.
     */
    private func target(_ intent: TargetedControl.Intent, at entry: SessionRegistry.Entry, label: String) {
        guard let client = superset?.client else {
            refuseTargeted("\(label): the Superset host client is off or not connected")
            return
        }
        guard let terminal = entry.supersetTerminalID, let workspace = entry.supersetWorkspaceID else {
            refuseTargeted("\(label): not a Superset terminal")
            return
        }
        let limits = model.preferences.targeted
        let sessionID = entry.sessionID
        Task { [weak self] in
            let report = await TargetedRun.fire(
                intent, terminalID: terminal, workspaceID: workspace, host: client, limits: limits
            )
            guard let self else { return }
            // The only line logged: sizes and reasons, never the text or the screen.
            Log.write(TargetedRun.logLine(report, intent: intent, label: label))
            switch report {
            case .done:
                if intent == .interrupt {
                    // Agents fire no hook on ⎋: the key would stay "working" otherwise.
                    let previous = self.registry.entry(forSession: sessionID)?.state
                    self.registry.setState(sessionID: sessionID, to: .idle)
                    self.publish()
                    self.fireLap(from: previous, sessionID: sessionID)
                    await self.paint()
                }
            case .refused, .failed:
                _ = self.play(show: Shows.refused(), priority: .confirm)
            }
        }
    }

    private func refuseTargeted(_ why: String) {
        Log.write("targeted: refused — \(why)")
        _ = play(show: Shows.refused(), priority: .confirm)
    }

    // MARK: - handoff (F8)

    /// Where the pending handoff comes from, as the log names it ("key 2 · app").
    private var handoffLabel = ""

    /**
     CODEX held: propose handing the focused Superset terminal to `launch.handoffAgent`.
     Nothing runs yet — the ring asks, and only APPR goes on (`PendingConfirmation`).
     Without a client, in read-only, or with no Superset terminal in front: the amber
     blink, and no call at all.
     */
    private func armHandoff(key: String) {
        guard superset?.client != nil else {
            refuseHandoff("\(key): the Superset host client is off or not connected")
            return
        }
        switch model.supersetLink {
        case .versionMismatch, .connected(_, true):
            refuseHandoff("\(key): read-only — the Superset version is not the tested one")
            return
        default:
            break
        }
        let focused = model.slots.first { $0.isLive && $0.isFocused }
        let entry = focused?.sessionID.flatMap { registry.entry(forSession: $0) }
        let source = entry.flatMap { entry -> (terminalID: String, workspaceID: String)? in
            guard let terminal = entry.supersetTerminalID, let workspace = entry.supersetWorkspaceID else { return nil }
            return (terminal, workspace)
        }
        guard let entry,
              let action = LaunchPolicy.handoff(focused: source, agent: model.preferences.launch.handoffAgent) else {
            refuseHandoff("\(key): no focused Superset terminal to hand off")
            return
        }
        handoffLabel = describeKey(slot: entry.slot)
        armConfirmation(action)
    }

    /// APPR confirmed it: transcript → prompt → `agents.run`. Logs one line of sizes
    /// (`Handoff.logLine`), never the transcript or the prompt.
    private func runHandoff(_ action: PendingAction) {
        guard let client = superset?.client else {
            refuseHandoff("\(handoffLabel): the Superset host client went away")
            return
        }
        let label = handoffLabel
        let contextChars = model.preferences.launch.handoffContextChars
        Task { [weak self] in
            guard let report = await Handoff.run(after: .confirmed(action), host: client, contextChars: contextChars)
            else { return }
            Log.write(Handoff.logLine(report, label: label))
            if case .launched = report { return }
            _ = self?.play(show: Shows.refused(), priority: .confirm)
        }
    }

    private func refuseHandoff(_ why: String) {
        Log.write("handoff refused — \(why)")
        _ = play(show: Shows.refused(), priority: .confirm)
    }

    // MARK: - NEW (F5)

    /**
     NEW: a bare agent (`launch.newAgent`, prompt empty) in the Superset workspace in
     front — no confirmation (D2), but a cooldown so one bouncy press never opens two.
     Outside a Superset workspace it does nothing and blinks the ring amber.
     */
    private func launchNewAgent(key: String) {
        guard let client = superset?.client else {
            Log.write("key \(key): NEW needs the Superset host client (off or not connected)")
            _ = play(show: Shows.noWorkspace(), priority: .confirm)
            return
        }
        // The workspace in front, whatever the pad's scope: with Superset in front the
        // newest focus signal names it.
        let context: BoardContext = front == .superset
            ? supersetFocus.winner.map { .superset(workspaceID: $0.workspaceID) } ?? .all
            : .all
        let agent = model.preferences.launch.newAgent
        guard let call = LaunchPolicy.newAgent(context: context, agent: agent) else {
            Log.write("key \(key): NEW — no Superset workspace in front")
            _ = play(show: Shows.noWorkspace(), priority: .confirm)
            return
        }
        guard launchCooldown.admit(now: Date()) else {
            Log.write("key \(key): NEW ignored — inside the \(launchCooldownMs)ms cooldown")
            return
        }
        let workspace: String = if case let .superset(id) = context { String(id.prefix(8)) } else { "?" }
        Log.write("key \(key): launching \(agent) in workspace \(workspace)")
        Task { [weak self] in
            do {
                try await client.perform(call)
                Log.write("key \(key): \(agent) launched in workspace \(workspace)")
            } catch {
                Log.write("key \(key): launch failed — \(Self.describe(error))")
                _ = self?.play(show: Shows.noWorkspace(), priority: .confirm)
            }
        }
    }

    /// An error for the log: the client's own cases, or a code — never a description
    /// that could carry the endpoint.
    private static func describe(_ error: Error) -> String {
        if let error = error as? SupersetClientError { return "\(error)" }
        if let error = error as? URLError { return "network error \(error.code.rawValue)" }
        return "error \((error as NSError).code)"
    }

    /**
     A registry slot as the person at the pad sees it: "key 2 · my-app".

     The slot number is internal — in a workspace context key 2 can be slot 5 — so
     the log and the popover speak in keys, with the workspace (or folder) to tell
     two boards apart. A session the pad is not showing says so.
     */
    private func describeKey(slot: Int) -> String {
        guard let entry = registry.occupancy().first(where: { $0.slot == slot })?.entry else {
            return "slot \(slot)"
        }
        let key = padView.keys.first { $0.value == entry.sessionID }?.key
        return SlotView.keyLabel(padKey: key, place: place(of: entry))
    }

    /// The workspace's folder for a Superset session, else the session's own folder.
    private func place(of entry: SessionRegistry.Entry) -> String? {
        if let workspace = PadView.workspace(of: entry, worktrees: supersetWorktrees),
           let path = supersetWorktrees[workspace] {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return entry.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// Re-read the tab titles, and republish only if one changed.
    ///
    /// On the presence cycle rather than on every repaint: it is an Apple Event per
    /// call, and a title changes when a session changes topic — minutes, not frames.
    private func refreshTerminalTitles() async {
        let titles = await TerminalTitles.read()
        guard titles != terminalTitles else { return }
        terminalTitles = titles
        publish()
    }

    /// Re-read cmux's surfaces, and republish only if something changed.
    ///
    /// On the same cycle and for the same reason as the tab titles: it is a subprocess
    /// per call, and what it answers — which surface a session is in, and what that
    /// surface is called — changes when someone moves a tab or a session changes topic.
    ///
    /// Skipped entirely when cmux is not running, so a user who does not have it never
    /// pays for a process spawn every few seconds.
    private func refreshCmuxSurfaces() async {
        guard Focus.isRunning(bundleID: Cmux.bundleID), let cli = Focus.cmuxCLI else {
            guard !cmuxSurfaces.isEmpty else { return }
            cmuxSurfaces = [:]
            publish()
            return
        }
        /*
         Kept to the sessions on the board, not everything cmux is running.

         cmux's tree holds every process in every surface — language servers,
         `caffeinate`, whatever a session shelled out to a second ago — and on a working
         machine that set changes several times a *second*. Storing all of it made the
         "did anything change" comparison below true on almost every cycle, so the board
         republished and rewrote the registry file continuously for churn no row could
         ever display. Nothing reads this map except by a session's pid.
        */
        let sessionPIDs = Set(registry.entries.compactMap(\.pid))
        let surfaces = await Task.detached { Cmux.surfaces(cli: cli) }.value
            .filter { sessionPIDs.contains($0.key) }

        /*
         Logged on change, like `device present`.

         What is worth reading is what the board resolved: which slot is in which
         surface, and under what name. Those are the two things "the cmux row will not
         jump" and "the cmux row has the wrong name" are asking about, and both are
         otherwise invisible.
        */
        let placed = registry.entries
            .sorted { $0.slot < $1.slot }
            .compactMap { entry -> String? in
                guard let pid = entry.pid, let surface = surfaces[pid] else { return nil }
                let name = surface.title.flatMap(TerminalTitle.clean) ?? "unnamed"
                return "\(entry.slot):\(pid)→\(surface.ref) “\(name)”"
            }
        lastCmuxLog = Log.changed(
            "cmux", last: lastCmuxLog,
            to: placed.isEmpty
                ? "reachable, no session on the board is in it"
                : placed.joined(separator: ", ")
        )
        guard surfaces != cmuxSurfaces else { return }
        cmuxSurfaces = surfaces
        publish()
    }

    /**
     Whether this entry is the session in front of you.

     Two surfaces, matched on what each one actually exposes. A Terminal tab carries the
     session's tty, which is exact. A VS Code window carries its active tab's name, and
     the extension names that tab after the session — so the match is on the name the
     board is already showing in the row, and a chat too young to have been named simply
     does not match rather than matching the wrong one.
     */
    private func isFocused(_ entry: SessionRegistry.Entry, name: String?) -> Bool {
        switch focused {
        case let .terminal(tty):
            return entry.tty == tty
        case let .cmux(surface):
            // By pid, because that is the only thing both sides have: cmux does not
            // expose a tty for a surface, and the registry does not know a surface id
            // until this map is read.
            return entry.pid.flatMap { cmuxSurfaces[$0]?.id } == surface
        case let .vscode(windowTitle):
            guard entry.entrypoint == "claude-vscode", let name else { return false }
            return WindowTitle.names(name, in: windowTitle)
        case .elsewhere:
            return false
        }
    }

    /// What the row calls this session — the tab title where the host offers one, and
    /// Claude Code's own name otherwise. Shared by `publish` and the focus match so the
    /// two cannot disagree about what a session is called.
    ///
    /// cmux carries the same titles Terminal does, because it is Claude Code that writes
    /// them; they arrive with the same spinner glyph in front and go through the same
    /// `TerminalTitle.clean`.
    private func name(of entry: SessionRegistry.Entry) -> String? {
        entry.tty.flatMap { terminalTitles[$0] }
            ?? entry.pid.flatMap { cmuxSurfaces[$0]?.title }.flatMap(TerminalTitle.clean)
            ?? SessionTitle.forSession(transcriptPath: entry.transcriptPath)
    }

    /// One line for the log. A window title is long and a tty is not, so the title is
    /// clipped rather than allowed to push the matched slot off the end of the line.
    private static func describe(_ surface: FocusedSurface) -> String {
        switch surface {
        case let .terminal(tty): return tty
        case let .cmux(surface): return "cmux \(surface)"
        case let .vscode(windowTitle): return "vscode “\(windowTitle.prefix(60))”"
        case .elsewhere: return "elsewhere"
        }
    }

    private func ambientSide() -> CodexProtocol.LightingSide {
        /*
         Dictation owns the ring while it runs.

         Above every mode, `off` included: this is not a summary of the board, it is
         feedback that the machine is listening to you right now — the one moment where
         a light that is otherwise dark by design has something urgent to say. It ends
         the moment the belief does, and the belief is bounded. See `VoiceSignal`.
        */
        if model.preferences.ambient.voiceRainbow, voiceIsActive {
            lastAmbientLog = Log.changed("ring", last: lastAmbientLog, to: "voice: rainbow")
            return CodexProtocol.LightingSide(
                color: RGB(0xFFFFFF), brightness: 1, effect: .rainbow, speed: 0.75
            )
        }

        let mode = Ambient.Mode(rawValue: model.preferences.ambient.mode) ?? .events
        // The whole registry, whatever the keys are showing: a prompt in another
        // workspace must still be able to light the ring.
        let states = padView.ringStates
        guard let resolved = Ambient.resolve(
            states: states, mode: mode, appearances: model.appearances,
            // Without this, `fixed` resolves to nothing and the ring is silently dark —
            // a mode that is documented, selectable, and does nothing.
            fixed: model.preferences.ambient.fixed
        ) else { return .off }

        // Logged on change, because a ring that is dark by design and one that is dark
        // by bug look identical — the same trap the config path fell into.
        lastAmbientLog = Log.changed(
            "ring", last: lastAmbientLog,
            // Describe the *appearance*, not the state: in fixed mode there is no
            // winning state, and reading "dark" beside a lit color is worse than no
            // log at all.
            to: resolved.appearance.effect == .off
                ? "\(mode.rawValue): dark"
                : "\(mode.rawValue): \(resolved.state?.rawValue ?? "held") "
                    + "\(resolved.appearance.color.hex)@"
                    + "\(Int(resolved.appearance.brightness * 100))% "
                    + "\(resolved.appearance.effect.rawValue)"
        )

        let appearance = resolved.appearance
        return CodexProtocol.LightingSide(
            color: appearance.color,
            brightness: appearance.brightness,
            effect: CodexProtocol.Effect(rawValue: appearance.effect.deviceCode) ?? .solid,
            speed: appearance.speed
        )
    }

    /**
     Bring the settings window up from a key press.

     `showSettingsWindow:` goes through the responder chain, and an `.accessory` app
     with no Dock icon and no key window frequently has nobody in that chain to receive
     it — `sendAction` returns false and nothing happens, silently. That is exactly what
     the dial did: the press was dispatched and logged, and no window appeared.
     Activating first puts something in the chain.

     There is deliberately **no fallback that hunts for the window and orders it front**.
     An earlier version had one, and logging the app's actual window list disproved it:
     even with Settings open, `NSApp.windows` holds only `NSStatusBarWindow` and
     `MenuBarExtraWindow`. SwiftUI's `Settings` scene simply is not there to be found,
     so that code could never have run — and a fallback that cannot fire is worse than
     none, because it reads as a safety net.
     */
    private func openSettingsWindow() {
        /*
         An injected closure, not `NSApp.delegate as? AppDelegate`.

         That cast silently returned nil from here — SwiftUI's
         `NSApplicationDelegateAdaptor` does not guarantee that `NSApp.delegate` is your
         own type — so the dial logged "settings: opened" and opened nothing. The same
         call worked from `applicationShouldHandleReopen`, which is *inside* the
         delegate and never needed the cast, and that difference is what made it look
         like the hold was broken rather than the plumbing.

         A closure cannot be nil-by-surprise: it is either wired at start or it is not,
         and the log says which.
         */
        guard let openSettings else {
            Log.write("settings: FAILED — no opener wired")
            return
        }
        openSettings()
    }

    /**
     Report a turn of the dial, once per gesture.

     Rotation was the only input that produced no trace at all, which made "did the
     encoder do anything?" unanswerable after the fact — the same blind spot that hid a
     dark ring and an unnamed session earlier.

     Summarised rather than logged per tick: a single turn emits ticks every few
     milliseconds, and one line each would bury everything else. The ticks are collected
     and written out once the turn stops.
     */
    private func noteScroll(_ lines: Int) {
        scrolledLines += lines
        scrollSummary?.cancel()
        scrollSummary = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, self.scrolledLines != 0 else { return }
            let total = self.scrolledLines
            self.scrolledLines = 0
            Log.write("encoder: scrolled \(abs(total)) lines \(total > 0 ? "up" : "down")")
        }
    }

    /**
     The dial went down.

     The long action fires *while still held* rather than on release. Classifying on
     release feels broken: you hold the dial, nothing happens, you let go, and the
     window appears afterwards — with no way to know whether you held it long enough,
     so people release early and get the wrong action.
     */
    private func encoderPressed() {
        encoderClick.threshold = model.preferences.encoder.longPressInterval
        encoderClick.press()
        encoderHoldTask?.cancel()
        encoderHoldTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.encoderClick.threshold))
            guard !Task.isCancelled, self.encoderClick.shouldFireLong() else { return }
            if let question = self.currentQuestion(),
               case let .key(tab) = QuestionMode.dial(.hold, pendingTool: question.pendingTool) {
                self.sendQuestionKey(tab, from: "ENC")
                return
            }
            // Per app: with Superset in front the hold opens its command palette.
            let long = self.controlMap.encoderLong
            guard let action = long.action else { return }
            Log.write("key ENC: held past \(Int(self.encoderClick.threshold * 1000))ms")
            self.perform(action, key: long.payloadKey)
        }
    }

    /**
     An action cap with a long press went down (F2).

     Like the dial, the hold fires *while still held*, once the threshold passes —
     not on release. The timer wakes a little past the threshold (`holdPollDelay`) so
     a sleep that ends a hair early does not read as "not yet" and leave the hold to
     the release. The tap, when it was short, fires on release.
     */
    private func actionPressed(_ key: String) {
        _ = pressTracker.press(key, hasLongBinding: true, now: Date())
        holdTasks[key]?.cancel()
        let delay = controlMap.holdPollDelay
        holdTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard let self, !Task.isCancelled else { return }
            self.holdTasks[key] = nil
            while let emit = self.pressTracker.poll(now: Date()) {
                self.fire(emit, stillDown: true)
            }
        }
    }

    /// Any key came back up. Only a cap the tracker is timing resolves here: a tap if
    /// it was short, or a hold whose timer ran late.
    private func actionReleased(_ key: String) {
        guard let emit = pressTracker.release(key, now: Date()) else { return }
        holdTasks.removeValue(forKey: key)?.cancel()
        fire(emit, stillDown: false)
    }

    private func fire(_ emit: ActionPressTracker.Emit, stillDown: Bool) {
        switch emit {
        case let .tap(cap), let .hold(cap):
            if ignoredInQuestionMode(cap) { return }
        }
        switch emit {
        case let .tap(cap):
            guard let action = controlMap.taps[cap] else {
                Log.write("key \(cap): unassigned")
                return
            }
            // Already released: nothing can be held any more.
            perform(action, key: cap, holdKey: nil)
        case let .hold(cap):
            guard let hold = controlMap.hold(cap), let action = hold.action else { return }
            Log.write("key \(cap): held past \(Int(controlMap.longPressThreshold * 1000))ms")
            perform(action, key: hold.payloadKey, holdKey: stillDown ? cap : nil)
        }
    }

    /// The dial came back up. Fires the press action only if the hold did not already
    /// take over — otherwise one press would fire both bindings.
    private func encoderReleased() {
        encoderHoldTask?.cancel()
        encoderHoldTask = nil
        switch encoderClick.release() {
        case .short:
            if let question = currentQuestion(),
               case let .key(space) = QuestionMode.dial(.click, pendingTool: question.pendingTool) {
                sendQuestionKey(space, from: "ENC")
                return
            }
            guard let action = model.preferences.encoder.click else { return }
            perform(action, key: "ENC")
        case .handled, .spurious:
            break
        }
    }

    /**
     Click the status item, so the dial opens the same panel a mouse would.

     `MenuBarExtra` gives no programmatic way to open its window — the scene owns the
     `NSStatusItem` and does not expose it. So the button is found in the status bar
     window and clicked, which is what a real click does and therefore behaves
     identically, including closing again on a second press.
     */
    private func openMenuBarPopover() {
        clickStatusItem(reason: "opened the dropdown")
    }

    /**
     Close the dropdown, for a row that opens one of *our* windows.

     Activating another application dismisses the panel by itself, which is why
     jumping to a chat needs nothing here. Settings does: it is this app's own window,
     the panel never resigns to it, and the menu is left hanging over the thing it just
     opened.

     A click, because the click is what the panel listens to — the same route the dial
     already uses, and the same reason: `MenuBarExtra` owns its `NSStatusItem` and
     exposes no way to close it.

     **Only safe from inside the open panel.** The click is a toggle, so calling this
     when nothing is showing would *open* the menu instead. That is why it is a
     separate command from `openSettings`, which the dial's long press also calls with
     no panel on screen.
     */
    func dismissMenuBarPopover() {
        clickStatusItem(reason: "closed the dropdown")
    }

    private func clickStatusItem(reason: String) {
        for window in NSApp.windows {
            guard let button = Self.statusButton(in: window.contentView) else { continue }
            button.performClick(nil)
            Log.write("menu: \(reason)")
            return
        }
        Log.write("menu: FAILED — no status item button found")
    }

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for child in view.subviews {
            if let found = statusButton(in: child) { return found }
        }
        return nil
    }

    /// Every key dark, without forgetting anything.
    private func allKeysOff() async {
        guard deviceIsOpen else { return }
        let dark = Dictionary(uniqueKeysWithValues: (1...BoardLayout.slotCount).map { ($0, Appearance.off) })
        let batch = PadPaint.keyBatch(dark, calibration: model.calibration, transport: device).batch
        guard !batch.isEmpty else { return }
        try? await device.write(batch: batch)
    }

    /// Release the socket and the device handle. Without this the socket file is left
    /// behind and the next launch has to clear it before it can bind.
    func stop() {
        reassertTask?.cancel()
        reassertTask = nil
        livenessTask?.cancel()
        livenessTask = nil
        overflowWinkTask?.cancel()
        overflowWinkTask = nil
        // Before anything else: a key left logically down outlives this process and
        // corrupts every keystroke on the machine afterwards.
        pushToTalk.releaseIfHeld()
        focusWatcher?.stop()
        // The board survives a restart. Saved on the way out *and* after every change,
        // because a crash never reaches this line.
        RegistryStore.save(registry)
        closeDeviceSync()
        tearDownSuperset(releaseBusSessions: false)
        Task { await hooks.stop() }
    }

    // MARK: - Superset host-service (F3)

    /**
     Bring the connection in line with `superset.*`: build it when `hostClient` is
     `auto`, drop it when `off`, rebuild it when any of its settings changed. Called at
     launch and on every settings edit, so the switch works live. A no-op when nothing
     changed — an unrelated edit must not drop the socket.
     */
    private func configureSuperset(force: Bool = false) {
        let config = model.preferences.superset
        guard config.hostClient == .auto else {
            if superset != nil {
                tearDownSuperset(releaseBusSessions: true)
                Log.write("superset: host client off — hooks and deep links only")
            }
            model.supersetLink = .off
            return
        }
        if !force, superset?.config == config { return }
        tearDownSuperset(releaseBusSessions: false)

        lifecycle = LifecycleMapper(
            startDebounce: Double(config.startDebounceMs) / 1000,
            dedupeWindow: Double(config.dedupeWindowMs) / 1000
        )
        let transport = SupersetConnection()
        // The manifest loader registers the token with the log redactor on every read,
        // before anything can log (SupersetConnection.loadManifest).
        let client = SupersetConnection.makeClient(config, transport: transport)
        let events: SupersetEventStream? = config.events
            ? transport.events(orgID: config.orgID) { message in
                Task { @MainActor [weak self] in self?.handleBus(message) }
            }
            : nil
        superset = SupersetLink(config: config, transport: transport, client: client, events: events)
        model.supersetLink = .searching
        Log.write("superset: host client on (events \(config.events ? "on" : "off"), tested \(config.testedVersion))")
        if let events { Task { await events.start() } }
        startSupersetHealth(client)
    }

    /// Drop the connection. Bus sessions lose their only source of truth with it, so
    /// switching the client off also gives their keys back.
    private func tearDownSuperset(releaseBusSessions: Bool) {
        supersetHealthTask?.cancel()
        supersetHealthTask = nil
        lifecycleFlushTask?.cancel()
        lifecycleFlushTask = nil
        bindingsRefreshTask?.cancel()
        bindingsRefreshTask = nil
        if let events = superset?.events { Task { await events.stop() } }
        superset = nil
        if releaseBusSessions,
           registry.syncBus(bindings: [], hookedAgents: Self.hookedAgents) {
            Log.write("superset: bus sessions released (client off)")
            publish()
            Task { await paint() }
        }
    }

    /// "Reconnect" in the Superset pane: forget the socket and the manifest, start over.
    func reconnectSuperset() {
        Log.write("superset: reconnect requested")
        configureSuperset(force: true)
    }

    /**
     `health.check` on a loop: the link state the pane shows, the version gate, and
     the moment to (re)read `terminalAgents.list` — at launch (reconciliation) and
     whenever the link comes back (Superset restarted on a new port).
     */
    private func startSupersetHealth(_ client: SupersetHostClient) {
        supersetHealthTask = Task { [weak self] in
            var wasConnected = false
            while !Task.isCancelled {
                let version = try? await client.health()
                let state = await client.state
                guard let self, !Task.isCancelled else { return }
                self.model.supersetLink = state
                self.lastLinkLog = Log.changed("superset link", last: self.lastLinkLog, to: Self.describe(state))
                let connected = version != nil
                if connected, !wasConnected {
                    await self.syncWithSuperset(client, launch: !self.reconciledAtLaunch)
                    self.reconciledAtLaunch = true
                }
                wasConnected = connected
                try? await Task.sleep(for: .seconds(connected ? 30 : 5))
            }
        }
    }

    private static func describe(_ state: SupersetLinkState) -> String {
        switch state {
        case .off: "off"
        case .searching: "searching"
        case let .connected(version, readOnly): "connected \(version)\(readOnly ? " (read-only)" : "")"
        case let .versionMismatch(found, tested): "version \(found) ≠ tested \(tested) — read-only"
        case let .unreachable(reason): "unreachable (\(reason))"
        }
    }

    /**
     Read `terminalAgents.list` and fold it into the board: at launch, confirm or end
     what the file restored (`Reconciler`); every time, give bus sessions (agents
     without our hooks) a key or take it back (`SessionRegistry.syncBus`).
     */
    private func syncWithSuperset(_ client: SupersetHostClient, launch: Bool) async {
        guard let bindings = try? await client.agents(workspaceID: nil) else {
            Log.write("superset: terminalAgents.list failed — board left as it is")
            return
        }
        var summary: [String] = ["\(bindings.count) binding(s)"]
        if launch, model.preferences.superset.reconcileOnLaunch {
            let unconfirmed = registry.entries.filter(\.isUnconfirmed)
                .map { (sessionID: $0.sessionID, terminalID: $0.supersetTerminalID) }
            let outcomes = Reconciler.reconcile(unconfirmed: unconfirmed, bindings: bindings)
            registry.apply(outcomes)
            let ended = outcomes.filter { if case .end = $0 { true } else { false } }.count
            summary.append("reconciled \(outcomes.count - ended) confirmed, \(ended) ended")
        }
        if registry.syncBus(bindings: bindings, hookedAgents: Self.hookedAgents) {
            fillBusSessionFolders()
            summary.append("bus sessions updated")
        }
        Log.write("superset: synced — " + summary.joined(separator: ", "))
        publish()
        requestBusPaint()
    }

    /// A bus session has no cwd of its own; its workspace's worktree names it in the
    /// popover.
    private func fillBusSessionFolders() {
        for entry in registry.entries where entry.isBusBorn && entry.cwd == nil {
            guard let workspace = entry.supersetWorkspaceID,
                  let path = supersetWorktrees[workspace] ?? openSupersetDB()?.worktrees()[workspace]
            else { continue }
            registry.enrich(sessionID: entry.sessionID, cwd: path)
        }
    }

    /**
     One message from `/events`. Logged by type and terminal only — never `preview`,
     which the decoder already dropped.
     */
    private func handleBus(_ message: SupersetBus.Message) {
        guard superset != nil else { return }
        switch message {
        case let .lifecycle(event):
            Log.write("bus \(event.type.rawValue) \(event.agent) [\(event.terminalID.prefix(8))]")
            if event.type == .detached {
                if let slot = registry.releaseBus(terminalID: event.terminalID) {
                    Log.write("bus: freed slot \(slot) — \(event.agent) detached")
                    publish()
                    requestBusPaint()
                }
                return
            }
            if let change = lifecycle.ingest(event, from: .bus, now: Date()) {
                applyBusChange(change)
            }
            if event.type == .start { scheduleLifecycleFlush() }
        case .bindingsChanged:
            // Says something changed, not what: re-read the list, once per burst.
            bindingsRefreshTask?.cancel()
            bindingsRefreshTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, let client = self.superset?.client else { return }
                await self.syncWithSuperset(client, launch: false)
            }
        case .other:
            break
        }
    }

    private func applyBusChange(_ change: LifecycleMapper.Change) {
        let previous = registry.entry(forTerminal: change.terminalID)
        let outcome = registry.applyBus(
            change, mayClaim: !Self.hookedAgents.contains(change.agent)
        )
        switch outcome {
        case .ignored:
            return
        case .noSlot:
            Log.write("bus: no key for \(change.agent) [\(change.terminalID.prefix(8))] — every key is asking for something")
            return
        case let .claimed(slot):
            Log.write("bus: \(change.agent) [\(change.terminalID.prefix(8))] took slot \(slot) as \(change.state.rawValue)")
            fillBusSessionFolders()
        case .updated:
            break
        }
        guard let sessionID = registry.entry(forTerminal: change.terminalID)?.sessionID else { return }
        publish()
        fireLap(from: previous?.state, sessionID: sessionID)
        interruptTransition(from: previous?.state, sessionID: sessionID)
        requestBusPaint()
    }

    /// Held `Start`s fall due after the debounce; one timer serves them all.
    private func scheduleLifecycleFlush() {
        guard lifecycleFlushTask == nil else { return }
        let wait = Double(model.preferences.superset.startDebounceMs) / 1000 + 0.02
        lifecycleFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            guard let self, !Task.isCancelled else { return }
            self.lifecycleFlushTask = nil
            for change in self.lifecycle.flush(now: Date()) { self.applyBusChange(change) }
        }
    }

    /**
     A repaint asked for by the bus, through `PadWriteCoalescer`: the first goes out at
     once, a burst inside `padWriteCoalesceMs` collapses into one write at the end of
     the window. A change that leaves the keys and ring as they were costs nothing.

     Only the bus goes through here. Hooks, previews and the resident re-assert paint
     directly, as before — the re-assert re-sends the same bytes on purpose.
     */
    private func requestBusPaint() {
        padView = composePadView()
        if keyLooks().mapValues(\.look) == lastPaintedLooks, padView.ringStates == lastPaintedRing { return }
        // A fresh payload per request: the coalescer only paces here; whether the
        // write is redundant was just decided against what the pad last received.
        busPaintSeq += 1
        if padCoalescer.offer(Data("\(busPaintSeq)".utf8), now: Date()) != nil {
            Task { await paint() }
            return
        }
        guard busDrainTask == nil else { return }
        let wait = Double(padCoalesceMs) / 1000 + 0.01
        busDrainTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            guard let self, !Task.isCancelled else { return }
            self.busDrainTask = nil
            if self.padCoalescer.drain(now: Date()) != nil { await self.paint() }
        }
    }

    // MARK: - hooks

    private func startHookServer() {
        Task {
            do {
                try await hooks.start { [weak self] event in
                    await self?.handle(event)
                }
                Log.write("hook socket listening at \(await hooks.socketPath)")
            } catch {
                // The socket failing to bind is worth surfacing: it means no session
                // will ever report, and the board would sit empty looking healthy.
                Log.write("hook socket FAILED: \(error.localizedDescription)")
                await MainActor.run {
                    self.model.apply(device: .permissionDenied(missing: ["a usable hook socket"]))
                }
            }
        }
    }

    private func handle(_ event: HookServer.Event) async {
        /*
         Delegating-state carve-out, ahead of `Eligibility.evaluate`.

         `SubagentStart`/`SubagentStop` payloads carry `agent_id`/`agent_type` even
         though they describe the *parent* session's own bookkeeping, not a subagent
         process reporting in — `Eligibility.evaluate`'s first two checks would refuse
         both unconditionally otherwise (Eligibility.swift:79-86). This branch is keyed
         on the two literal event names only, never on "any event with an agent field",
         so a subagent's own PreToolUse/PostToolUse (which also carries those fields)
         still falls through to `Eligibility.evaluate` below and is refused exactly as
         today. `adjustDelegation` never allocates — an unknown `session_id` is
         ignored rather than given a key, so scarcity is preserved by construction.

         This also bypasses the CLAUDE_AGENT_ID/
         CLAUDE_AGENT_TYPE env checks Eligibility would otherwise apply, so a *nested*
         subagent's own SubagentStart could in principle reach `adjustDelegation` and
         over-count. Bounded by the authoritative reconcile on every `Stop` (below),
         which replaces the incremental count with the true `background_tasks` size
         regardless of how it got there.

         No `publish()`/`paint()` here: `SubagentStart` precedes the turn's own `Stop`
         by construction (spike-observed ordering), so there is no visible state change
         to paint at dispatch time — the effect surfaces the next time `Stop` reconciles
         and (possibly) overrides `.done` to `.working`, which already repaints.

         `agentID` (from the same `agent_id` field Eligibility would have rejected on)
         is what turns `delegatingAgentIDs` into a set rather than a bare counter — see
         `SessionRegistry.Entry.delegatingAgentIDs`'s doc comment for the race this
         closes. A missing/empty `agent_id` degrades to a no-op inside
         `adjustDelegation` itself, not here.
         */
        if event.name == "SubagentStart" || event.name == "SubagentStop",
           let sessionID = event.sessionID {
            registry.adjustDelegation(
                sessionID: sessionID, event: event.name,
                agentID: event.eligibilityPayload.agentID
            )
            return
        }

        // Fail-closed: an unrecognised surface gets no key. Applied here rather than
        // in the helper so the rules live in one place and can be reasoned about.
        let verdict = Eligibility.evaluate(
            env: event.environment,
            payload: event.eligibilityPayload,
            harness: event.harness
        )
        guard verdict.eligible, let sessionID = event.sessionID else {
            Log.write("hook \(event.name): refused (\(verdict.reason.rawValue) \(verdict.detail))")
            return
        }

        guard let state = EventMapper.state(
            for: event.name,
            matcher: event.matcher,
            enabledEvents: model.events,
            notifications: model.notifications
        ) else {
            Log.write("hook \(event.name): no state mapping\(event.matcher.map { " (\($0))" } ?? "")")
            return
        }
        /*
         Remember that this harness has ever worked here.

         Recorded from the first event rather than inferred from the config, because a
         wired hook proves nothing: the file can say all the right things while the
         binary path is stale, which is the exact failure `HookInstall` audits for. An
         event arriving is the only proof that the whole path works end to end.

         Written through `updatePreferences`, which saves — debounced, so a session
         firing a hook every few seconds costs one write rather than one per tool call.
        */
        let sender = event.harness ?? Harness.claudeCode.id
        if !model.preferences.harnessesSeen.contains(sender) {
            model.updatePreferences { $0.harnessesSeen = ($0.harnessesSeen + [sender]).sorted() }
            model.persist()
            Log.write("harness: \(sender) reported for the first time")
        }

        // What the event *maps to*, which is not always what gets applied — the
        // branches below can decline it. A line that reads like a state change while
        // nothing changed is how a stuck key stayed invisible for a whole session, so
        // anything that declines says so on its own line.
        Log.write("hook \(event.name) maps to \(state.rawValue) [\(sessionID.prefix(8))]")

        // A hook from a Superset terminal: the bus reports the same moment, so it goes
        // through the lifecycle mapper too and the bus echo is counted once (F3). And
        // if the bus spoke first and gave the terminal a key, this session takes it.
        if let terminal = event.supersetTerminalID {
            if registry.promoteBusEntry(terminalID: terminal, to: sessionID) {
                Log.write("hook \(event.name): took over the key the bus gave [\(terminal.prefix(8))]")
            }
            if let type = LifecycleType.forHookState(state) {
                _ = lifecycle.ingest(
                    LifecycleEvent(
                        type: type, terminalID: terminal,
                        workspaceID: event.supersetWorkspaceID ?? "",
                        agent: event.harness ?? Harness.claudeCode.id, at: Date()
                    ),
                    from: .hook, now: Date()
                )
            }
        }

        // Dictation ends when what it was dictating is sent.
        if event.name == "UserPromptSubmit", voiceIsActive {
            setVoice(false, why: "prompt submitted")
        }

        /*
         A prompt typed into a Superset session says which workspace you are in.

         Except the one nobody typed: when a background subagent finishes, the CLI
         injects a `UserPromptSubmit` whose prompt begins `<task-notification>`, from
         whatever workspace that session is in — which is not a signal about you.
        */
        if event.name == "UserPromptSubmit",
           !((event.raw["prompt"] as? String)?.hasPrefix("<task-notification>") ?? false),
           let workspace = event.supersetWorkspaceID
               ?? registry.entry(forSession: sessionID)?.supersetWorkspaceID {
            noteSupersetSignal(.init(workspaceID: workspace, at: Date(), source: .prompt))
        }

        /*
         Session ended — drop the entry so the slot becomes reclaimable immediately.

         `.ended` renders as OFF (identical to an unused slot), and leaving the entry
         in place makes `pickSlot` prefer any other unused key over this one. So a
         Terminal tab you closed keeps its slot dark while the next session lights up
         somewhere else — which was the whole "slots crawl right until eviction takes
         over" behaviour that the reclaim path was supposed to prevent, but only
         gets to prevent once *all* slots are occupied.

         Dropping releases the slot at ordering 1 in `pickSlot` (unused wins), so the
         next new session lands here rather than somewhere new. `SessionTitle.forget`
         drops the cached transcript name too, or the reused slot would carry the
         old chat's title until the next enrich.
         */
        if state == .ended {
            if let entry = registry.entry(forSession: sessionID) {
                SessionTitle.forget(transcriptPath: entry.transcriptPath)
                registry.release(sessionID: sessionID)
                Log.write("hook \(event.name): released slot \(entry.slot) (\(sessionID.prefix(8)))")
                publish()
                await paint()
            }
            return
        }

        // Captured before anything mutates the registry: a lap fires on a *transition*,
        // never on a repaint. Reading it afterwards would compare a state to itself and
        // either fire on every hook or never fire at all.
        let previousState = registry.entry(forSession: sessionID)?.state

        /*
         Adopt a session we have never seen start, before anything else looks at it.

         The registry is rebuilt from hooks and `SessionStart` fires once, so a session
         already running when this app starts — after a restart, a rebuild, or the
         cutover from the Node CLI — would otherwise stay invisible forever.

         This runs *first* deliberately. It was originally placed after the
         attention-clear branch, which returns early for PostToolUse — so a session
         quietly working through tool calls, which is most of them, was never adopted
         and the board reported zero sessions while hooks arrived normally.

         Safe here because eligibility has already run: only `cli` and `claude-vscode`
         reach this point, never a subagent or an embedded SDK client.
         */
        // A discovered host holding a placeholder hands its slot over here, rather
        // than the session taking a second key and the board showing it twice.
        //
        // CLAUDE_PID first, because if Claude Code ever exports it that is
        // canonical. Fall back to walking up from the hook helper's parent — its
        // ppid is a shell or claude itself, and the claude ancestor's pid is what
        // Terminal's per-tab tty match needs. Without this fallback, every hook
        // arrives with pid=nil and every "jump to slot N" reports noWindow.
        let hookPID = event.environment["CLAUDE_PID"].flatMap(Int.init)
            ?? event.hookPPID.flatMap(Self.claudePID(fromAncestryOf:))

        /*
         A known session speaking from another process or terminal has moved:
         `claude --resume` in a new tab keeps the session id and changes everything
         else. `enrich` only fills what is missing, so without this the entry kept the
         old pid and terminal and a jump landed in the tab the session had left. An
         entry the liveness check had ended comes back on its own key here.

         The tty is only looked up when something moved: `ps` is not free, and hooks
         arrive several times a minute per session.
         */
        if let known = registry.entry(forSession: sessionID),
           Liveness.hasMoved(known, pid: hookPID, supersetTerminalID: event.supersetTerminalID),
           let move = registry.relocate(
               sessionID: sessionID,
               pid: hookPID,
               tty: hookPID.flatMap(Self.tty(forPID:)),
               supersetTerminalID: event.supersetTerminalID,
               supersetWorkspaceID: event.supersetWorkspaceID
           ) {
            Log.write(Liveness.movedLogLine(move))
            publish()
        }

        /*
         A surface the board is not listening to gets no key.

         Placed here rather than in `Eligibility`, which is pure and answers from the
         payload and the environment: which app *owns* a session is a question only the
         process table can answer, and the hook payload cannot carry it. Placed before
         the adoption and both claims below, so a muted session never takes a key it
         would immediately have to give back.

         Asked only for a session that is not already on the board, and remembered:
         hooks arrive several times a minute per session, and every one of them would
         otherwise pay for the walk up the process tree just to be refused again.
        */
        if registry.entry(forSession: sessionID) == nil, let pid = hookPID {
            let host = mutedPIDs.contains(pid) ? nil : ProcessAncestry.host(ofPID: pid)
            if let host, !model.preferences.listens(to: host) {
                mutedPIDs.insert(pid)
            }
            if mutedPIDs.contains(pid) {
                Log.write("hook \(event.name): refused (not listening to that surface)")
                return
            }
        }

        if registry.adoptRealSessionID(
            sessionID,
            pid: hookPID,
            tty: hookPID.flatMap(Self.tty(forPID:)),
            cwd: event.cwd,
            transcriptPath: event.transcriptPath ?? SessionTranscript.locate(sessionID: sessionID),
            entrypoint: event.entrypoint
        ) {
            Log.write("hook \(event.name): matched a running session already on the board")
            registry.enrich(
                sessionID: sessionID,
                supersetWorkspaceID: event.supersetWorkspaceID,
                supersetTerminalID: event.supersetTerminalID
            )
            registry.setState(sessionID: sessionID, to: state, pendingTool: event.toolName)
            publish()
            fireLap(from: previousState, sessionID: sessionID)
            interruptTransition(from: previousState, sessionID: sessionID)
            await paint()
            return
        }

        if event.name != "SessionStart", registry.entry(forSession: sessionID) == nil {
            Log.write("hook \(event.name): adopting a session already in progress")
            // The tty is what makes a jump exact — Terminal's dictionary exposes it
            // per tab. Omitting it here meant an adopted session could be seen but not
            // raised: "jump to slot 1 -> noWindow".
            let adoptedPID = event.environment["CLAUDE_PID"].flatMap(Int.init)
            _ = registry.claim(
                sessionID: sessionID,
                cwd: event.cwd,
                pid: adoptedPID,
                tty: adoptedPID.flatMap(Self.tty(forPID:)),
                transcriptPath: event.transcriptPath
                    ?? SessionTranscript.locate(sessionID: sessionID),
                entrypoint: event.entrypoint,
                state: state
            )
            // Publish immediately.
            //
            // The branches below can return early — an attention-clear for a session
            // that is not asking for anything does — and a claim that never reaches
            // the model is invisible to everything that reads it. The pad painted
            // correctly from the registry while the menu bar showed nothing and
            // pressing the key reported "slot 1 has no session".
            publish()
        }

        /*
         Learn anything this entry is still missing, before any branch can return.

         A session restored from disk or discovered from the process table arrives with
         no transcript and no cwd, and nothing else revisits those fields. Placed at the
         bottom of this function it was unreachable for exactly the hook that fires most:
         `PostToolUse` returns early unless the session is in an attention state, so the
         board stayed unnamed while hooks arrived normally — the same trap that once made
         session adoption itself unreachable.
         */
        let transcript = event.transcriptPath
            ?? SessionTranscript.locate(sessionID: sessionID)
        if registry.enrich(
            sessionID: sessionID,
            cwd: event.cwd,
            transcriptPath: transcript,
            entrypoint: event.entrypoint,
            tty: hookPID.flatMap(Self.tty(forPID:)),
            pid: hookPID,
            supersetWorkspaceID: event.supersetWorkspaceID,
            supersetTerminalID: event.supersetTerminalID
        ) {
            // Logged once per session, when it happens: an unnamed row is otherwise
            // indistinguishable from a session that genuinely has no transcript.
            Log.write(
                "enriched \(sessionID.prefix(8)): "
                    + "transcript=\(transcript.map { ($0 as NSString).lastPathComponent } ?? "none") "
                    + "cwd=\(event.cwd.map { ($0 as NSString).lastPathComponent } ?? "none")"
            )
        }

        if event.name == "SessionStart" {
            // `hookPID`, not `CLAUDE_PID` alone: Claude Code rarely exports it, and a
            // session claimed without a pid can never be seen to die — its key stayed
            // lit after its process was gone.
            let pid = hookPID
            _ = registry.claim(
                sessionID: sessionID,
                cwd: event.cwd,
                pid: pid,
                tty: pid.flatMap(Self.tty(forPID:)),
                transcriptPath: event.transcriptPath
                    ?? SessionTranscript.locate(sessionID: sessionID),
                entrypoint: event.entrypoint,
                state: state
            )
            // The enrich above ran before this session had an entry, so the Superset
            // workspace is recorded here for a fresh claim.
            registry.enrich(
                sessionID: sessionID,
                supersetWorkspaceID: event.supersetWorkspaceID,
                supersetTerminalID: event.supersetTerminalID
            )
        } else if EventMapper.clearsAttention.contains(event.name) {
            /*
             A tool just ran, so this session is working — whatever it was showing.

             This used to require an attention state and return otherwise, on the
             reasoning that `PostToolUse` is only interesting as an attention-clear and
             repainting on every tool call would write to the device constantly. The
             optimisation was right and the guard implemented it wrongly: it conflated
             *do not repaint* with *do not record*.

             The consequence was a key stuck on the wrong color for a whole turn. Once
             anything moved a working session to `idle` — an `idle_prompt` notification,
             or a relaunch — `PostToolUse` was the only hook firing for the rest of that
             turn, and it did nothing. The board showed idle white through minutes of
             work, and the log said `PostToolUse -> working` the whole time because the
             line is written before this branch.

             Skipping when it is *already* working keeps the write traffic exactly where
             it was: that is the common case by a wide margin.
             */
            guard let existing = registry.entry(forSession: sessionID),
                  existing.state != .working
            else { return }
            registry.setState(sessionID: sessionID, to: .working)
            Log.write("hook \(event.name): \(existing.state.rawValue) -> working")
        } else {
            /*
             `idle_prompt` false-demotion guard, ahead of the delegating override below.

             Claude Code fires a Notification with subtype `idle_prompt` on an idle
             timer (~60s after a turn ends), independent of whether subagents are still
             running. A config that maps `idle_prompt` to any state (commonly `.idle`)
             would otherwise repaint a delegating `.working` key straight to slate —
             `mayReplace` only guards `done -> idle`, not `working -> idle`. Skipped
             entirely (no `setState`, no repaint) rather than re-applying `.working`,
             matching this function's own "a branch that declines says so on its own
             line, without touching the registry" precedent (`clearsAttention` above).
             */
            let delegatedBefore = registry.entry(forSession: sessionID)?.delegatingAgentIDs.count ?? 0
            if EventMapper.suppressesDelegating(
                eventName: event.name,
                matcher: event.matcher,
                delegatedCount: delegatedBefore
            ) {
                Log.write(
                    "hook \(event.name) idle_prompt suppressed (delegating, "
                        + "\(delegatedBefore) in flight) [\(sessionID.prefix(8))]"
                )
                return
            }

            /*
             Delegating-state override: a `Stop` that would paint `.done` paints
             `.working` instead while background subagents are still in flight.

             `background_tasks` (filtered to `type == "subagent"` by
             `backgroundSubagentIDs`) is authoritative and replaces the whole
             `delegatingAgentIDs` set wholesale — never trusted as a running total
             across `Stop`s. This is a no-op for every event that does not map to
             `.done` — Claude Code's `Stop` is the case this override exists for, but
             other harnesses' `.done`-mapped events (Pi's `turn_end`/`agent_settled`,
             `SessionRegistry.swift`) and a `Notification` subtype remapped to `.done`
             (`HarnessPane`'s picker) reach the same override too — so a plain turn with
             no subagents writes exactly the same `.done` it always has.

             No deferred-transition replay needed for the last agent landing: when the
             final background subagent finishes, the CLI has been observed to inject a
             synthetic `UserPromptSubmit` (its prompt begins with `<task-notification>`)
             followed by a real `Stop` — not a documented contract, but consistent
             across hardware validation. That follow-on `Stop` reconciles the count to
             zero and paints `.done` through this exact path — nothing needs to be
             stashed and replayed when the counter drops.
             */
            if state == .done {
                registry.reconcileDelegation(
                    sessionID: sessionID,
                    ids: event.backgroundSubagentIDs
                )
            }
            let delegatedCount = registry.entry(forSession: sessionID)?.delegatingAgentIDs.count ?? 0
            let delegating = delegatedCount > 0
            let applied = (state == .done && delegating) ? SessionState.working : state
            if state == .done, delegating {
                Log.write(
                    "hook \(event.name) deferred to working (delegating, "
                        + "\(delegatedCount) in flight) [\(sessionID.prefix(8))]"
                )
            }
            registry.setState(sessionID: sessionID, to: applied, pendingTool: event.toolName)
        }

        publish()
        fireLap(from: previousState, sessionID: sessionID)
        interruptTransition(from: previousState, sessionID: sessionID)
        await paint()
    }

    /**
     Fire the ring lap a state change earns, if any.

     Separate from `handle` so the rule stays one line: **only a transition**. Firing on
     every paint turns the ring into a strobe and, worse, teaches you that a lap means
     nothing — which costs the one signal that is visible from across the room.
     */
    private func fireLap(from previous: SessionState?, sessionID: String) {
        let current = registry.entry(forSession: sessionID)?.state
        guard let name = Laps.show(
            from: previous, to: current, settings: model.preferences.ambient
        ) else { return }
        guard let show = Shows.show(named: name) else { return }
        Log.write("lap \(name): \(previous?.rawValue ?? "none") -> \(current?.rawValue ?? "none")")
        play(show: show)
    }

    /**
     A session starting to need a human stops a workspace transition mid-count.

     The cascade holds the paint lane, so the hook's own repaint would otherwise wait
     for it to finish. Cutting it short costs the animation; waiting could cost the
     prompt half a second of being dark on a key that has not been counted in yet.
     */
    private func interruptTransition(from previous: SessionState?, sessionID: String) {
        let current = registry.entry(forSession: sessionID)?.state
        guard current != previous, TransitionPlanner.role(of: current) == .attention else { return }
        transitions.interrupt()
    }

    /// The tty of a live process, so a key can raise the right tab later. Captured at
    /// claim time because `ps` cannot resolve one for a dead pid.
    /**
     Walk up from a pid until finding a `claude` process.

     Hooks run as children of the shell or of `claude` itself, so the ppid we get
     from the payload is one or two hops away from the session process. `ps -o
     comm=` on each ancestor tells us where in the chain the real `claude` sits.

     Bounded by depth: cyclic process tables are a `ps` bug, not a real state, but
     an unbounded loop here would freeze the hook path.
     */
    static func claudePID(fromAncestryOf pid: Int) -> Int? {
        var current = pid
        for _ in 0..<8 {
            guard let info = ProcessAncestry.defaultParentOf(current) else { return nil }
            // info.path is *current's* command, per `ps -o ppid=,comm=`.
            let comm = info.path.split(separator: "/").last.map(String.init) ?? info.path
            if comm == "claude" { return current }
            guard info.parent > 1 else { return nil }
            current = info.parent
        }
        return nil
    }

    private static func tty(forPID pid: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let raw = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // "??" means no controlling terminal — normal for an extension-hosted session.
        guard !raw.isEmpty, raw != "??" else { return nil }
        return raw.hasPrefix("/dev/") ? raw : "/dev/\(raw)"
    }

    // MARK: - liveness

    /**
     End every session whose process is gone (`Liveness`), logging each one.

     A process can die without `SessionEnd` — a closed window, a crash, a kill — and
     until this ran every `Liveness.checkInterval` a dead session's key stayed lit
     until its slot was needed or it went stale, and a press raised a tab with no
     session in it. Returns whether anything ended.
     */
    @discardableResult
    private func endGoneSessions() -> Bool {
        let ended = registry.endGoneSessions()
        guard !ended.isEmpty else { return false }
        for entry in ended { Log.write(Liveness.endedLogLine(entry)) }
        publish()
        return true
    }

    /// Its own loop rather than the resident one: that one paints only while the pad
    /// is present, and a dead session should go dark in the menu bar regardless.
    private func startLiveness() {
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Liveness.checkInterval))
                guard let self else { return }
                if self.endGoneSessions() { await self.paint() }
            }
        }
    }

    // MARK: - the resident loop

    private func startResident() {
        startLiveness()
        reassertTask = Task { [weak self] in
            var wasPresent: Bool?
            while !Task.isCancelled {
                guard let self else { return }
                let survey = self.surveyPad()
                let present = survey.found
                self.model.apply(isWired: survey.isWired)
                // Which pad, not just whether one is there: the name in the menu bar is
                // filed under this.
                self.model.apply(deviceSerial: survey.serial)
                self.lastPresenceLog = Log.changed("device present", last: self.lastPresenceLog, to: "\(present) (matched \(survey.matched), vendor \(survey.vendorInterfaces), transport \(survey.transport ?? "none"))"
                )
                let changed = present != wasPresent
                wasPresent = present

                if changed, present {
                    // A reconnect: repaint at once rather than waiting out a tick,
                    // then again shortly after, because Codex takes the LEDs back as
                    // it comes up and the first write can lose that race.
                    await self.reopen()
                    await self.paint()
                    try? await Task.sleep(for: .milliseconds(1500))
                    await self.paint()
                } else if present {
                    await self.paint()
                } else {
                    await self.closeDevice()
                }

                await self.refreshTerminalTitles()
                await self.refreshCmuxSurfaces()
                await self.publishDeviceStatus(present: present)
                try? await Task.sleep(for: present ? self.presentInterval : self.absentInterval)
            }
        }
    }

    private func reopen() async {
        closeDeviceSync()
        do {
            try device.open()
            deviceIsOpen = true
            lastOpenLog = Log.changed("device open", last: lastOpenLog, to: "yes")
        } catch {
            deviceIsOpen = false
            // The distinction that matters: denied is a permission the user can grant,
            // anything else is the pad not being there.
            lastOpenLog = Log.changed("device open", last: lastOpenLog, to: "NO — \(error.localizedDescription)")
        }
    }

    private func closeDevice() async { closeDeviceSync() }

    /// Drop a handle that is no longer working, so the next cycle reopens it.
    ///
    /// Separate from `closeDeviceSync` only to log it: "the pad stopped responding and
    /// the app noticed" and "the pad went away" look identical afterwards, and the
    /// first is the one that used to never happen.
    private func invalidateHandle() {
        guard deviceIsOpen else { return }
        Log.write("device handle dropped after a failed write — will reopen")
        closeDeviceSync()
    }

    private func closeDeviceSync() {
        guard deviceIsOpen else { return }
        device.close()
        deviceIsOpen = false
    }

    private func publishDeviceStatus(present: Bool) async {
        if !present {
            // Ask *why* only when something is already wrong: system_profiler takes
            // about a second, which is far too slow for the 2s presence poll and
            // pointless while the pad is working.
            let presence = DeviceDiagnostics.presence()
            lastPresenceReason = Log.changed("device missing", last: lastPresenceReason, to: String(describing: presence))
            switch presence {
            case .pairedButAsleep: model.apply(device: .bluetoothDisconnected)
            case .bluetoothOff: model.apply(device: .bluetoothOff)
            case .notPaired, .unknown, .connected: model.apply(device: .notFound)
            }
            return
        }
        if !deviceIsOpen {
            await reopen()
        }
        if deviceIsOpen {
            model.apply(device: .ready)
            return
        }
        // Do not guess. The pad being visible but unopenable was reported as
        // "Input Monitoring" regardless of whether that permission was actually the
        // problem, which sends people to a settings pane where the switch is already on.
        // Grant checked first: it is the durable problem, and the one with a settings
        // fix. Secure Keyboard Entry is checked next — it produces the identical
        // kIOReturnNotPermitted, but the remedy is whatever engaged it, not settings.
        let access = PermissionProbe.inputMonitoring()
        if !access.isGranted {
            model.apply(device: .permissionDenied(missing: ["Input Monitoring"]))
            return
        }
        let secure = PermissionProbe.secureInput()
        model.apply(device: secure.active
            ? .secureInputBlocked(holder: secure.holderDescription)
            : .inUseElsewhere)
    }

    // MARK: - painting

    /// Push the whole board to the pad.
    ///
    /// Nothing paints without calibration: slot order is never assumed, and a
    /// confidently wrong light is worse than no light.
    func paint() async {
        var painted = (written: 0, skipped: 0)
        /*
         Never two at once.

         `paint` is async and every caller can trigger it — the resident loop, each
         hook, a settings edit, the battery refresh. `@MainActor` does not prevent
         reentrancy: it only means one runs at a time *between* suspension points, and
         `await device.write` is a suspension point right in the middle. A second paint
         then enters while the first is parked and mutates `registry` through `prune`
         and `decay`, which is overlapping exclusive access to a struct — a hard trap,
         not a race that merely produces a wrong light.

         It crashed the app with `swift_beginAccess` from the resident loop. Coalescing
         is also simply correct: two repaints of the same board are one repaint, and the
         second would only re-send what the first already sent.
         */
        guard !isPainting else {
            repaintWanted = true
            return
        }
        isPainting = true
        defer {
            isPainting = false
            // Anything that asked while this was in flight gets exactly one follow-up,
            // so a burst of hooks collapses into a single extra repaint.
            if repaintWanted {
                repaintWanted = false
                Task { await paint() }
            }
        }

        guard deviceIsOpen else {
            lastPaintLog = Log.changed("paint", last: lastPaintLog, to: "skipped — device not open")
            return
        }
        let calibration = model.calibration
        // A capture owns the keys until it ends. Otherwise the re-assert loop repaints
        // the board over the legend a second after it appears, and the operator is
        // asked to name colors that are no longer there.
        guard calibrationTask == nil else {
            lastPaintLog = Log.changed("paint", last: lastPaintLog, to: "deferred — calibrating")
            return
        }
        // Fun mode owns the whole pad, status included. It was asked for explicitly and
        // it repaints the real board when it ends.
        guard countdown?.isRunning != true else {
            lastPaintLog = Log.changed("paint", last: lastPaintLog, to: "deferred — fun mode")
            return
        }

        /*
         Drop sessions whose process is gone, then age what is left.

         `prune` existed with exactly the right reasoning in its own doc comment — "a
         dead session holding a key makes the board claim activity that does not exist"
         — and was never called from anywhere. So a closed Terminal tab kept its key
         until the 12h stale window, and the header counted it as live.
         */
        // Ended rather than dropped (`prune` used to delete them): an ended entry is
        // reclaimable, so it frees its key exactly as before, and a `--resume` of the
        // same session can still come back on it (`relocate`).
        var boardChanged = endGoneSessions()
        if registry.decay(
            doneAfter: TimeInterval(model.preferences.doneDecaySeconds),
            holdAttention: model.preferences.holdAttention
        ) > 0 {
            boardChanged = true
        }
        if boardChanged { publish() }

        do {
            // Build the whole repaint first, then write it under a single lock. A board
            // update is one logical operation; taking the cross-process lock once per
            // key gave seven chances to collide with another writer.
            var batch: [[Data]] = []
            var written = 0
            var skipped = 0

            // Silence the layer's own backlight, or it floods the pad and buries every
            // per-key color. rgbcfg needs a complete config — both sides, always.
            // Silence the key backlight, or it floods the pad and buries per-key
            // color. Skipped entirely while a show owns the ring: this call carries
            // the ring config too, so sending it mid-show cuts the animation off.
            padView = composePadView()
            if Date() >= ringBusyUntil {
                batch.append(device.prepare(
                    lighting: CodexProtocol.LightingConfig(keys: .off, ambient: ambientSide())
                ))
            }

            // Pad keys, not registry slots: in a workspace context the keys are that
            // workspace's sessions packed from 1 (see `PadView`); in `.all` the two
            // are the same thing. Every key is written — a key with no session is
            // painted dark, or it would keep the previous workspace's light. All six
            // in one call: see `PadPaint`.
            //
            // A slot the calibration does not cover is skipped rather than guessed.
            // Counted, because "every key went dark" and "the app wrote every key and
            // the pad ignored it" look identical from the outside and have completely
            // different causes.
            // A key whose session just changed state flashes its new color, in this same
            // write; the repaint that ends the flash is scheduled once it has landed.
            let own = keyLooks()
            let looks = stateFlash.apply(
                own.mapValues(\.look),
                states: own.mapValues { StateFlash.Key($0.sessionID, $0.state) },
                now: Date()
            )
            let keys = PadPaint.keyBatch(looks, calibration: calibration, transport: device)
            batch += keys.batch
            written = keys.written
            skipped = keys.skipped

            try await device.write(batch: batch)
            painted = (written, skipped)
            lastPaintedLooks = looks
            lastPaintedRing = padView.ringStates
            scheduleFlashEnd()
        } catch {
            // Never throw out of the loop: a failed repaint is a missed light, but a
            // dead loop is a board that stays wrong until someone restarts the app.
            // Logged, though — a silent swallow here is what made this undiagnosable.
            //
            // kIOReturnNotPermitted on an already-open handle is the Secure Keyboard
            // Entry signature — the periodic poll's disambiguation only covers the
            // *open* path, so a mid-session engage surfaces here first and used to be
            // logged as an Input Monitoring denial the settings pane would contradict.
            var failure = error.localizedDescription
            if case CodexError.accessDenied = error {
                let secure = PermissionProbe.secureInput()
                if secure.active {
                    failure += " — Secure Keyboard Entry is active (\(secure.holderDescription)), not an Input Monitoring problem"
                }
            }
            lastPaintLog = Log.changed("paint", last: lastPaintLog, to: "FAILED — \(failure)")
            /*
             A failed write means this handle is dead, whatever the survey says.

             Plugging the pad into USB while it is on Bluetooth removes one HID device
             and adds another. The survey counts the *new* one, so `present` stays true
             and never *changes* — which is the only thing that triggered a reopen. The
             app went on writing to the old handle indefinitely: every report refused,
             the pad dark and unresponsive, and the header still saying "connected"
             because `deviceIsOpen` was never falsified.

             So the write is the authority on whether the handle works, not the count of
             devices that look like a pad. Dropping it here also corrects the header,
             which reads `deviceIsOpen` — one flag, so the status cannot claim a
             connection the writes are not getting.
             */
            invalidateHandle()
            return
        }
        // The key count, not just the session count: a board that goes dark while this
        // says "6 keys" is the device dropping them, and one that says "0 keys" is us.
        lastPaintLog = Log.changed(
            "paint",
            last: lastPaintLog,
            to: "ok — \(painted.written) keys written"
                + (painted.skipped > 0 ? ", \(painted.skipped) uncalibrated" : "")
                + " (\(registry.entries.count) sessions)"
        )
    }

    /**
     Repaint when the flash in progress ends, so the keys go back to their own looks on
     the next step. One task per deadline: keys that joined the flash moved it, and the
     old task is dropped rather than left to repaint early.
     */
    private func scheduleFlashEnd() {
        guard let until = stateFlash.until, until != flashEndsAt else { return }
        flashEndsAt = until
        flashEndTask?.cancel()
        flashEndTask = Task { [weak self] in
            let wait = max(until.timeIntervalSinceNow, 0)
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 10))
            guard let self, !Task.isCancelled else { return }
            self.flashEndsAt = nil
            await self.paint()
        }
    }

    // MARK: - commands

    func sync() { Task { await paint() } }

    /**
     Play a ring animation.

     One at a time — overlapping shows fight over a single light — and by rank: a
     higher one cuts a lower one off (`ShowArbiter`). The board keeps
     painting underneath: the ring and the six keys are separate RPCs, so status is
     never suspended for a show, only the ring is borrowed.
     */
    /**
     Fun mode.

     Owns the whole pad for the length of the song, status included. `paint()` stands
     down while it runs — the same rule the calibration capture uses, for the same
     reason: two writers produce a fight nobody can read.
     */
    func playCountdown() {
        guard deviceIsOpen else { return }
        if countdown?.isRunning == true {
            countdown?.cancel()
            return
        }
        let player = CountdownPlayer(
            device: device,
            log: { Log.write($0) },
            finished: { [weak self] in
                guard let self else { return }
                self.countdown = nil
                self.model.funModeRunning = false
                self.ringBusyUntil = .distantPast
                Task { await self.paint() }
            }
        )
        countdown = player
        model.funModeRunning = true
        // The ring belongs to the show for the duration; a status repaint mid-song
        // restarts the firmware's animation and reads as flicker.
        ringBusyUntil = Date().addingTimeInterval(400)
        player.start(preferences: model.preferences)
    }

    /**
     - Parameter priority: defaults to the show's own rank (`ShowPriority.of`).
     - Returns: whether it started. A lower-ranked show than the one playing — or any
       show while dictation owns the ring — does not.
     */
    @discardableResult
    func play(show: Show, priority: ShowPriority? = nil) -> Bool {
        // The event laps and the workspace sweep run at the configured speed.
        let show = Shows.paced(show, speed: model.preferences.animationSpeed)
        let rank = priority ?? ShowPriority.of(showNamed: show.name)
        let decision = ShowArbiter.decide(
            incoming: rank,
            running: runningShow == nil ? nil : runningShowPriority,
            voiceActive: voiceOwnsRing
        )
        guard decision != .ignore else {
            Log.write("show \(show.name): ignored, \(runningShow ?? "dictation") owns the ring")
            return false
        }
        guard deviceIsOpen else { return false }
        if decision == .preempt {
            Log.write("show \(show.name): cuts off \(runningShow ?? "another")")
        }

        showToken += 1
        let token = showToken
        runningShow = show.name
        runningShowPriority = rank
        model.runningShow = show.name
        ringBusyUntil = Date().addingTimeInterval(show.duration.seconds + 0.8)
        Log.write("show \(show.name): starting (\(Int(show.duration.seconds * 1000))ms)")

        Task { [weak self] in
            guard let self else { return }
            for step in show.steps {
                guard self.showToken == token, self.runningShow == show.name else { break }
                // Asserted once, then left alone for the step's duration.
                try? await self.device.send(
                    lighting: CodexProtocol.LightingConfig(keys: .off, ambient: step.side)
                )
                try? await Task.sleep(for: .milliseconds(step.milliseconds))
            }
            // Cut off: the show that replaced it owns the ring, and its hand-back.
            guard self.showToken == token else { return }
            // Hand the ring back rather than leaving whatever the last step wrote.
            try? await self.device.send(
                lighting: CodexProtocol.LightingConfig(keys: .off, ambient: .off)
            )
            self.runningShow = nil
            self.runningShowPriority = nil
            self.model.runningShow = nil
            self.ringBusyUntil = .distantPast
            Log.write("show \(show.name): done")
            await self.paint()
        }
        return true
    }

    /// Jump from a click in the popover, as opposed to a key press.
    func jumpFromUI(_ slot: Int) { jump(to: slot) }

    func stopShow() {
        runningShow = nil
        runningShowPriority = nil
        ringBusyUntil = .distantPast
    }

    /**
     Free one key.

     The session keeps running — this forgets the *binding*, it does not stop anything.
     Needed because a session whose process died without emitting `SessionEnd` holds its
     slot until the stale window expires, and "forget all" is a poor answer to one row
     being wrong.
     */
    func release(slot: Int) {
        guard let entry = registry.occupancy().first(where: { $0.slot == slot })?.entry else {
            return
        }
        // Drop the cached name too, or a key reused by a different chat keeps the old one.
        SessionTitle.forget(transcriptPath: entry.transcriptPath)
        registry.release(sessionID: entry.sessionID)
        Log.write("released slot \(slot) (\(entry.sessionID.prefix(8)))")
        publish()
        Task { await paint() }
    }

    func forgetAllSessions() {
        registry.reset()
        publish()
        Task { await paint() }
    }

    // MARK: - publishing

    private func publish() {
        // First: each row names the pad key its session is on.
        padView = composePadView()
        let slots = registry.occupancy().map { slot, entry -> SlotView in
            guard let entry else { return SlotView(slot: slot) }
            // What you asked for, falling back to the folder. Two sessions in one repo
            // are otherwise identical rows.
            // The tab title first: Claude Code keeps it describing what the session
            // is *now*, where the first message describes what it was when it started.
            let name = self.name(of: entry)
            // Not `focused`: that is the property holding what is in front of you, and
            // shadowing it here reads as though the two are the same thing.
            let viewing = isFocused(entry, name: name)
            let shown = Viewing.display(entry.state, isFocused: viewing)
            return SlotView(
                slot: slot,
                state: shown,
                // What you asked for, falling back to the folder. Two sessions in one
                // repo are otherwise identical rows.
                title: name ?? entry.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                project: entry.cwd.map(Self.shorten),
                surface: entry.tty.map { $0.replacingOccurrences(of: "/dev/", with: "") }
                    ?? entry.entrypoint,
                age: Self.age(of: entry.updatedAt),
                sessionID: entry.sessionID,
                pendingTool: entry.pendingTool,
                origin: SessionOrigin.from(
                    entrypoint: entry.entrypoint, tty: entry.tty, host: entry.host
                ),
                pid: entry.pid,
                cmuxSurface: entry.pid.flatMap { cmuxSurfaces[$0] },
                entrypoint: entry.entrypoint,
                isNamed: name != nil,
                cwd: entry.cwd,
                supersetWorkspaceID: entry.supersetWorkspaceID,
                supersetTerminalID: entry.supersetTerminalID,
                // The same resolution the pad gets, from the same configured colors, so
                // the dot and the swatch cannot drift from the key.
                emitting: entry.isUnconfirmed && !viewing
                    ? model.preferences.unconfirmedAppearance
                    : Viewing.appearance(shown, isFocused: viewing, from: model.appearances),
                isFocused: viewing,
                padKey: padView.keys.first { $0.value == entry.sessionID }?.key,
                place: place(of: entry),
                isUnconfirmed: entry.isUnconfirmed
            )
        }
        // The popover lists every session; only the pad is filtered.
        model.apply(slots: slots)
        RegistryStore.save(registry)
    }

    private static func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func age(of date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

/// Runs a callback at most once, however many exits reach it.
@MainActor
private final class CallOnce {
    private var body: (@MainActor () -> Void)?
    init(_ body: (@MainActor () -> Void)?) { self.body = body }
    func run() {
        let once = body
        body = nil
        once?()
    }
}
