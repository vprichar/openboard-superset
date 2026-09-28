import Foundation

/**
 The Codex Micro as it physically sits under your hand.

 A 4×4 grid of positions, but only 13 are keys. The other three are a rotary encoder
 (top-left), a planar joystick (top-right) and a touch sensor (bottom-left). The
 settings window draws this grid directly, so the window matches the hardware rather
 than an idealised version of it.

 Two details that look like mistakes and are not:

 - **`ACT10` and `ACT11` are separate keys on this build.** The genuine pad puts both
   switches under one wide MIC cap and collapses them; the clone this fork targets has
   three separate 1U keys on the bottom row (mic, pencil, terminal), so `ACT11` is its
   own cell and independently bindable. `span`/`members` stay so a wide cap can be
   described again.
 - **The joystick and touch sensor emit nothing.** They are drawn because the pad has
   them, not because they can be bound. A 25s capture with the joystick in constant
   use produced 113 encoder events and zero joystick events.

 Only the six Agent keys are RGB-addressable. The action keys are not individually lit.
 */
public enum BoardElement: String, Sendable, Codable {
    case encoder
    case joystick
    case touch
}

public struct BoardCell: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// One of the six status keys. Always jumps to its session; not rebindable.
        case agent(slot: Int)
        /// Freely assignable.
        case action
        /// A physical control that is not a key.
        case element(BoardElement)
    }

    /// Vendor keycode name with the `KV_OAI_` prefix stripped: AG00…AG05,
    /// ACT06…ACT12. Elements use ENC / JOY / TOUCH, matching the design's cap ids.
    public let id: String
    public let kind: Kind
    /// The wide cap spans two grid columns.
    public let span: Int
    /// Switches collapsed into this cell. `[ACT10, ACT11]` for the wide cap.
    public let members: [String]

    public init(id: String, kind: Kind, span: Int = 1, members: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.span = span
        self.members = members ?? [id]
    }

    public var isAgent: Bool { if case .agent = kind { return true }; return false }
    public var isAction: Bool { if case .action = kind { return true }; return false }

    public var slot: Int? {
        if case let .agent(slot) = kind { return slot }
        return nil
    }

    /// Elements carry no icon — a dial, a stick and a touch pad are not keycaps.
    public var acceptsKeycap: Bool {
        if case .element = kind { return false }
        return true
    }
}

public enum BoardLayout {
    public static let slotCount = 6

    /// Reading order, row by row, exactly as the design's `BOARD` array.
    ///
    /// Row 1: dial, two session keys, stick
    /// Row 2: four session keys
    /// Row 3: four action keys
    /// Row 4: touch, then three single action keys (the clone's layout)
    public static let cells: [BoardCell] = [
        BoardCell(id: "ENC", kind: .element(.encoder)),
        BoardCell(id: "AG00", kind: .agent(slot: 1)),
        BoardCell(id: "AG01", kind: .agent(slot: 2)),
        BoardCell(id: "JOY", kind: .element(.joystick)),

        BoardCell(id: "AG02", kind: .agent(slot: 3)),
        BoardCell(id: "AG03", kind: .agent(slot: 4)),
        BoardCell(id: "AG04", kind: .agent(slot: 5)),
        BoardCell(id: "AG05", kind: .agent(slot: 6)),

        BoardCell(id: "ACT06", kind: .action),
        BoardCell(id: "ACT07", kind: .action),
        BoardCell(id: "ACT08", kind: .action),
        BoardCell(id: "ACT09", kind: .action),

        BoardCell(id: "TOUCH", kind: .element(.touch)),
        // Clone layout: ACT10 and ACT11 are separate caps, not one wide MIC cap.
        BoardCell(id: "ACT10", kind: .action),
        BoardCell(id: "ACT11", kind: .action),
        BoardCell(id: "ACT12", kind: .action),
    ]

    public static let agentKeys: [String] = ["AG00", "AG01", "AG02", "AG03", "AG04", "AG05"]

    /// Slot for an Agent key name, 1-based. Mirrors calibration's reading order.
    public static func slot(forKey key: String) -> Int? {
        guard let index = agentKeys.firstIndex(of: key) else { return nil }
        return index + 1
    }

    public static func key(forSlot slot: Int) -> String? {
        guard slot >= 1, slot <= agentKeys.count else { return nil }
        return agentKeys[slot - 1]
    }

    /// Map a reported switch to the cell that owns its binding.
    ///
    /// This is what collapses the wide cap's two switches into one press. Anything
    /// reading key events must go through it, or the double-fire returns.
    public static func canonical(_ reported: String) -> String {
        for cell in cells where cell.members.contains(reported) {
            return cell.id
        }
        return reported
    }

    /**
     The same cells, grouped into the four physical rows.

     `Grid` needs rows explicitly, and it is the only layout that honours
     `gridCellColumns` — which the wide MIC cap depends on. A flat list rendered in a
     `LazyVGrid` drops the span silently and the bottom row comes out a column short.

     Derived from `cells` rather than written out again, so there is one definition of
     what is on the pad.
     */
    public static var rows: [[BoardCell]] {
        var result: [[BoardCell]] = []
        var current: [BoardCell] = []
        var width = 0
        for cell in cells {
            current.append(cell)
            width += cell.span
            if width >= 4 {
                result.append(current)
                current = []
                width = 0
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func cell(id: String) -> BoardCell? {
        cells.first { $0.id == id }
    }
}

/// What pressing an action key does. Ported from `lib/layout.cjs` ACTION_CHOICES.
public enum KeyAction: String, CaseIterable, Sendable, Codable {
    case sync
    case settings = "ui"
    case reset
    case off
    case approve
    case reject
    case snippet
    case newtab
    /**
     A new tab, and a new workspace, in cmux.

     Two actions rather than one because cmux has two things a "new tab" key could
     reasonably mean, and it names them itself: ⌘T is a new **surface** — a tab inside
     the pane you are in — and ⌘N is a new **workspace**, which is what cmux's own
     shortcut list calls `newTab`. Guessing between them would be guessing at someone's
     habit; both are one call, so both are offered.

     Neither is a variant of `newtab`, which sends ⌘T to Terminal.app. A key bound to
     that in a cmux session opens a Terminal window behind cmux — the wrong app, doing
     the right thing.
     */
    case newtabCmux = "newtab-cmux"
    case newWorkspaceCmux = "newworkspace-cmux"
    case voiceTap = "voice-tap"
    case voiceTalk = "voice-talk"
    case voiceToggle = "voice-toggle"
    case countdown
    /// Open the menu bar dropdown — the same panel a click on the status item gives.
    case popover = "menu"
    /// Next / previous tab, and the arrow keys — what the joystick is for.
    case tabForward = "tab-forward"
    case tabBack = "tab-back"
    case arrowUp = "arrow-up"
    case arrowDown = "arrow-down"
    case arrowLeft = "arrow-left"
    case arrowRight = "arrow-right"
    /// Move along the board itself rather than the screen — jump to the session on the
    /// next or previous occupied key. The one navigation that is about *this* app.
    case prevSession = "prev-session"
    case nextSession = "next-session"
    /// Submit whatever is being typed. Unconditional, unlike `approve`, which answers
    /// the one waiting session and refuses otherwise.
    case enter
    /// Replay a chord recorded in Settings — the payload is a `Shortcut`.
    case shortcut
    /*
     The Superset actions (Plan §2.5 + D10). Declared here so the picker, the config
     reader and the tests agree on their names; each is wired into `BoardController`
     by its own phase, and until then a key bound to one only logs that it is not.
    */
    /// A fresh agent in the focused workspace (`agents.run`, empty prompt).
    case supersetNewAgent = "superset-new-agent"
    /// Hand the focused terminal's context to another agent, after confirmation.
    case supersetHandoff = "superset-handoff"
    /// Jump to whichever session has been waiting on you the longest.
    case jumpOldestWaiting = "jump-oldest-waiting"
    /// ⎋ to the focused agent, through the host-service, after reading its screen.
    case interruptFocused = "interrupt-focused"
    /// Arm a remote send: the next agent key receives it, without jumping there.
    case targetedArm = "targeted-arm"

    /// Short label, as the popover's keycap grid shows it.
    public var short: String {
        switch self {
        case .sync: tr("repintar el tablero")
        case .settings: tr("abrir Ajustes")
        case .reset: tr("olvidar sesiones")
        case .off: tr("apagar todas las teclas")
        case .approve: tr("aprobar")
        case .reject: tr("rechazar")
        case .snippet: tr("escribir texto")
        case .newtab: tr("nueva pestaña de Terminal")
        case .newtabCmux: tr("nueva pestaña de cmux")
        case .newWorkspaceCmux: tr("nuevo espacio de trabajo de cmux")
        case .voiceTap: tr("tocar para dictar")
        case .voiceTalk: tr("mantener para dictar")
        case .voiceToggle: tr("activar o desactivar la voz")
        case .countdown: tr("modo diversión")
        case .popover: tr("abrir el menú")
        case .tabForward: tr("pestaña siguiente")
        case .tabBack: tr("pestaña anterior")
        case .arrowUp: tr("flecha arriba")
        case .arrowDown: tr("flecha abajo")
        case .arrowLeft: tr("flecha izquierda")
        case .arrowRight: tr("flecha derecha")
        case .prevSession: tr("sesión anterior")
        case .nextSession: tr("sesión siguiente")
        case .enter: tr("enviar ⏎")
        case .shortcut: tr("atajo personalizado")
        case .supersetNewAgent: tr("agente nuevo")
        case .supersetHandoff: tr("traspasar")
        case .jumpOldestWaiting: tr("el que más espera")
        case .interruptFocused: tr("interrumpir agente")
        case .targetedArm: tr("envío remoto")
        }
    }

    /// Full label for the settings window's picker, where the ambiguity in `reject`
    /// has room to be spelled out.
    public var long: String {
        switch self {
        case .approve: tr("aprobar la solicitud pendiente (⏎)")
        case .reject: tr("rechazar la solicitud pendiente (⎋) / cancelar el modo diversión")
        case .snippet: tr("escribir texto en el cursor")
        case .newtabCmux: tr("nueva pestaña de cmux (en el espacio de trabajo actual)")
        case .newWorkspaceCmux: tr("nuevo espacio de trabajo de cmux (el ⌘N de cmux)")
        case .voiceTalk: tr("mantener para dictar (requiere voice.mode=hold)")
        case .countdown: tr("MODO DIVERSIÓN: reproduce el video y las luces lo siguen")
        case .popover: tr("abrir el menú de la barra de menús")
        case .tabForward: tr("pestaña siguiente (⌘⇧])")
        case .tabBack: tr("pestaña anterior (⌘⇧[)")
        case .arrowUp: tr("flecha arriba")
        case .arrowDown: tr("flecha abajo")
        case .arrowLeft: tr("flecha izquierda")
        case .arrowRight: tr("flecha derecha")
        case .prevSession: tr("sesión anterior")
        case .nextSession: tr("sesión siguiente")
        case .enter: tr("enviar ⏎ a la ventana activa")
        case .shortcut: tr("atajo de teclado personalizado (se graba abajo)")
        case .supersetNewAgent: tr("agente nuevo en el espacio de trabajo activo de Superset")
        case .supersetHandoff: tr("traspasar la terminal activa a otro agente (confirmar con APPR)")
        case .jumpOldestWaiting: tr("ir a la sesión que más lleva esperando")
        case .interruptFocused: tr("interrumpir el agente activo (⎋ vía Superset)")
        case .targetedArm: tr("preparar un envío remoto y luego pulsar una tecla de agente")
        default: short
        }
    }

    /// Glyph overlaid on the keycap for the two that send a literal keystroke.
    public var hint: String? {
        switch self {
        case .approve, .enter: "⏎"
        case .reject: "⎋"
        default: nil
        }
    }

    public var needsSnippetText: Bool { self == .snippet }
    public var needsShortcut: Bool { self == .shortcut }

    /**
     What the joystick can usefully be bound to.

     Curated rather than `allCases`. A direction on a stick is a *navigation* gesture,
     and offering it "fun mode" or "forget all sessions" is offering a way to make a
     mistake with your thumb — the whole list has to be things it makes sense to do
     four of, one per direction.
     */
    public static var forJoystick: [KeyAction] {
        [.arrowUp, .arrowDown, .arrowLeft, .arrowRight,
         .tabBack, .tabForward, .prevSession, .nextSession,
         .approve, .reject, .snippet, .enter, .shortcut]
    }

    /// How the picker groups the actions under headers.
    public enum Category: String, CaseIterable, Sendable {
        case board, navigation, superset, typing, voice, cmux, fun
    }

    /// What stands between a press and its effect. Shown as a badge in the picker; the
    /// behaviour itself belongs to each action's phase.
    public enum Safeguard: Sendable {
        case none
        /// A second press inside the cooldown is dropped.
        case debounce
        /// Armed first, then confirmed with APPR or cancelled by any other key.
        case twoStep
        /// Reads the terminal before writing into it.
        case snapshotFirst
    }

    public var category: Category {
        switch self {
        case .sync, .settings, .reset, .off, .popover: .board
        case .tabForward, .tabBack, .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
             .prevSession, .nextSession, .jumpOldestWaiting: .navigation
        case .supersetNewAgent, .supersetHandoff, .interruptFocused, .targetedArm: .superset
        case .approve, .reject, .snippet, .enter, .shortcut, .newtab: .typing
        case .voiceTap, .voiceTalk, .voiceToggle: .voice
        case .newtabCmux, .newWorkspaceCmux: .cmux
        case .countdown: .fun
        }
    }

    /// Whether it does anything without the host-service. `jumpOldestWaiting` reads the
    /// board's own registry, so it works with the client off.
    public var requiresSuperset: Bool { category == .superset }

    public var safeguard: Safeguard {
        switch self {
        // D2: debounce only — a new agent is cheap to close and slow to confirm.
        case .supersetNewAgent: .debounce
        case .supersetHandoff: .twoStep
        case .interruptFocused, .targetedArm: .snapshotFirst
        default: .none
        }
    }

    /// Shipped bindings, from `lib/config.cjs`.
    public static let defaults: [String: KeyAction] = [
        "ACT06": .approve,
        "ACT07": .reject,
        "ACT08": .snippet,
        "ACT09": .newtab,
        "ACT10": .voiceTap,
        "ACT12": .countdown,
        "ENC": .settings,
    ]
}
