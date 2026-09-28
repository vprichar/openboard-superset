import Combine
import Foundation
import OpenBoardKit
import SwiftUI

/**
 What the UI reads.

 One observable object shared by the status item, the popover and the settings
 window, so the three can never disagree about the state of the board. Everything
 here is display state derived from the registry — the registry itself is owned by
 the session store and rebuilt from hooks.

 Deliberately holds no device handle: the UI must keep rendering, and keep saying
 *why*, when the pad is unreachable.
 */
@MainActor
final class BoardModel: ObservableObject {
    @Published private(set) var slots: [SlotView] = SlotView.emptyBoard
    @Published private(set) var device: DeviceStatus = .unknown
    /// Attached by cable. Charging, and off Bluetooth for as long as it is — which is
    /// why the battery percentage stops updating and must not be shown as if it had.
    @Published private(set) var isWired = false
    /// The attached pad's hardware serial, or nil when nothing is attached. The key a
    /// custom name is filed under — see `Preferences.deviceNames`.
    @Published private(set) var deviceSerial: String?

    /**
     What to call the pad on screen.

     The name you gave this one, or the plain product name. Never the pairing suffix
     macOS appends — "Codex Micro #3" describes this Mac's pairing history, not the
     object, and reads as a version number.
     */
    var deviceName: String {
        if let deviceSerial, let named = preferences.deviceNames[deviceSerial],
           !named.trimmingCharacters(in: .whitespaces).isEmpty {
            return named
        }
        return "Codex Micro"
    }
    @Published var appearances: [SessionState: Appearance] = [:]
    @Published var actions: [String: KeyAction] = [:]
    @Published var caps: [String: String] = [:]
    /// Per-key snippet text. `snippet` is the fallback for a key with none set.
    @Published var snippets: [String: String] = [:]
    @Published var snippet: String = "/start-ticket"
    /// Never nil: an un-recorded pad runs on the assumed layout rather than staying
    /// dark. See `Calibration` for the evidence behind that default.
    @Published var calibration: Calibration = Calibration.loadDefault()

    /// Which hooks may repaint. Absent means enabled — muting is opt-in.
    @Published var events: [String: Bool] = [:]
    /// Which surfaces the board listens to, by host raw value. Absent means listening,
    /// the same rule as `events` — see `Preferences.surfaces`.
    @Published var surfaces: [String: Bool] = [:]
    /// Notification subtype → state. `idle_prompt` is deliberately absent.
    @Published var notifications: [String: SessionState] = [:]
    /// The show currently owning the ring, if any.
    @Published var runningShow: String?
    /// Fun mode, which owns the whole pad rather than just the ring.
    @Published var funModeRunning = false

    /// Sessions blocked on a human, in slot order. Drives the popover's orange row
    /// and the status item's color — one source, so they cannot drift apart.
    /// A restored session not yet confirmed is not counted: see `Actions.respond`.
    var blocked: [SlotView] { slots.filter { $0.state?.isAttention == true && !$0.isUnconfirmed } }

    /// Whether a person has actually confirmed the key order, as opposed to the board
    /// running on the layout every pad so far has reported.
    var isCalibrationConfirmed: Bool { !calibration.isAssumed }

    /// The whole configuration, so callers that need a value the model does not
    /// surface (decay timings, ambient mode, countdown) can reach it in one place.
    @Published private(set) var preferences: Preferences = .default

    /// The host-service connection, as the Superset pane shows it. `.off` until the
    /// client exists.
    @Published var supersetLink: SupersetLinkState = .off

    init() {
        apply(PreferencesStore.shared.load())
    }

    /// Adopt a settings document. The single path by which stored preferences reach
    /// the UI, so there is one place to look when a setting does not take effect.
    func apply(_ settings: Preferences) {
        preferences = settings
        appearances = Dictionary(
            uniqueKeysWithValues: SessionState.allCases.map { ($0, settings.appearance(for: $0)) }
        )
        actions = settings.keyActions
        caps = settings.caps
        snippets = settings.snippets
        events = settings.events
        surfaces = settings.surfaces
        notifications = settings.notificationStates
    }

    /// Fold the current UI state back into a settings document.
    var settings: Preferences {
        var next = preferences
        for (state, appearance) in appearances { next.setAppearance(appearance, for: state) }
        // Every action key, including ones explicitly cleared — an unassigned key has
        // to persist as unassigned rather than falling back to its default.
        // Every action key, including ones explicitly cleared — an unassigned key must
        // persist *as* unassigned or it reverts to its default on the next launch.
        var keys: [String: KeyAction?] = [:]
        for cell in BoardLayout.cells where cell.isAction { keys[cell.id] = actions[cell.id] }
        keys["ENC"] = actions["ENC"]
        next.actionKeys = keys
        next.caps = caps
        next.snippets = snippets
        next.events = events
        next.surfaces = surfaces
        var mapped: [String: SessionState?] = [:]
        for kind in ["permission_prompt", "agent_needs_input", "elicitation_dialog", "idle_prompt"] {
            mapped[kind] = notifications[kind]
        }
        next.notifications = mapped
        return next
    }

    func persist() { PreferencesStore.shared.save(settings) }

    /// Edit a field the UI does not mirror into its own `@Published` state.
    ///
    /// `settings` rebuilds the document from the mirrored properties, so a direct write
    /// to `preferences` would be overwritten by the next fold-back. Everything not
    /// mirrored — encoder, ambient, countdown, timings — goes through here.
    func updatePreferences(_ change: (inout Preferences) -> Void) {
        var next = settings
        change(&next)
        apply(next)
    }

    func resetToDefaults() {
        apply(PreferencesStore.shared.reset())
    }

    /// Replace the visible board. Called from the session store as hooks arrive.
    func apply(slots: [SlotView]) { self.slots = slots }

    func apply(device: DeviceStatus) { self.device = device }

    func apply(isWired: Bool) { self.isWired = isWired }

    func apply(deviceSerial: String?) { self.deviceSerial = deviceSerial }
}

/// One of the six keys, as the UI needs it.
struct SlotView: Identifiable, Equatable {
    let slot: Int
    var state: SessionState?
    var title: String?
    var project: String?
    var surface: String?
    var age: String?
    var sessionID: String?
    var pendingTool: String?
    /// Terminal, cmux, VS Code, or a CLI with no tty.
    var origin: SessionOrigin?
    /// The session's process, for the one host that is addressed by pid: cmux knows
    /// which surface a pid is running in, so this is what resolves a jump when the
    /// cached `cmuxSurface` is not there yet.
    var pid: Int?
    /// The cmux surface holding this session, with the workspace and window a focus
    /// request has to name. Nil for every other host, and for a cmux session claimed
    /// since the last read.
    var cmuxSurface: Cmux.Surface?
    /// The raw entry point, kept alongside `origin` because the two answer different
    /// questions. `origin` is `.vscode` for both an extension-hosted chat and a session
    /// in VS Code's integrated terminal; only the first has a panel that can be revealed
    /// by session id, and asking for one that does not exist *creates* it.
    var entrypoint: String?
    /// Whether `title` is the session's own name or a fallback to its folder.
    var isNamed: Bool = false
    /// The real working directory. `project` is its *display* form with the home
    /// directory shortened to `~`, which is not a path anything can open.
    var cwd: String?
    /// The Superset workspace hosting this session. Set means the jump deep-links into
    /// Superset rather than walking terminal ttys.
    var supersetWorkspaceID: String?
    /// The Superset terminal inside that workspace, so the jump lands on the right tab.
    var supersetTerminalID: String?

    var id: Int { slot }

    var key: String { BoardLayout.key(forSlot: slot) ?? "AG\(slot - 1)" }
    /// Holds a session record — including one that has ended and not yet been pruned.
    var isOccupied: Bool { sessionID != nil }

    /// Actually running. What "N live" in the header means, and not the same thing:
    /// an ended session still holds its record until its process is reaped.
    var isLive: Bool { isOccupied && state != .ended }

    /// The color this key is emitting. An empty slot is not a color — it is the
    /// absence of one, and must look different from a slot deliberately turned off.
    /// What this key is emitting, including the focus pulse — so the dot in the menu
    /// bar and the swatch in the popover agree with the pad rather than describing a
    /// state the hardware is not showing.
    var appearance: Appearance? {
        // Resolved by the controller from the *configured* colors. Computing it here
        // from the shipped defaults was its own quiet lie: a customised idle showed the
        // user's white on the pad and the stock blue in the popover.
        if let emitting { return emitting }
        guard let state else { return nil }
        return Viewing.appearance(state, isFocused: isFocused)
    }

    /// What the pad was told to emit for this slot, colors and all.
    var emitting: Appearance?

    /// Whether this is the session in front of you. Set by the controller, which is the
    /// only thing that knows what the focus watcher last reported.
    var isFocused: Bool = false

    /// The pad key showing this session, or nil when the pad is showing another
    /// workspace. Not `slot`: in a workspace context key 2 can be slot 5.
    var padKey: Int?
    /// The workspace's folder for a Superset session, else the session's own folder.
    var place: String?
    /// Restored from disk and not yet confirmed by a live event (F1).
    var isUnconfirmed: Bool = false

    /// "key 2 · my-app" — what the popover and the log call this session.
    var keyLabel: String { Self.keyLabel(padKey: padKey, place: place) }

    static func keyLabel(padKey: Int?, place: String?) -> String {
        let key = padKey.map { "key \($0)" } ?? "off the pad"
        return place.map { "\(key) · \($0)" } ?? key
    }

    /// `keyLabel` in Spanish, for the popover. `keyLabel` stays English: the log reads it.
    var displayKeyLabel: String {
        let key = padKey.map { tr("tecla %ld", $0) } ?? tr("fuera del pad")
        return place.map { "\(key) · \($0)" } ?? key
    }

    var swatch: Color {
        guard let appearance, appearance.effect != .off else { return Color.secondary.opacity(0.28) }
        return Color(appearance.color)
    }

    /// Brightness reads as opacity in the menu bar: the dot is small enough that a
    /// dim color and a bright one are otherwise indistinguishable.
    var menuBarOpacity: Double {
        guard let appearance, appearance.effect != .off else { return 0.30 }
        return 0.45 + 0.55 * appearance.brightness
    }

    /// The second line, beside the origin badge. See `SessionDetail`.
    var detail: String {
        SessionDetail.line(
            terminal: surface, project: project, age: age, isNamed: isNamed
        )
    }

    /// Kept for the settings window, which shows one line rather than two.
    var meta: String {
        [origin?.rawValue, project, age].compactMap { $0 }.joined(separator: " · ")
    }

    static let emptyBoard: [SlotView] = (1...BoardLayout.slotCount).map { SlotView(slot: $0) }
}

/**
 Why the pad is or is not usable.

 Modelled as a closed set rather than a boolean because the remedies differ
 completely, and the popover's job when things are broken is to say which one applies.
 */
enum DeviceStatus: Equatable {
    case unknown
    case ready
    /// Paired but not connected — press a key to wake it.
    case bluetoothDisconnected
    /// Bluetooth itself is off, so nothing can connect.
    case bluetoothOff
    /// Visible and permitted, but another process holds it.
    case inUseElsewhere
    /// Secure Keyboard Entry is engaged, blocking keyboard-class HID system-wide.
    /// Transient and not this app's grant — the remedy is whatever engaged it, not
    /// System Settings, which is why it is not folded into `permissionDenied`.
    case secureInputBlocked(holder: String)
    /// Found, but macOS refused access. Per-app, and needs a restart after granting.
    case permissionDenied(missing: [String])
    /// No vendor interface at all.
    case notFound

    var isUsable: Bool { self == .ready }

    /// Whether this is something guided setup can fix, rather than something about the
    /// hardware. "Try again" is the wrong offer for a missing permission — retrying
    /// asks macOS the same question and gets the same answer, so the button has to send
    /// people somewhere that changes it.
    var needsSetup: Bool {
        if case .permissionDenied = self { return true }
        return false
    }

    /// - Parameter name: what the user calls this pad. Threaded in rather than read
    ///   here, because a status enum has no business knowing about preferences.
    func headline(_ name: String = "Codex Micro") -> String {
        switch self {
        case .unknown: tr("Buscando el pad")
        case .ready: tr("Conectado a %@", name)
        case .bluetoothDisconnected: tr("Sin conexión por Bluetooth")
        case .bluetoothOff: tr("El Bluetooth está desactivado")
        case .inUseElsewhere: tr("Otra app está usando el pad")
        case .secureInputBlocked: tr("La entrada segura de teclado bloquea el pad")
        case .permissionDenied: tr("macOS denegó el acceso")
        case .notFound: tr("No se encontró ningún %@", name)
        }
    }

    var message: String {
        switch self {
        case .unknown:
            tr("Comprobando la interfaz HID.")
        case .ready:
            tr("Seis teclas, en vivo.")
        case .bluetoothDisconnected:
            tr("El Codex Micro está enlazado pero no conectado. Pulsa cualquier tecla del pad para despertarlo; hasta entonces, cada color que ves aquí es lo último que pidió OpenBoard, no lo que muestra el pad.")
        case let .permissionDenied(missing):
            tr("OpenBoard necesita %@. Se conceden por app y solo surten efecto después de reiniciarla.",
                missing.map(permissionName).joined(separator: tr(" y ")))
        case .notFound:
            tr("Conecta el pad por USB o Bluetooth. Si ya está conectado, comprueba que esté en la capa 1.")
        case .bluetoothOff:
            tr("El Bluetooth está desactivado, así que el pad no puede conectarse.")
        case .inUseElsewhere:
            tr("El pad está aquí y OpenBoard tiene permiso para leerlo, pero otra app lo tiene abierto. Lo habitual es que siga abierta una copia antigua de OpenBoard.")
        case let .secureInputBlocked(holder):
            tr("%@ activó la entrada segura de teclado, que bloquea el HID de teclado para todas las apps. Tu permiso de Monitorización de entrada está bien: termina o cierra lo que la activó y el pad volverá.", holder)
        }
    }
}
