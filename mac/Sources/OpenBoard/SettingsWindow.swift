import OpenBoardKit
import SwiftUI

/**
 The settings window: a sidebar and five panes, all real. Hosted in a window the app owns rather than a SwiftUI `Settings`
 scene — see `MainWindowController` for why that distinction turned out to matter.

 The sidebar is color-chipped icons and a status group that answers "is this working"
 without navigating anywhere.

 It had a search field, copied from CodexBar, which has a long provider list to filter.
 This window has four panes, all visible at once — searching a list you can already see
 is a control that can only ever narrow it to something you were looking at.
 */
struct SettingsWindow: View {
    @EnvironmentObject private var board: BoardModel
    /**
     What the detail side is showing.

     A pane or a harness, because the sidebar now lists both and they are not the same
     kind of thing: a pane is a subject, a harness is one of several instances of one.
     Modelling it as a single enum keeps `List` selection working — two selection
     states in one list means clicking either leaves the other highlighted.
     */
    enum Selection: Hashable {
        case pane(Pane)
        case harness(String)
    }

    @State private var selection: Selection = .pane(.board)
    /// Read only to rebuild the window when the interface language changes.
    @AppStorage(UIStrings.defaultsKey) private var uiLanguage = UIStrings.defaultLanguage.rawValue
    @State private var installed: Set<String> = []

    enum Pane: String, CaseIterable, Identifiable {
        case board = "Board"
        case colors = "Colors"
        case device = "Device"
        case superset = "Superset"
        case workspaces = "Workspaces"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .board: "square.grid.3x2"
            case .colors: "paintpalette"
            case .device: "cable.connector"
            case .superset: "terminal"
            case .workspaces: "rectangle.stack"
            }
        }

        /// What the sidebar calls it. The raw value stays English as an identifier.
        var title: String {
            switch self {
            case .board: tr("Tablero")
            case .colors: tr("Colores")
            case .device: tr("Dispositivo")
            case .superset: "Superset"
            case .workspaces: tr("Espacios de trabajo")
            }
        }

        /// One color per pane, as System Settings and CodexBar both do it.
        ///
        /// The color is the thing you actually navigate by once you know the window —
        /// it is recognisable in peripheral vision in a way a monochrome glyph is not.
        var tint: Color {
            switch self {
            case .board: Color(RGB(0x0C47E9))
            case .colors: Color(RGB(0xD41145))
            case .device: Color(RGB(0x09B821))
            case .superset: Color(RGB(0xFF6A00))
            case .workspaces: Color(RGB(0x9B30FF))
            }
        }

    }


    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section {
                        ForEach(Pane.allCases) { item in
                            SidebarRow(pane: item).tag(Selection.pane(item))
                        }
                    }

                    /*
                     The three harnesses, where CodexBar puts its providers.

                     Only the three OpenBoard can actually drive. The harness pane knows
                     about thirteen and can say which are on the machine, but a sidebar
                     is navigation: every row here has to go somewhere, and ten rows
                     that only report a fact would be a list you cannot click.

                     A row is lit when its agent is installed *and* reporting. Grey is
                     "not connected", which covers both "not here" and "here but not
                     wired" — the pane says which.
                    */
                    Section {
                        ForEach(Harness.all) { item in
                            HarnessRow(
                                harness: item,
                                connected: installed.contains(item.id),
                                everSeen: board.preferences.harnessesSeen.contains(item.id)
                            )
                            .tag(Selection.harness(item.id))
                        }
                    } header: {
                        Text("HARNESS")
                            .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                            .foregroundStyle(.tertiary)
                    }

                    // Live state, not navigation — the board's own status. It answers
                    // "is this thing working" without changing pane.
                    Section {
                        StatusRow(
                            // Just "Connected" here. The pad's name is worth carrying
                            // in the menu bar, where it is the only thing identifying
                            // which board you are looking at; in a window whose title
                            // is already the app, it was a long line saying little.
                            title: board.device.isUsable ? tr("Conectado") : tr("Pad no disponible"),
                            detail: board.device.isUsable
                                ? (liveCount == 1 ? tr("%ld sesión", liveCount) : tr("%ld sesiones", liveCount))
                                : board.device.headline(board.deviceName),
                            ok: board.device.isUsable
                        )
                    } header: {
                        Text(tr("ESTADO"))
                            .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                            .foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.sidebar)
                // The list draws its own backdrop, which over the window's material is
                // a second pane of frosted glass on top of the first — the seam down
                // the middle of the window. Cleared, so the one behind shows through.
                .scrollContentBackground(.hidden)
            }
            .onAppear(perform: refreshHarnesses)
            /*
             Fixed, and wide enough for the longest thing in it.

             `min == ideal == max` is what makes it fixed: with a range, the divider is
             draggable and the column takes whatever width the window was last left at,
             which is how "Claude Code" became "Clau…" in a 268pt sidebar. A settings
             window has four panes and nothing to gain from a resizable sidebar.

             250 is the longest row — "Connected to <pad name>" — plus its dot and
             insets, measured rather than guessed.
            */
            .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 250)
            // Belt and braces. `navigationSplitViewColumnWidth` states the column's
            // width; it does not stop the split view proposing less to the content
            // inside it, which is how "Claude Code" came back as "Claude…" in a column
            // that was supposed to be fixed at 250.
            .frame(minWidth: 250)
            // The floating glyph above the list was NavigationSplitView's own collapse
            // toggle. A settings window has exactly two panes and nothing to gain from
            // hiding one of them, so it was a control that could only make the window
            // worse — and it read as a broken icon rather than as a button.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                // Device is deliberately ungated. It is the pane that says which
                // permission is missing, so blocking it because a permission is missing
                // would be a locked door with the key behind it.
                switch selection {
                case .pane(.board):
                    BoardPane().requiresSetup(tr("Lo que hace cada tecla"))
                case .pane(.colors):
                    ColorsPane().requiresSetup(tr("El aspecto de las teclas"))
                case .pane(.device):
                    DevicePane()
                case .pane(.superset):
                    SupersetPane()
                case .pane(.workspaces):
                    WorkspacePane()
                case let .harness(id):
                    HarnessPane(harnessID: id).requiresSetup(tr("Cómo se muestra este harness"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Same reason as the sidebar: every pane is a ScrollView, and a ScrollView
            // paints an opaque background over the window's material by default.
            .scrollContentBackground(.hidden)
        }
        // Nothing to collapse and nothing to drag, so the divider is decoration
        // separating two halves of one surface.
        .navigationSplitViewStyle(.balanced)
        // Without this the sidebar selection is a fixed blue whatever the user chose:
        // SwiftUI resolves the accent from an asset catalog, and a SwiftPM build has
        // none. See SystemColors.
        .tint(SystemColors.selectedRow)
        // A new language rebuilds the panes so every string is looked up again; the
        // selected pane is this view's own state and survives.
        .id(uiLanguage)
    }

    private var liveCount: Int { board.slots.filter(\.isLive).count }

    /// Installed *and* wired. The dot is the same claim the harness pane's card makes,
    /// computed once here so the two cannot disagree.
    private func refreshHarnesses() {
        let found = Set(
            HarnessDetector.survey().filter(\.installed).compactMap { $0.agent.harnessID }
        )
        let audit = HookInstall.audit(
            settings: HookInstall.loadSettings(),
            expectedCommand: HookInstall.hookCommandPath()
        )
        installed = Set(
            Harness.all
                .filter { found.contains($0.id) && ($0.setup == .automatic ? audit.isHealthy : true) }
                .map(\.id)
        )
    }
}

/// A sidebar row: color-chipped icon, then the name.
struct SidebarRow: View {
    let pane: SettingsWindow.Pane

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(pane.tint)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
            Text(pane.title).font(.system(size: 13))
        }
        .padding(.vertical, 1)
    }
}

/// Live state in the sidebar, with a dot rather than a chip — it is not somewhere you
/// can navigate to, and a chip would say otherwise.
struct StatusRow: View {
    let title: String
    let detail: String
    let ok: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(ok ? Color(RGB(0x09B821)) : Color(RGB(0xFF6A00)))
                .frame(width: 7, height: 7)
                .padding(.leading, 7)
                // Aligned to the first line rather than centred on a block whose height
                // now changes with the name.
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 0) {
                /*
                 Wraps, rather than truncating.

                 A pad can be called anything, and this is the one line in the window
                 that names it — "Connected to…" is the least useful half of the
                 sentence to keep. `fixedSize` vertically is what actually does it: a
                 sidebar row proposes a height for one line, and without it the text
                 takes that proposal and truncates instead of growing.
                */
                Text(title)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        // Not selectable: it is a readout, and letting it take selection would leave
        // the detail pane showing a pane that is no longer highlighted.
        .allowsHitTesting(false)
    }
}

/**
 The pad, drawn as the object on your desk.

 A case, a plate with screws, and keys that catch light — because the window's job is
 to let you point at a key here and know which one your hand will find. A flat grid of
 squares needs translating; this does not.

 ## Selection

 Nothing is selected until you click. The inspector then opens *beside* the pad rather
 than under it, so the key you are editing stays visible and in the same place while
 you change it — a panel below pushes the board around as it grows and shrinks, and
 you lose track of which cap you picked.

 It closes, too. An inspector that cannot be dismissed is a permanent column of
 controls for a decision you already made.
 */
struct BoardPane: View {
    @EnvironmentObject private var board: BoardModel
    @Environment(\.boardCommands) private var commands
    /// Deliberately nil at first. Opening on a preselected key implies you asked about
    /// it, and hides the fact that the board is the thing to click.
    @State private var selected: String?
    /// Which app's profile the inspector edits; nil is the base bindings ("All apps").
    @State private var context: String?
    /// Tap or Hold, for the action caps.
    @State private var gesture: OpenBoardKit.Gesture

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 4)

    /// The defaults are what the window opens with; the snapshot harness passes a key,
    /// a context and a gesture to picture a particular state.
    init(selected: String? = nil, context: String? = nil, gesture: OpenBoardKit.Gesture = .tap) {
        _selected = State(initialValue: selected)
        _context = State(initialValue: context)
        _gesture = State(initialValue: gesture)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // No page title: the sidebar already says which pane this is, and a
                // heading that repeats the selected row is a line of chrome between you
                // and the first setting.
                PaneHeader(tr("Nombre"), tr("Cómo se llama este pad en todo OpenBoard."))
                nameRow

                PaneHeader(tr("Asignar teclas"), tr("Haz clic en una tecla para ver qué hace y cambiar su tapa."))
                ProfileContextBar(context: $context)
                // Side by side when both fit, the inspector under the pad when not. Both
                // are fixed-width, so an HStack that does not fit overlaps them instead
                // of shrinking — the pad drew over the inspector's first letters.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        padCase
                        inspector
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        padCase
                        inspector
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(22)
        }
        // A new key opens on what it does when tapped, whatever the last one showed.
        .onChange(of: selected) { gesture = .tap }
    }

    @ViewBuilder
    private var inspector: some View {
        if let selected, let cell = BoardLayout.cell(id: selected) {
            CapInspector(cell: cell, context: context, gesture: $gesture) { self.selected = nil }
                .frame(width: 300)
                .transition(.opacity)
        }
    }

    /**
     What the ring's LED bar beside the touch hole shows: the "One color" setting when
     that is the mode. The live ring (laps, pulses) is the controller's and is not
     published to the model, so every other mode is drawn unlit rather than guessed.
     */
    private var ringLight: Appearance? {
        let ambient = board.preferences.ambient
        guard ambient.mode == "fixed", ambient.fixed.effect != .off else { return nil }
        return ambient.fixed
    }

    /// The caps the chosen context overrides, for the profile badge.
    private var overridden: Set<String> {
        guard let context else { return [] }
        return SettingsEditing.overriddenCells(profile: context, in: board.preferences)
    }

    /// Whether holding this action cap does something in the chosen context.
    private func hasHold(_ cell: BoardCell) -> Bool {
        guard cell.isAction else { return false }
        return ProfileResolver.resolve(
            .action(cell.id), .hold, frontBundleID: context, prefs: board.preferences
        ).action != nil
    }

    /**
     Name this pad.

     Every Codex Micro reports the same product name, so "Connected to Codex Micro"
     tells someone with two of them nothing — and macOS's own answer is a pairing
     counter, "#1" and "#3", which describes this Mac's history rather than the object
     on the desk.

     Filed under the hardware serial, so the name follows the pad rather than the port
     it is plugged into, and survives re-pairing.

     Disabled with no pad attached: there is nothing to name, and a field that accepts
     a name and files it under nothing is worse than one that will not take it.
     */
    private var nameRow: some View {
        HStack(spacing: 10) {
            TextField("Codex Micro", text: nameBinding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .disabled(board.deviceSerial == nil)
            // The serial is still what the name is filed under; it is just not
            // something anyone needs to read. Kept only for the case the field cannot
            // be used at all, where the reason matters.
            if board.deviceSerial == nil {
                Text(tr("No hay ningún pad conectado"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { board.deviceSerial.flatMap { board.preferences.deviceNames[$0] } ?? "" },
            set: { name in
                guard let serial = board.deviceSerial else { return }
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                board.updatePreferences {
                    // Cleared rather than stored empty, so the placeholder comes back
                    // and the file does not accumulate blank entries.
                    if trimmed.isEmpty {
                        $0.deviceNames.removeValue(forKey: serial)
                    } else {
                        $0.deviceNames[serial] = trimmed
                    }
                }
                commands.bindingsChanged()
            }
        )
    }

    /**
     The pad itself.

     Built outward from the grid — `padding` then `background` then `padding` then
     `background` — so each layer is exactly the size of what it wraps. The previous
     version used a `ZStack` whose screws were positioned with
     `frame(maxHeight: .infinity)`, which made the whole stack greedy: the pad stretched
     to whatever height the inspector beside it happened to be, and grew as you
     selected keys. Screws are `overlay` now, which does not participate in layout.

     Shadows are deliberately sparse. Three of them stacked — plate, case, and one per
     key — plus a `plusLighter` rim turned a flat object into a cloud. The plate carries
     none at all: on the real pad it is a recess, and a recess does not cast.
     */
    private var padCase: some View {
        Grid(horizontalSpacing: 7, verticalSpacing: 7) {
            ForEach(Array(BoardLayout.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row, id: \.id) { cell in
                        BoardCapView(
                            cell: cell,
                            slot: cell.slot.flatMap { slot in
                                board.slots.first { $0.slot == slot }
                            },
                            capID: board.caps[cell.id],
                            action: board.actions[cell.id],
                            isSelected: selected == cell.id,
                            hasHold: hasHold(cell),
                            isOverridden: overridden.contains(cell.id),
                            ring: ringLight
                        )
                        .gridCellColumns(cell.span)
                        .onTapGesture { selected = cell.id }
                    }
                }
            }
        }
        // No width here. The caps are explicitly sized, so the grid is exactly
        // 4 x 51 + 3 x 7 = 225 and the plate wraps whatever that comes to.
        .padding(22)
        .background(plate)
        .overlay(alignment: .topLeading) { screw }
        .overlay(alignment: .topTrailing) { screw }
        .overlay(alignment: .bottomLeading) { screw }
        .overlay(alignment: .bottomTrailing) { screw }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(
                    stops: [
                        // Frosted grey acrylic, as on the clone: a translucent case
                        // around a white plate.
                        .init(color: Color(RGB(0xDCDCDA)), location: 0),
                        .init(color: Color(RGB(0xC4C4C1)), location: 0.52),
                        .init(color: Color(RGB(0xAEAEAB)), location: 1),
                    ],
                    startPoint: UnitPoint(x: 0.09, y: 0), endPoint: UnitPoint(x: -0.09, y: 1)
                ))
                // Inside the background, on the shape.
                //
                // `.shadow()` applied to the *container* shadows the whole composited
                // subtree — so every key cast this 22pt blur as well, and it pooled
                // between the case edge and the plate as a dark halo. Attached to the
                // shape, only the outer silhouette casts, which is what an object
                // sitting on a desk actually does.
                .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
        )
    }

    /// The recessed plate. Inset shading only — a recess does not cast a shadow.
    private var plate: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(RGB(0xFBFBF9)), Color(RGB(0xF2F2EF))],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay {
                // A hairline, not an outline. The plate is a recess in the case, so
                // the only thing marking its edge is where the light stops.
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.black.opacity(0.05), lineWidth: 0.5)
            }
    }

    private var screw: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color(RGB(0x4A4A4E)), Color(RGB(0x141416))],
                center: UnitPoint(x: 0.38, y: 0.32), startRadius: 0, endRadius: 7
            ))
            .frame(width: 11, height: 11)
            .padding(11)
    }
}

/// Which corner a case screw sits in.
enum Screw: CaseIterable, Hashable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    static var corners: [Screw] { allCases }

    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}

/**
 What the selected cap is and what it does.

 Agent keys are not rebindable — they always jump to their slot — so they get an icon
 picker only. Action keys and the encoder click get both. The dial, stick and touch
 sensor get neither: they are drawn because the pad has them, not because they can be
 bound.
 */
struct CapInspector: View {
    @EnvironmentObject private var board: BoardModel
    /**
     Every edit here has to be announced.

     `BoardModel` is the *display* copy. Writing to it repaints the window and nothing
     else: it does not save, and it does not push the change into the dispatcher that
     actually reads a binding when a key is pressed. `bindingsChanged` is what does
     both — which is why the whole pane silently forgot every keycap, binding, snippet
     and joystick direction the moment the app restarted, and why a rebound key kept
     doing its old job until it did.

     There is no save button by design, so a setter that does not call this is not a
     missing confirmation step — it is a control that does nothing.
     */
    @Environment(\.boardCommands) private var commands
    let cell: BoardCell
    /// The app profile being edited, or nil for the base bindings.
    var context: String? = nil
    /// Tap or Hold, for the action caps. Owned by the pane so it survives a redraw.
    var gesture: Binding<OpenBoardKit.Gesture> = .constant(.tap)
    /// Dismiss. An inspector that cannot be closed is a permanent column of controls
    /// for a decision already made.
    var close: () -> Void = {}

    init(
        cell: BoardCell,
        context: String? = nil,
        gesture: Binding<OpenBoardKit.Gesture> = .constant(.tap),
        close: @escaping () -> Void = {}
    ) {
        self.cell = cell
        self.context = context
        self.gesture = gesture
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(kind)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.5), in: .capsule)
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(tr("Cerrar"))
            }

            switch cell.kind {
            case .element(.encoder):
                // Kept: it scrolls whatever is under the pointer, not the focused
                // window, which is not what a dial on a keyboard implies.
                Text(tr("Desplaza la ventana que está bajo el puntero."))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("AL GIRAR A LA DERECHA"))
                        .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                        .foregroundStyle(.tertiary)
                    Picker("", selection: encoderDirectionBinding) {
                        Text(tr("Sube")).tag(true)
                        Text(tr("Baja")).tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    // There is no correct default: macOS ships "natural" scrolling on
                    // and plenty of people turn it off, so the direction a dial should
                    // feel like depends on a setting this app cannot read.
                    // Kept: otherwise the missing second direction reads as an
                    // omission, and someone goes looking for it.
                    Text(tr("Al girar a la izquierda hace siempre lo contrario."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(tr("LÍNEAS POR CLIC"))
                            .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("\(board.preferences.scrollLines)")
                            .font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                    }
                    Slider(
                        value: scrollLinesBinding, in: 1...10, step: 1
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("AL PULSAR"))
                        .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                        .foregroundStyle(.tertiary)
                    GroupedActionPicker(selection: encoderActionBinding(\.click), noneLabel: tr("nada"))
                        .disabled(context != nil)
                    if context != nil { SameEverywhereNote() }
                }
                if board.preferences.encoder.click?.needsShortcut == true {
                    shortcutSection(key: "ENC", allowHold: false)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(tr("AL MANTENER"))
                            .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(tr("tras %ld ms", board.preferences.encoder.longPressMs))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if let context {
                        ProfileOverrideRow(control: .encoderLong, gesture: .hold, profile: context, noneLabel: tr("nada"))
                    } else {
                        GroupedActionPicker(selection: encoderActionBinding(\.longPress), noneLabel: tr("nada"))
                    }
                    Slider(value: holdMsBinding, in: 150...1200, step: 50)
                    // The hold fires while the dial is still down, not on release:
                    // classifying on release gives no feedback that you have held it
                    // long enough, so people let go early and get the wrong action.
                }
                if resolved(.encoderLong, .hold).action?.needsShortcut == true {
                    shortcutSection(key: resolved(.encoderLong, .hold).payloadKey, allowHold: false)
                }

            case .element(.joystick):
                ForEach(Joystick.Direction.allCases, id: \.self) { direction in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(direction.rawValue.uppercased())
                            .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                            .foregroundStyle(.tertiary)
                        if let context {
                            ProfileOverrideRow(
                                control: .joystick(direction), gesture: .tap, profile: context,
                                noneLabel: tr("sin asignar"), actions: KeyAction.forJoystick
                            )
                        } else {
                            GroupedActionPicker(
                                selection: stickBinding(direction), noneLabel: tr("sin asignar"),
                                actions: KeyAction.forJoystick
                            )
                        }
                    }
                    if resolved(.joystick(direction), .tap).action?.needsShortcut == true {
                        shortcutSection(key: resolved(.joystick(direction), .tap).payloadKey, allowHold: false)
                    }
                }

                // Kept: a stick you can hold looks like it should repeat.
                Text(tr("Un empuje es una acción, por mucho que lo mantengas."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)

            case .element(.touch):
                inert(tr("Este sensor no ha enviado nunca ningún evento."))

            case .agent:
                // Kept: this pane is where every other key is rebound.
                Text(tr("Las teclas de agente siempre saltan a su posición y no se pueden reasignar."))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                RemoteBlock()
                capPicker(allowNone: true)

            case .action:
                if SettingsEditing.offersHold(cell) {
                    GesturePicker(gesture: gesture)
                }
                if gesture.wrappedValue == .hold {
                    HoldSection(cell: cell, context: context)
                    if resolved(.action(cell.id), .hold).action?.needsShortcut == true {
                        shortcutSection(key: resolved(.action(cell.id), .hold).payloadKey, allowHold: false)
                    }
                } else {
                    actionPicker(title: tr("AL PULSAR ESTA TECLA"), key: cell.id)
                    if context != nil { SameEverywhereNote() }
                    if board.actions[cell.id]?.needsSnippetText == true {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tr("TEXTO QUE ESCRIBE"))
                                .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                                .foregroundStyle(.tertiary)
                            TextField("", text: snippetBinding)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5).monospaced())
                            Text(tr("Se escribe en el cursor. No se envía."))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            DangerousSnippetWarning(text: board.snippets[cell.id] ?? "")
                        }
                    }
                    if board.actions[cell.id]?.needsShortcut == true {
                        shortcutSection(key: cell.id, allowHold: true)
                    }
                }
                capPicker(allowNone: false)
                if cell.span > 1 {
                    // Kept: the title reads "ACT10 + ACT11", which looks like two keys
                    // to bind separately.
                    Text(tr("Una tapa, dos interruptores: se asigna como %@.", cell.members[0]))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
    }

    private func inert(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The chord a `.shortcut` binding sends and, on the action caps only, whether the
    /// pad key taps or holds it. Shaped like the snippet block. The dial's hold and the
    /// stick have no release edge, so they are never offered hold.
    @ViewBuilder
    private func shortcutSection(key: String, allowHold: Bool) -> some View {
        // `JOY.up@bundle` falls back to `JOY.up`, as the dispatcher does, so an
        // inherited chord shows; recording one writes the profile's own.
        let recorded = ProfileResolver.shortcut(forPayloadKey: key, prefs: board.preferences)
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("ATAJO QUE ENVÍA"))
                .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                .foregroundStyle(.tertiary)
            ShortcutRecorder(shortcut: recorded) { chord in
                var next = chord
                next.mode = recorded?.mode ?? .tap
                // Re-recording the keys keeps the count.
                next.repeats = recorded?.repeats ?? 1
                board.updatePreferences { SettingsEditing.setShortcut(next, payloadKey: key, in: &$0) }
                commands.bindingsChanged()
            }
            Text(tr("Pulsa las teclas en tu teclado. Esc cancela."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            // Sends the chord N times per press, a moment apart — ⎋ ×2 is Claude Code's
            // double Esc. Only for a tapped chord; a held one is held, not repeated.
            if let recorded, recorded.mode == .tap {
                Stepper(value: shortcutRepeatBinding(key, current: recorded.repeats), in: Shortcut.repeatRange) {
                    Text(tr("Repetir ×%ld", recorded.repeats))
                        .font(.system(size: 12.5).monospacedDigit())
                }
            }
        }
        if allowHold, recorded != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("AL PULSARLA"))
                    .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                    .foregroundStyle(.tertiary)
                Picker("", selection: shortcutModeBinding(key)) {
                    Text(tr("Lo toca")).tag(Shortcut.Mode.tap)
                    Text(tr("Lo mantiene mientras pulsas")).tag(Shortcut.Mode.hold)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(tr("Mantener deja el atajo pulsado hasta que sueltas, como mantener para dictar."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func shortcutRepeatBinding(_ key: String, current: Int) -> Binding<Int> {
        Binding(
            get: { current },
            set: { count in
                board.updatePreferences { SettingsEditing.setShortcutRepeat(count, payloadKey: key, in: &$0) }
                commands.bindingsChanged()
            }
        )
    }

    private func shortcutModeBinding(_ key: String) -> Binding<Shortcut.Mode> {
        Binding(
            get: { board.preferences.shortcuts[key]?.mode ?? .tap },
            set: { mode in
                board.updatePreferences { $0.shortcuts[key]?.mode = mode }
                commands.bindingsChanged()
            }
        )
    }

    private func actionPicker(title: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                .foregroundStyle(.tertiary)
            GroupedActionPicker(selection: actionBinding(key), noneLabel: tr("sin asignar"))
                .disabled(context != nil)
        }
    }

    /// What this control does in the chosen context, and the key its chord is under.
    private func resolved(_ control: PadControl, _ gesture: OpenBoardKit.Gesture) -> Resolved {
        ProfileResolver.resolve(control, gesture, frontBundleID: context, prefs: board.preferences)
    }

    /// The real Codex Micro caps, so the window matches the hardware.
    private func capPicker(allowNone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("TAPA"))
                .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                .foregroundStyle(.tertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: 6)], spacing: 6) {
                if allowNone {
                    // Session keys default to none: the LED is the signal there, and a
                    // glyph competes with it.
                    capButton(id: nil)
                }
                // Blank moulds are left out; one already on this key still shows, so
                // the current choice is never invisible.
                ForEach(KeycapCatalog.selectable, id: \.id) { cap in
                    capButton(id: cap.id)
                }
                if let current = board.caps[cell.id],
                   !KeycapCatalog.selectable.contains(where: { $0.id == current }) {
                    capButton(id: current)
                }
            }
        }
    }

    private func capButton(id: String?) -> some View {
        let chosen = board.caps[cell.id] == id
        return Button {
            if let id { board.caps[cell.id] = id } else { board.caps.removeValue(forKey: cell.id) }
            commands.bindingsChanged()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(chosen
                        ? AnyShapeStyle(SystemColors.selectedRow.opacity(0.28))
                        : AnyShapeStyle(.quaternary.opacity(0.4)))
                if let id, let icon = KeycapCatalog.icon(forCap: id) {
                    KeycapIconView(icon: icon).frame(width: 18, height: 18)
                } else if id == nil {
                    Image(systemName: "nosign").font(.system(size: 12)).foregroundStyle(.tertiary)
                } else if let id {
                    Text(id).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 34)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(SystemColors.selectedRow, lineWidth: chosen ? 1.5 : 0)
            )
        }
        .buttonStyle(.plain)
        .help(id ?? tr("sin icono"))
    }

    private var title: String {
        switch cell.kind {
        case let .agent(slot): tr("%@ · posición %ld", cell.id, slot)
        case .element(.encoder): "ENCODER"
        case .element(.joystick): "JOYSTICK"
        case .element(.touch): tr("SENSOR TÁCTIL")
        case .action: cell.span > 1 ? cell.members.joined(separator: " + ") : cell.id
        }
    }

    private var kind: String {
        switch cell.kind {
        case .agent: tr("tecla de agente · salta a su posición")
        case .element(.encoder): tr("dial · girar y pulsar")
        case .element(.joystick): tr("joystick · un empuje, una acción")
        case .element: tr("sin función")
        case .action: cell.span > 1 ? tr("tecla de acción · una tapa ancha") : tr("tecla de acción · configurable")
        }
    }

    private func actionBinding(_ key: String) -> Binding<KeyAction?> {
        Binding(
            get: { board.actions[key] },
            set: {
                board.actions[key] = $0
                commands.bindingsChanged()
            }
        )
    }

    private var snippetBinding: Binding<String> {
        Binding(
            get: { board.snippets[cell.id] ?? "" },
            set: {
                board.snippets[cell.id] = $0
                commands.bindingsChanged()
            }
        )
    }

    private var encoderDirectionBinding: Binding<Bool> {
        Binding(
            get: { board.preferences.encoder.clockwiseScrollsUp },
            set: { up in
                board.updatePreferences { $0.encoder.clockwiseScrollsUp = up }
                commands.bindingsChanged()
            }
        )
    }

    private func stickBinding(_ direction: Joystick.Direction) -> Binding<KeyAction?> {
        Binding(
            get: { board.preferences.joystick.action(for: direction) },
            set: { action in
                board.updatePreferences { prefs in
                    switch direction {
                    case .up: prefs.joystick.up = action
                    case .down: prefs.joystick.down = action
                    case .left: prefs.joystick.left = action
                    case .right: prefs.joystick.right = action
                    }
                }
                commands.bindingsChanged()
            }
        )
    }

    private func encoderActionBinding(
        _ path: WritableKeyPath<Preferences.Encoder, KeyAction?>
    ) -> Binding<KeyAction?> {
        Binding(
            get: { board.preferences.encoder[keyPath: path] },
            set: { action in
                board.updatePreferences { $0.encoder[keyPath: path] = action }
                commands.bindingsChanged()
            }
        )
    }

    private var holdMsBinding: Binding<Double> {
        Binding(
            get: { Double(board.preferences.encoder.longPressMs) },
            set: { ms in
                board.updatePreferences { $0.encoder.longPressMs = Int(ms.rounded()) }
                commands.bindingsChanged()
            }
        )
    }

    private var scrollLinesBinding: Binding<Double> {
        Binding(
            get: { Double(board.preferences.scrollLines) },
            set: { lines in
                board.updatePreferences { $0.scrollLines = Int(lines.rounded()) }
                commands.bindingsChanged()
            }
        )
    }
}

/**
 One key, drawn to the design's measurements.

 Every number here comes from `OpenBoard-Board-New.html` rather than being judged by
 eye: 51pt keys, 11pt corners, 7pt gaps, and the specific gradients that make a plastic
 cap read as plastic and a rubber stick read as rubber. Approximating them produced
 something recognisably similar and obviously not the same thing.

 The three round controls are round because they are round on the pad — the dial and
 the stick are not keycaps and never take an icon.
 */
struct BoardCapView: View {
    let cell: BoardCell
    let slot: SlotView?
    let capID: String?
    let action: KeyAction?
    let isSelected: Bool
    /// Holding it does something: a dot in the corner. Settings window only.
    var hasHold: Bool = false
    /// The chosen app profile overrides it: an "S" badge. Settings window only.
    var isOverridden: Bool = false
    /// The ring's color, for the LED bar the pad has beside the touch hole. Nil draws
    /// it unlit.
    var ring: Appearance? = nil
    /**
     Drop the moulded-plastic finish.

     The settings window is a picture *of the pad*, so there the gradients and the
     contact shadow are the point — it should read as the object on your desk. The menu
     bar popover is a menu: it sits over whatever you were doing, at a glance, and
     fifteen little lit plastic objects in it is noise pretending to be realism.

     Same geometry either way. Only the material changes, so the two surfaces can never
     disagree about which key is where — which is the whole reason there is one view
     here rather than two.
     */
    var isFlat: Bool = false

    /**
     Key geometry, from the hardware rather than from the grid.

     Every cap on the pad is **square** — 1U — and the MIC is a 2U: twice the width,
     the same height. Letting the column width fall out of the grid instead made them
     44.25 wide by 51 tall, which is subtly wrong in a way that reads as "off" long
     before you can say why.

     2U is two keys plus the gap between them, not two keys, or the wide cap ends up
     narrower than the pair it replaces.
     */
    private static let unit: CGFloat = 51
    private static let gap: CGFloat = 7

    private var side: CGFloat { isTouch ? 30 : Self.unit }
    private var width: CGFloat {
        if isRound { return side }
        return cell.span > 1
            ? Self.unit * CGFloat(cell.span) + Self.gap * CGFloat(cell.span - 1)
            : Self.unit
    }
    private var isRound: Bool { isDial || isStick || isTouch }

    private var isDial: Bool { if case .element(.encoder) = cell.kind { true } else { false } }
    private var isStick: Bool { if case .element(.joystick) = cell.kind { true } else { false } }
    private var isTouch: Bool { if case .element(.touch) = cell.kind { true } else { false } }
    private var isAgent: Bool { if case .agent = cell.kind { true } else { false } }

    var body: some View {
        if isTouch && !isFlat {
            touchHole
        } else {
            cap
        }
    }

    /**
     The touch position, as the clone has it: no key, a hole through the plate, and the
     ring's four LEDs in a bar beside it.
     */
    private var touchHole: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Color(RGB(0x040405)), Color(RGB(0x18181A))],
                    center: UnitPoint(x: 0.45, y: 0.4), startRadius: 0, endRadius: 15
                ))
                .overlay { Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5) }
                .frame(width: 28, height: 28)
            if isSelected {
                Circle().strokeBorder(SystemColors.selectedRow, lineWidth: 2.5).frame(width: 36, height: 36)
            }
        }
        .frame(width: Self.unit, height: Self.unit)
        .overlay(alignment: .leading) {
            VStack(spacing: 2.5) {
                // Five, as on the plate's silkscreen and the line drawing of the pad.
                ForEach(0..<5, id: \.self) { _ in
                    Capsule()
                        .fill(ring.map { Color($0.color).opacity(0.55 + 0.45 * $0.brightness) }
                            ?? Color(RGB(0xCFCFCC)))
                        .frame(width: 5, height: 4)
                        .shadow(color: ring.map { Color($0.color).opacity(0.8) } ?? .clear, radius: 3)
                }
            }
            .padding(3)
            .background(Color(RGB(0xE6E6E3)), in: .rect(cornerRadius: 4))
            .offset(x: -12)
            .help(ring == nil ? tr("Los LED del anillo") : tr("Los LED del anillo, en su ajuste de un color"))
        }
        .contentShape(Circle())
    }

    private var cap: some View {
        ZStack {
            shell
            if isAgent && !isFlat && lit == nil { diffuser }
            if !isFlat && (isDial || isStick) { topMark }
            if !isFlat && !isRound { bevel }
            if let lit { glow(lit) }
            VStack(spacing: 3) {
                if !isRound, let icon = KeycapCatalog.icon(forCap: capID ?? "") {
                    KeycapIconView(icon: icon)
                        .frame(width: 18, height: 18)
                        // Ink on a white cap; the label color on a flat one, which has
                        // to invert with the system appearance rather than stay black.
                        //
                        // A concrete `Color`, never `AnyShapeStyle`. The icon is drawn
                        // in a `Canvas` with `.style(.foreground)`, and an erased style
                        // does not resolve there — the shapes render as nothing and the
                        // caps come out empty.
                        .foregroundStyle(isFlat ? Color.primary : Color(RGB(0x1A1A1A)))
                }
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(0.45)
                        .foregroundStyle(isStick || isTouch
                            ? Color.white.opacity(0.78)
                            : Color(RGB(0x121214)).opacity(0.82))
                        .shadow(color: .white.opacity(lit == nil ? 0 : 0.75), radius: 2)
                }
            }
            if isSelected { selectionRing }
        }
        .frame(width: width, height: side)
        .overlay(alignment: .topTrailing) {
            if hasHold {
                Circle()
                    .fill(Color(RGB(0x121214)).opacity(0.5))
                    .frame(width: 5, height: 5)
                    .padding(isRound ? 8 : 6)
                    .help(tr("Al mantenerla también hace algo"))
            }
        }
        .overlay(alignment: .topLeading) {
            if isOverridden {
                Text("S")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 13, height: 13)
                    .background(SystemColors.selectedRow, in: .circle)
                    // Inside the cap: outside it, the badge lands on the case screws.
                    .padding(isRound ? 2 : 4)
                    .help(tr("Sobrescrita en esta app"))
            }
        }
        .glassCap(isFlat: isFlat, shape: shape)
        .contentShape(shape)
    }

    private var shape: AnyShape {
        isRound ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    /// `AnyShape` erases `InsettableShape`, so a stroked border has to branch on the
    /// concrete type rather than going through the erased one.
    @ViewBuilder
    private func border(_ color: Color, width: CGFloat) -> some View {
        if isRound {
            Circle().strokeBorder(color, lineWidth: width)
        } else {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(color, lineWidth: width)
        }
    }

    /// The cap itself. Four materials: rubber for the stick and touch strip, and three
    /// slightly different plastics for the dial, the session caps and the action caps.
    private var shell: some View {
        shape
            .fill(fill)
            // A contact shadow: short, tight, close underneath. Keys sit *on* the
            // plate, they do not hover above it, and a soft blur around each one is
            // what turned fifteen objects into a cloud. Flat keys cast nothing.
            .shadow(
                color: .black.opacity(isFlat ? 0 : (isStick || isTouch ? 0.28 : 0.13)),
                radius: isFlat ? 0 : 1.5,
                y: isFlat ? 0 : 1
            )
    }

    private var fill: AnyShapeStyle {
        if isFlat {
            // Clear only where the glass actually lands. `glassCap` is a no-op below
            // macOS 26, so clearing unconditionally would have left the popover's caps
            // invisible on every system this package still deploys to — the fill *is*
            // the cap there.
            if #available(macOS 26.0, *) {
                return AnyShapeStyle(Color.clear)
            }
            return AnyShapeStyle(Color.primary.opacity(isRound ? 0.16 : 0.08))
        }
        if isStick || isTouch {
            return AnyShapeStyle(RadialGradient(
                colors: [Color(RGB(0x3C3C40)), Color(RGB(0x151518)), Color(RGB(0x08080A))],
                center: UnitPoint(x: 0.42, y: 0.30), startRadius: 1, endRadius: side * 0.85
            ))
        }
        if isDial {
            // Brushed aluminium: a bright band across a grey knob.
            return AnyShapeStyle(LinearGradient(
                stops: [
                    .init(color: Color(RGB(0xC9C9C7)), location: 0),
                    .init(color: Color(RGB(0xF3F3F1)), location: 0.38),
                    .init(color: Color(RGB(0xB4B4B1)), location: 0.62),
                    .init(color: Color(RGB(0x8E8E8B)), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            ))
        }
        if isAgent {
            // Frosted and translucent, so an LED underneath shows through the cap —
            // greyer than the opaque white action caps, as on the clone.
            return AnyShapeStyle(LinearGradient(
                stops: [
                    .init(color: Color(RGB(0xEEEFF0)).opacity(0.88), location: 0),
                    .init(color: Color(RGB(0xE1E2E4)).opacity(0.80), location: 0.60),
                    .init(color: Color(RGB(0xD2D4D6)).opacity(0.76), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            ))
        }
        return AnyShapeStyle(LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: Color(RGB(0xF6F5F2)), location: 0.58),
                .init(color: Color(RGB(0xE3E1DC)), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        ))
    }

    /**
     The marks on the two round controls' tops: a radial line on the dial (where it
     points), a dot on the stick's cap. The line drawing of the pad has both; without
     them the dial and the stick are the same disc in two colours.
     */
    @ViewBuilder
    private var topMark: some View {
        if isDial {
            Capsule()
                .fill(Color(RGB(0x5A5A58)).opacity(0.7))
                .frame(width: 2, height: side * 0.22)
                .offset(y: -side * 0.30)
        } else {
            Circle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 7, height: 7)
                .offset(y: -side * 0.26)
        }
    }

    /// The sculpted profile: a darker lip along the bottom edge, where the cap's
    /// front face turns under.
    private var bevel: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.72),
                        .init(color: .black.opacity(0.10), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 3
            )
            .allowsHitTesting(false)
    }

    /// The LED's diffuser, faintly visible through an unlit frosted cap.
    private var diffuser: some View {
        Circle()
            .strokeBorder(Color(RGB(0x9FAAB8)).opacity(0.35), lineWidth: 1.2)
            .frame(width: 15, height: 15)
    }

    /// The LED under a session cap, if it is lit.
    private var lit: Appearance? {
        guard isAgent, let appearance = slot?.appearance, appearance.effect != .off else {
            return nil
        }
        return appearance
    }

    private func glow(_ appearance: Appearance) -> some View {
        shape
            .fill(LinearGradient(
                stops: [
                    .init(color: pastel(appearance.color, 0.42), location: 0),
                    .init(color: pastel(appearance.color, 0.58), location: 0.58),
                    .init(color: pastel(appearance.color, 0.74), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            ))
            .opacity(0.6 + 0.4 * appearance.brightness)
            .overlay { border(pastel(appearance.color, 0.30), width: 1.5) }
            .shadow(color: Color(appearance.color).opacity(0.4), radius: 6)
    }

    /**
     Toward white by `amount`, matching the design's own `pastel()`.

     A cap is white plastic over a coloured LED, so what you see is never the raw
     colour — it is that colour washed out by the diffuser. Painting the raw value made
     every key look like a sticker.
     */
    private func pastel(_ color: RGB, _ amount: Double) -> Color {
        Color(
            .sRGB,
            red: color.red + (1 - color.red) * amount,
            green: color.green + (1 - color.green) * amount,
            blue: color.blue + (1 - color.blue) * amount
        )
    }

    private var selectionRing: some View {
        border(SystemColors.selectedRow, width: 2.5)
    }

    private var label: String {
        switch cell.kind {
        case let .agent(slot): "S\(slot)"
        case .element(.encoder): "DIAL"
        case .element(.joystick): "STICK"
        case .element(.touch): ""
        case .action: ""
        }
    }
}



// MARK: - Profiles, gestures and remote (F1, F2, F7)
//
// Subviews of the Board pane for the per-app profiles, Tap/Hold on the action caps,
// the agent keys' Remote block and the dangerous-snippet switch. Every edit goes
// through `SettingsEditing` and is announced with `bindingsChanged`, like the rest of
// the pane. Colors come from the system: `SystemColors` for selection, semantic
// styles for everything else.

/// A small uppercase caption, the inspector's section label.
private struct InspectorCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold)).kerning(0.8)
            .foregroundStyle(.tertiary)
    }
}

/**
 An action picker grouped under category headers, with each action's safeguards in
 its label and, under the picker, as badges for the one chosen.

 A menu item is plain text, so the badges ride in the label there ("… — requires
 Superset · two-step confirm"); the chips below repeat them for the current choice,
 where they have room to be read.
 */
struct GroupedActionPicker: View {
    @Binding var selection: KeyAction?
    var noneLabel: String
    var actions: [KeyAction] = KeyAction.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("", selection: $selection) {
                Text(noneLabel).tag(KeyAction?.none)
                ForEach(SettingsEditing.pickerSections(actions), id: \.category) { section in
                    Section(section.title) {
                        ForEach(section.actions, id: \.self) { action in
                            Text(label(action)).tag(KeyAction?.some(action))
                        }
                    }
                }
            }
            .labelsHidden()
            if let selection {
                ActionBadges(action: selection)
            }
        }
    }

    private func label(_ action: KeyAction) -> String {
        let badges = SettingsEditing.badges(for: action)
        return badges.isEmpty ? action.long : "\(action.long) — \(badges.joined(separator: " · "))"
    }
}

/// The safeguards of one action, as chips.
struct ActionBadges: View {
    let action: KeyAction

    var body: some View {
        let badges = SettingsEditing.badges(for: action)
        if !badges.isEmpty {
            HStack(spacing: 5) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: .capsule)
                }
            }
        }
    }
}

/// Shown under a control a profile cannot override.
struct SameEverywhereNote: View {
    var body: some View {
        Text(tr("Igual en todas las apps. Cámbialo en Todas las apps."))
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

/// Tap / Hold, for the action caps.
struct GesturePicker: View {
    @Binding var gesture: OpenBoardKit.Gesture

    var body: some View {
        Picker("", selection: $gesture) {
            Text(tr("Tocar")).tag(OpenBoardKit.Gesture.tap)
            Text(tr("Mantener")).tag(OpenBoardKit.Gesture.hold)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }
}

/**
 What holding an action cap does, and how long "held" is.

 In a profile the binding is an override of the base one; the threshold is one value
 for every cap and every app, so it is always editable here.
 */
struct HoldSection: View {
    @EnvironmentObject private var board: BoardModel
    @Environment(\.boardCommands) private var commands
    let cell: BoardCell
    let context: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorCaption(tr("AL MANTENER ESTA TECLA"))
            if let context {
                ProfileOverrideRow(control: .action(cell.id), gesture: .hold, profile: context, noneLabel: tr("nada"))
            } else {
                GroupedActionPicker(selection: holdBinding, noneLabel: tr("nada"))
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                InspectorCaption(tr("SE MANTIENE TRAS"))
                Spacer()
                Text(tr("%ld ms", board.preferences.actionLongPressMs))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(
                value: thresholdBinding,
                in: Double(SettingsEditing.longPressRange.lowerBound)...Double(SettingsEditing.longPressRange.upperBound),
                step: 50
            )
            Text(tr("Una tecla con acción al mantener espera este tiempo antes de tocar; una sin ella toca al instante."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var holdBinding: Binding<KeyAction?> {
        Binding(
            get: {
                ProfileResolver.resolve(.action(cell.id), .hold, frontBundleID: nil, prefs: board.preferences).action
            },
            set: { action in
                board.updatePreferences {
                    SettingsEditing.setAction(action, for: .action(cell.id), gesture: .hold, profile: nil, in: &$0)
                }
                commands.bindingsChanged()
            }
        )
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { Double(board.preferences.actionLongPressMs) },
            set: { ms in
                board.updatePreferences { SettingsEditing.setLongPressMs(Int(ms.rounded()), in: &$0) }
                commands.bindingsChanged()
            }
        )
    }
}

/**
 One control inside an app profile: the inherited binding greyed with "Override", or
 the profile's own with "Inherit again".

 Overriding starts from the inherited action, so pressing the button changes nothing
 until a new action is picked — the profile simply starts owning the binding.
 */
struct ProfileOverrideRow: View {
    @EnvironmentObject private var board: BoardModel
    @Environment(\.boardCommands) private var commands
    let control: PadControl
    let gesture: OpenBoardKit.Gesture
    let profile: String
    var noneLabel: String
    var actions: [KeyAction] = KeyAction.allCases

    var body: some View {
        let overridden = SettingsEditing.isOverridden(control, gesture: gesture, profile: profile, in: board.preferences)
        VStack(alignment: .leading, spacing: 5) {
            if overridden {
                GroupedActionPicker(selection: ownBinding, noneLabel: noneLabel, actions: actions)
                Button(tr("Heredar de nuevo")) {
                    board.updatePreferences {
                        SettingsEditing.clearOverride(control, gesture: gesture, profile: profile, in: &$0)
                    }
                    commands.bindingsChanged()
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Text(inheritedLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button(tr("Sobrescribir")) {
                        let current = resolved.action
                        board.updatePreferences {
                            SettingsEditing.setAction(current, for: control, gesture: gesture, profile: profile, in: &$0)
                        }
                        commands.bindingsChanged()
                    }
                    .controlSize(.small)
                }
                Text(tr("Heredado de Todas las apps."))
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
    }

    private var resolved: Resolved {
        ProfileResolver.resolve(control, gesture, frontBundleID: profile, prefs: board.preferences)
    }

    private var inheritedLabel: String {
        resolved.action?.long ?? noneLabel
    }

    private var ownBinding: Binding<KeyAction?> {
        Binding(
            get: { resolved.action },
            set: { action in
                board.updatePreferences {
                    SettingsEditing.setAction(action, for: control, gesture: gesture, profile: profile, in: &$0)
                }
                commands.bindingsChanged()
            }
        )
    }
}

/**
 Which app the Board pane is editing: "All apps" (the base bindings) or one app's
 profile, with "+" to add a profile for a running app.

 The "+" menu lists running apps rather than "the app in front": with this window
 open, the app in front is OpenBoard.
 */
struct ProfileContextBar: View {
    @EnvironmentObject private var board: BoardModel
    @Environment(\.boardCommands) private var commands
    @Binding var context: String?

    var body: some View {
        // Wraps rather than truncating: every app with a profile adds a chip.
        WrappingHStack(spacing: 6, lineSpacing: 6) {
            Text(tr("CONTEXTO"))
                .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                .foregroundStyle(.tertiary)
            chip(tr("Todas las apps"), selected: context == nil) { context = nil }
            ForEach(SettingsEditing.profileOrder(board.preferences), id: \.self) { bundle in
                chip(Self.appName(bundle), selected: context == bundle) { context = bundle }
                    .contextMenu {
                        Button(tr("Quitar perfil")) {
                            if context == bundle { context = nil }
                            board.updatePreferences { SettingsEditing.removeProfile(bundleID: bundle, in: &$0) }
                            commands.bindingsChanged()
                        }
                    }
            }
            Menu {
                let candidates = runningApps
                if candidates.isEmpty {
                    Text(tr("No hay ninguna otra app abierta"))
                }
                ForEach(candidates, id: \.bundle) { app in
                    Button(app.name) {
                        board.updatePreferences { SettingsEditing.addProfile(bundleID: app.bundle, in: &$0) }
                        commands.bindingsChanged()
                        context = app.bundle
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("Añadir un perfil para una app"))
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .fixedSize()
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(
                    selected
                        ? AnyShapeStyle(SystemColors.selectedRow.opacity(0.28))
                        : AnyShapeStyle(.quaternary.opacity(0.45)),
                    in: .capsule
                )
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    /// Regular apps that are running and have no profile yet, by name.
    private var runningApps: [(bundle: String, name: String)] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set(board.preferences.profiles.keys)
        var out: [(bundle: String, name: String)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundle = app.bundleIdentifier, bundle != own, !seen.contains(bundle) else { continue }
            seen.insert(bundle)
            out.append((bundle, app.localizedName ?? bundle))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func appName(_ bundle: String) -> String {
        if bundle == Preferences.supersetBundleID { return "Superset" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundle
    }
}

/**
 An agent key's Remote block: how a send is aimed at it and what it sends.

 The gesture wording follows `targeted.mode` (D10). "Only to an agent that has
 stopped" is shown as a fixed rule — it is `requireStopForSend`, a safety rule rather
 than a preference, so there is no control for it.
 */
struct RemoteBlock: View {
    @EnvironmentObject private var board: BoardModel

    var body: some View {
        let targeted = board.preferences.targeted
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                InspectorCaption(tr("REMOTO"))
                Text(targeted.mode == .armed ? tr("armado") : tr("acorde"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary.opacity(0.5), in: .capsule)
                Spacer(minLength: 0)
            }
            ActionBadges(action: .targetedArm)
            Text(SettingsEditing.remoteGesture(for: targeted.mode))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Text(tr("Envía"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(targeted.defaultSnippet)
                    .font(.system(size: 11.5).monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 5))
            }
            Label(tr("Solo a un agente que se haya detenido."), systemImage: "lock.fill")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/**
 A snippet that `SnippetGuard` would block: say so, and offer the switch that lets it
 through — behind a confirmation, because the key that typed `/clear` into the wrong
 window is why the guard exists.
 */
struct DangerousSnippetWarning: View {
    @EnvironmentObject private var board: BoardModel
    @Environment(\.boardCommands) private var commands
    let text: String
    @State private var confirming = false

    var body: some View {
        let allowed = board.preferences.snippetsAllowDangerous
        if case let .block(reason) = SnippetGuard.check(text, allowDangerous: false) {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    allowed ? tr("Permitido: %@", reason) : tr("Bloqueado: %@", reason),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(allowed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .fixedSize(horizontal: false, vertical: true)
                Toggle(tr("Permitir comandos peligrosos"), isOn: allowBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11.5))
            }
            .confirmationDialog(
                tr("¿Permitir que los textos escriban comandos destructivos?"),
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button(tr("Permitir"), role: .destructive) { setAllowed(true) }
                Button(tr("Cancelar"), role: .cancel) {}
            } message: {
                Text(tr("Se aplica a todas las teclas de texto. Una tecla que escribe /clear en la ventana equivocada no se puede deshacer."))
            }
        }
    }

    private var allowBinding: Binding<Bool> {
        Binding(
            get: { board.preferences.snippetsAllowDangerous },
            set: { on in
                if on { confirming = true } else { setAllowed(false) }
            }
        )
    }

    private func setAllowed(_ on: Bool) {
        board.updatePreferences { SettingsEditing.setAllowDangerousSnippets(on, in: &$0) }
        commands.bindingsChanged()
    }
}

/**
 Left to right, wrapping onto a new line when the next item does not fit. Items keep
 their ideal size — a chip is never squeezed into "Goo…".
 */
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if added > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row(items: [index], width: size.width, height: size.height))
            } else {
                rows[rows.count - 1].items.append(index)
                rows[rows.count - 1].width = added
                rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            }
        }
        return rows
    }
}

// MARK: - End profiles, gestures and remote

/**
 One harness in the sidebar: its mark, its name, and whether it is reporting.

 A plain row now rather than a `Button`. It used to draw its own selection because it
 navigated somewhere the `List` did not know about; now the list owns the selection for
 both kinds of row, so hand-drawn highlighting would be a second one fighting the first.
 */
struct HarnessRow: View {
    let harness: Harness
    let connected: Bool
    /// Has ever reported an event here. Distinct from `connected`, which is about now:
    /// a harness set up months ago and quiet today is not an empty state.
    let everSeen: Bool

    var body: some View {
        HStack(spacing: 9) {
            // A picture first, then a shape, then nothing at all. Hermes' mark is a
            // portrait with no monochrome form worth drawing, so it ships as the
            // favicon it already is — see ProviderRasters.
            if let png = ProviderRasters.data(iconID), let image = NSImage(data: png) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 15, height: 15)
                    .opacity(everSeen ? (connected ? 1 : 0.55) : 0.4)
            } else if let icon = ProviderIcons.icon(iconID) {
                KeycapIconView(icon: icon)
                    .frame(width: 15, height: 15)
                    // A concrete `Color`, never an inherited or erased style. The mark
                    // is drawn in a `Canvas` with `.style(.foreground)`, which resolves
                    // nothing in a sidebar row — the paths render as empty and the row
                    // shows a name with a hole where its logo should be.
                    .foregroundStyle(Color.primary)
                    .opacity(everSeen ? (connected ? 1 : 0.55) : 0.35)
            } else {
                Circle()
                    .strokeBorder(.tertiary, lineWidth: 1)
                    .frame(width: 13, height: 13)
                    .opacity(everSeen ? 1 : 0.5)
            }
            // The name outranks the dot. Without a priority the Spacer and the trailing
            // circle take their space first and the label is what truncates.
            Text(harness.name)
                .font(.system(size: 13))
                .foregroundStyle(everSeen ? .primary : .secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if everSeen {
                Circle()
                    .fill(connected ? Color(RGB(0x09B821)) : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
            // Nothing at all when it has never reported. The dimmed mark and label
            // already say it, and a word in the trailing slot competes with the dots
            // above it for a meaning it does not have.
        }
        .padding(.vertical, 1)
    }

    /// The catalogue is keyed by vendor, the harness by id — they agree everywhere
    /// except Claude Code, whose mark is filed under the product rather than the CLI.
    private var iconID: String {
        harness.id == "claude-code" ? "claude" : harness.id
    }
}

