import OpenBoardKit
import SwiftUI

/**
 Colors — everything the pad emits, on one pane.

 This was two tabs, Keys & Colors and Fun, and the split did not survive the question
 "which one holds the ring?". The ring is a color the board shows; so are the laps that
 fire on it, the toy shows, and the countdown. They were filed under Fun because they
 are animated, which is a fact about *how* they light rather than about what they are.

 These are **hardware** colors: the swatch and the LED are the same number. So the
 editor offers the real ones as presets and any hex besides, but no system color picker,
 whose output would be a screen color that happens to be nearby.

 ## Less scrolling, same controls

 Each state used to be a block about 110pt tall — swatch, ten presets, a hex field, an
 effect picker, two sliders — and seven of those meant most of a screen of scrolling
 before reaching anything else. Now a state is one row, and the color controls sit in a
 popover behind its swatch. Nothing was dropped: presets, hex, speed and the hardware
 preview are all still there, one click further in, which is the right distance for
 values that are set once and then left.

 Ordered by how often a thing is touched rather than by how it is implemented: colors,
 how long they stay, the ring, then fun mode.
 */
struct ColorsPane: View {
    @EnvironmentObject private var board: BoardModel
    @Environment(\.boardCommands) private var commands

    private let showColumns = [GridItem(.adaptive(minimum: 210), spacing: 10)]

    // MARK: - how long a color stays

    private var holdsDone: Bool { board.preferences.doneDecaySeconds <= 0 }

    /// Zero means never, which is what the registry's decay already understands — so
    /// the toggle writes the same field rather than adding a second source of truth.
    private var holdDoneBinding: Binding<Bool> {
        Binding(
            get: { holdsDone },
            set: { hold in
                board.updatePreferences { $0.doneDecaySeconds = hold ? 0 : 90 }
                commands.bindingsChanged()
            }
        )
    }

    private var doneSecondsBinding: Binding<Double> {
        Binding(
            get: { Double(max(10, board.preferences.doneDecaySeconds)) },
            set: { value in
                board.updatePreferences { $0.doneDecaySeconds = Int(value.rounded()) }
                commands.bindingsChanged()
            }
        )
    }

    private var holdAttentionBinding: Binding<Bool> {
        Binding(
            get: { board.preferences.holdAttention },
            set: { hold in
                board.updatePreferences { $0.holdAttention = hold }
                commands.bindingsChanged()
            }
        )
    }

    // MARK: - the ring

    private var currentAmbientMode: Ambient.Mode {
        Ambient.Mode(rawValue: board.preferences.ambient.mode) ?? .events
    }

    private var ambientModeBinding: Binding<Ambient.Mode> {
        Binding(
            get: { currentAmbientMode },
            set: { mode in
                board.updatePreferences { $0.ambient.mode = mode.rawValue }
                commands.bindingsChanged()
            }
        )
    }

    private var fixedColorBinding: Binding<Color> {
        Binding(
            get: { Color(board.preferences.ambient.fixed.color) },
            set: { picked in
                guard let rgb = RGB(picked) else { return }
                board.updatePreferences { $0.ambient.fixed.color = rgb }
                commands.bindingsChanged()
            }
        )
    }

    private var fixedBrightnessBinding: Binding<Double> {
        Binding(
            get: { board.preferences.ambient.fixed.brightness },
            set: { value in
                board.updatePreferences { $0.ambient.fixed.brightness = value }
                commands.bindingsChanged()
            }
        )
    }

    /// What the selected mode actually does. Restored because the four words on the
    /// segments are a name each, not a description — "Show the board" and "Laps only"
    /// are indistinguishable until you know that one holds a color and the other is
    /// dark between events.
    private var ambientExplanation: String {
        switch currentAmbientMode {
        case .events: tr("Apagado, salvo una vuelta cuando algo cambia.")
        case .aggregate: tr("Mantiene el color de la sesión más urgente. Las vueltas siguen saliendo.")
        case .fixed: tr("Mantiene un color haga lo que haga el tablero. Las vueltas siguen saliendo.")
        case .off: tr("Nunca se enciende, ni siquiera con vueltas.")
        }
    }

    private func lapBinding(
        _ path: WritableKeyPath<Preferences.Ambient, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { board.preferences.ambient[keyPath: path] },
            set: { value in
                board.updatePreferences { $0.ambient[keyPath: path] = value }
                commands.bindingsChanged()
            }
        )
    }

    // MARK: - state rows

    private func stateBinding(_ state: SessionState) -> Binding<Appearance> {
        Binding(
            get: { board.appearances[state] ?? state.defaultAppearance },
            set: { next in
                board.appearances[state] = next
                commands.bindingsChanged()
            }
        )
    }

    private var unconfirmedBinding: Binding<Appearance> {
        Binding(
            get: { board.preferences.unconfirmedAppearance },
            set: { next in
                board.updatePreferences { SettingsEditing.setUnconfirmedAppearance(next, in: &$0) }
                commands.bindingsChanged()
            }
        )
    }

    // MARK: - fun mode

    /// Both halves are required: the analysis without the video has nothing to sync to,
    /// and the video without the analysis has nothing to sync *with*.
    private var mediaPresent: Bool {
        guard let media = Countdown.mediaDirectory(
            configured: board.preferences.countdown.mediaDir
        ) else { return false }
        return Countdown.loadAnalysis(directory: media) != nil
            && Countdown.findVideo(directory: media) != nil
    }

    /// The song the Play button would start. Falls back to a bare verb rather than a
    /// guess: with no media there is no song to name, and the button is disabled anyway.
    private var selectedSong: String {
        guard let media = Countdown.mediaDirectory(
            configured: board.preferences.countdown.mediaDir
        ) else { return "" }
        return Countdown.songTitle(media.lastPathComponent)
    }

    /// Only a *refusal* is worth warning about. QuickTime reports nothing useful while
    /// it is not running, which is the normal state before fun mode starts — treating
    /// that as missing would be a permanent false alarm on a working machine.
    private var permissionMissing: Bool {
        PermissionProbe.automation(bundleID: "com.apple.QuickTimePlayerX") == .denied
    }

    // MARK: - body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // "Colors" was doing two jobs — page title and the heading for the
                // rows below it. The title goes; the heading it was quietly providing
                // has to stay, or the states arrive unannounced.
                PaneHeader(tr("Estados"), tr("Cómo se ve cada uno en una tecla de sesión."))
                statesSection

                HStack {
                    Button(tr("Restablecer valores predeterminados")) { commands.resetColors() }
                        .controlSize(.small)
                    Spacer(minLength: 0)
                    Text(tr("Guardado en %@", PreferencesStore.url().lastPathComponent))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                PaneHeader(tr("Cuánto dura un color"), tr("Cuándo borra el tablero un color por su cuenta."))
                holdSection

                PaneHeader(tr("El anillo"), tr("La luz exterior, que resume todo el tablero."))
                ringSection

                // Kept: "Fun mode" says nothing, and this one takes over the entire
                // board — including status — for four minutes.
                PaneHeader(tr("Modo diversión"), tr("Ocupa todo el pad, estado incluido, mientras dura la canción."))
                funSection
            }
            .padding(22)
        }
    }

    // MARK: - sections

    private var statesSection: some View {
        VStack(spacing: 0) {
            // Column headers, aligned to StateRow's fixed widths. The swatch is the
            // least discoverable control on the pane — it opens color, hex and speed —
            // so the leading header says so instead of naming the column.
            HStack(spacing: 12) {
                GroupLabel(tr("ESTADO — CLIC EN LA MUESTRA: COLOR, HEX Y VELOCIDAD"))
                Spacer(minLength: 8)
                GroupLabel(tr("EFECTO")).frame(width: 130, alignment: .leading)
                GroupLabel(tr("BRILLO")).frame(width: 90, alignment: .leading)
                // Same footprint as the row's play button, so the columns line up.
                Image(systemName: "play.fill").font(.system(size: 9)).hidden()
            }
            .padding(.top, 9)
            .padding(.bottom, 3)

            ForEach(Array(SessionState.displayOrder.enumerated()), id: \.element) { index, state in
                Divider().opacity(index > 0 ? 0.3 : 0.15)
                StateRow(
                    title: state.label,
                    means: state.means,
                    appearance: stateBinding(state),
                    preview: { commands.previewState(state) }
                )
            }

            // Not a `SessionState`: a claim restored at launch that no live event has
            // confirmed yet. Last, because it is what a state looks like *before* it is
            // one of the rows above.
            Divider().opacity(0.3)
            StateRow(
                title: tr("sin confirmar"),
                means: tr("Restaurada al abrir la app, aún no vista en vivo."),
                appearance: unconfirmedBinding,
                preview: { commands.previewUnconfirmed() }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }

    private var holdSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            holdToggle(
                state: .done,
                title: tr("Mantener encendidas las sesiones terminadas hasta que vuelvas"),
                detail: tr("Se borra cuando le envías algo a esa sesión."),
                isOn: holdDoneBinding
            )

            if !holdsDone {
                HStack(spacing: 8) {
                    Text(tr("Se borra tras"))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Slider(value: doneSecondsBinding, in: 10...600, step: 10)
                        .frame(width: 200)
                    Text("\(board.preferences.doneDecaySeconds)s")
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                }
                .padding(.leading, 38)
            }

            Divider().opacity(0.35)

            holdToggle(
                state: .awaiting,
                title: tr("Mantener encendidas las sesiones mientras te esperan"),
                detail: board.preferences.holdAttention
                    ? tr("Se borra en cuanto respondes.")
                    // Kept: an orange that vanishes on its own otherwise looks like the
                    // board losing track rather than a deliberate bound.
                    : tr("Se borra al responder, o a los 15 min si nadie responde."),
                isOn: holdAttentionBinding
            )
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }

    private var ringSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: ambientModeBinding) {
                Text(tr("Solo vueltas")).tag(Ambient.Mode.events)
                Text(tr("Ver tablero")).tag(Ambient.Mode.aggregate)
                Text(tr("Un color")).tag(Ambient.Mode.fixed)
                Text(tr("Sin luz")).tag(Ambient.Mode.off)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            if currentAmbientMode == .fixed {
                HStack(spacing: 10) {
                    ColorPicker("", selection: fixedColorBinding, supportsOpacity: false)
                        .labelsHidden()
                    Text(board.preferences.ambient.fixed.color.hex)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                    Slider(value: fixedBrightnessBinding, in: 0...1).frame(width: 150)
                    Text("\(Int(board.preferences.ambient.fixed.brightness * 100))%")
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Text(ambientExplanation)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Above the laps, because it is not one: a lap fires and ends, this holds
            // for as long as the machine is listening.
            VStack(spacing: 0) {
                lapToggle(tr("Girar mientras dictas"), isOn: lapBinding(\.voiceRainbow))
            }
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))

            GroupLabel(tr("VUELTAS"))
            VStack(spacing: 0) {
                lapToggle(tr("Termina un chat"), isOn: lapBinding(\.completionLap))
                Divider().opacity(0.3)
                lapToggle(tr("Uno te necesita"), isOn: lapBinding(\.questionLap))
                Divider().opacity(0.3)
                lapToggle(tr("Uno falla"), isOn: lapBinding(\.errorPulse))
            }
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
            .disabled(currentAmbientMode == .off)
            .opacity(currentAmbientMode == .off ? 0.45 : 1)

            GroupLabel(tr("REPRODUCIR UNO AHORA"))
            LazyVGrid(columns: showColumns, spacing: 10) {
                ForEach(Shows.all, id: \.name) { show in
                    ShowCard(show: show, running: board.runningShow == show.name) {
                        commands.playShow(show.name)
                    }
                }
            }
        }
    }

    /**
     One lap switch: label hard left, switch hard right.

     A `Toggle` carrying its own label is only as wide as it needs to be, and the
     enclosing `VStack` centres it — which put the text and the switch together in the
     middle of the row with empty space on both sides, reading as neither a list nor a
     form. An explicit `HStack` with a `Spacer` is the only version that cannot drift.
     */
    /**
     A hold switch, with the color it is talking about.

     The labels used to name the colors — "keep finished sessions **green**" — which is
     wrong the moment anyone edits the palette directly above. The swatch is read from
     the same configured appearance the pad emits, so the sentence stays true whatever
     `done` and `awaiting` have been set to.
     */
    private func holdToggle(
        state: SessionState,
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        let appearance = board.appearances[state] ?? state.defaultAppearance
        return HStack(spacing: 10) {
            Circle()
                .fill(Color(appearance.color))
                .frame(width: 10, height: 10)
                .overlay { Circle().strokeBorder(.black.opacity(0.2), lineWidth: 0.5) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    private func lapToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 12.5))
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 7)
    }

    private var funSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(board.funModeRunning ? tr("Detener")
                        : selectedSong.isEmpty ? tr("Reproducir") : tr("Reproducir %@", selectedSong)) {
                    commands.playCountdown()
                }
                .disabled(!board.device.isUsable || !mediaPresent)
                if board.funModeRunning {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            if !mediaPresent {
                Text(tr("No hay video instalado — pon uno en %@.", AppPaths.media().path))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(RGB(0xFF6A00)))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Said here as well as in the log, because a deliberately dark pad and a
                // broken one look identical — two early runs were cancelled at 3 and 10
                // beats, well before it was going to light.
                Text(
                    tr("El anillo sigue apagado durante los primeros %.1fs.",
                       board.preferences.countdown.introFlashSec)
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }

            if permissionMissing {
                Text(tr("Necesita Automatización → QuickTime Player, en el panel Dispositivo."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(RGB(0xFF6A00)))
            }
        }
    }
}

/**
 One state, as a single row.

 Swatch, name, effect, brightness — the four worth seeing for all states at once.
 Everything else lives behind the swatch: presets, hex and speed are set once and then
 left, while comparing states against each other is what this pane is for.

 Takes the appearance as a binding rather than a `SessionState`, so the same row serves
 `unconfirmed`, which is stored beside the states but is not one of them.
 */
private struct StateRow: View {
    let title: String
    let means: String
    @Binding var appearance: Appearance
    /// Shows it on the pad; `nil` hides the button but keeps its column.
    let preview: (() -> Void)?

    @State private var editing = false

    var body: some View {
        HStack(spacing: 12) {
            Button { editing = true } label: {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(appearance.color))
                    // Brightness reads as opacity, so a row at 20% does not claim the
                    // same presence as one at 100%.
                    .opacity(appearance.effect == .off ? 0.15 : 0.35 + 0.65 * appearance.brightness)
                    .frame(width: 26, height: 26)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .help(tr("Color, hex y velocidad"))
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                // The editor writes through bindings that already hold the model and
                // the commands, so nothing depends on environment values crossing
                // into the popover's own window — which macOS does not reliably do.
                ColorEditor(
                    title: title,
                    color: $appearance.color,
                    speed: appearance.effect.isAnimated ? $appearance.speed : nil
                )
                .padding(14)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                // Kept: `stalled` and `viewing` are this product's words, not anything
                // anyone arrives already knowing.
                Text(means)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if appearance.color.isNearWhite, appearance.effect != .off {
                    Text(tr("Casi blanco — el pad reposa en blanco, así que parecerá apagado."))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color(RGB(0xFF6A00)))
                }
            }

            Spacer(minLength: 8)

            Picker("", selection: $appearance.effect) {
                // The spatial effects are not offered: snake and gradient only mean
                // anything on the multi-LED ring and render a single key dark.
                ForEach([LEDEffect.solid, .breath, .shallowBreath, .rainbow, .off], id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Slider(value: $appearance.brightness, in: 0...1).frame(width: 90)

            Button { preview?() } label: {
                Image(systemName: "play.fill").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help(tr("Mostrar este estado en el pad"))
            .opacity(preview == nil ? 0 : 1)
            .disabled(preview == nil)
        }
        .padding(.vertical, 7)
    }
}

/**
 The color itself: presets, hex, and speed when the effect moves.

 Internal, not private: the Superset and Workspaces panes pick hardware colors too (the
 confirmation light, the workspace palette), and a second editor would be a second
 set of presets to keep in step. It edits bindings, not a state, for the same reason.
 */
struct ColorEditor: View {
    let title: String
    @Binding var color: RGB
    /// Shown when the effect animates; `nil` hides the slider.
    var speed: Binding<Double>?

    @State private var hexDraft = ""
    @FocusState private var hexFocused: Bool

    init(title: String, color: Binding<RGB>, speed: Binding<Double>? = nil) {
        self.title = title
        self._color = color
        self.speed = speed
    }

    /// The hardware legend, plus a few useful neighbours.
    ///
    /// Presets rather than a color wheel because these are the values the product's
    /// vocabulary is built on — and because picking "roughly orange" off a wheel is how
    /// `awaiting` stops being unmistakable.
    private static let presets: [(name: String, rgb: RGB)] = [
        ("Pizarra", RGB(0x2E4A6B)),
        ("Azul", RGB(0x0C47E9)),
        ("Naranja", RGB(0xFF6A00)),
        ("Verde", RGB(0x09B821)),
        ("Carmesí", RGB(0xD41145)),
        ("Violeta", RGB(0x7B2FF7)),
        ("Cian", RGB(0x00C8D7)),
        ("Ámbar", RGB(0xFFB300)),
        ("Magenta", RGB(0xE81CA8)),
        ("Negro", RGB(0x000000)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12.5, weight: .semibold))

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 5),
                spacing: 8
            ) {
                ForEach(Self.presets, id: \.name) { preset in
                    // The draft is synced by hand, and it is load-bearing: clicking a
                    // preset also blurs the hex field, and blur commits the draft.
                    // Left stale, that commit writes the *old* color straight back
                    // over the preset just picked — the click appears to not take,
                    // in either blur-then-click order.
                    Button {
                        color = preset.rgb
                        hexDraft = preset.rgb.hex
                    } label: {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(preset.rgb))
                            .frame(width: 24, height: 24)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(
                                        color == preset.rgb
                                            ? Color.primary : .black.opacity(0.25),
                                        lineWidth: color == preset.rgb ? 2 : 0.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(tr(preset.name))
                }
            }

            HStack(spacing: 8) {
                TextField("hex", text: $hexDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5).monospaced())
                    .frame(width: 96)
                    .focused($hexFocused)
                    .onSubmit(commitHex)
                    // Committed on blur too, so a typed value is not silently lost by
                    // clicking away.
                    .onChange(of: hexFocused) { _, focused in if !focused { commitHex() } }

                // What the typed value looks like, before committing it. Falls back
                // to the current color while the draft is not yet a parseable hex,
                // so a half-typed value reads as "no change yet" rather than black.
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(RGB(hex: hexDraft) ?? color))
                    .frame(width: 24, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
                    )
                    .help(tr("Previsualización del valor hex"))
            }

            if let speed {
                HStack(spacing: 8) {
                    Text(tr("Velocidad")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Slider(value: speed, in: 0...1).frame(width: 110)
                    Text("\(Int(speed.wrappedValue * 100))%")
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .frame(width: 214)
        .onAppear { hexDraft = color.hex }
        .onChange(of: color) { _, new in
            if !hexFocused { hexDraft = new.hex }
        }
    }

    private func commitHex() {
        guard let parsed = RGB(hex: hexDraft) else {
            hexDraft = color.hex
            return
        }
        // A draft that matches the current color is not an edit — it is the seed, or
        // a preset click that already synced it. Writing it anyway is how a blur
        // used to overwrite a preset pick with the value the field was seeded with.
        guard parsed != color else { return }
        color = parsed
        hexDraft = parsed.hex
    }
}

/// A small-caps label for a group inside a section.
///
/// One step below `PaneHeader`: a section says what part of the product this is, a
/// group label says what the next few rows have in common. Used where the difference
/// matters — three switches and six buttons under one heading read as nine unrelated
/// controls without it.
struct GroupLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold)).kerning(0.8)
            .foregroundStyle(.tertiary)
    }
}
