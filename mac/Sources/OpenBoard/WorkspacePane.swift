import AppKit
import OpenBoardKit
import SwiftUI
import UniformTypeIdentifiers

/**
 Workspaces — what the pad does with Superset workspaces: which sessions the keys show,
 the switch animation, each workspace's color, and the borrowed key.

 The switch animation is an *event*: a sweep on the ring and the keys counting up,
 then the board as usual. The workspace color is only ever seen in passing, so it is
 edited here, next to the animation that shows it, rather than on Colors, whose rows
 are all things a key holds.

 Every control writes through `SettingsEditing` and then `commands.bindingsChanged`.
 */
struct WorkspacePane: View {
    @EnvironmentObject private var board: BoardModel
    @Environment(\.boardCommands) private var commands

    @State private var showTiming = false
    /// The naming sheet for saving, importing or renaming a theme.
    @State private var themeSheet: ThemeSheet?
    @State private var deletingTheme: CustomTheme?
    @State private var themeError: String?
    /// A one-line confirmation under the picker ("JSON copied…").
    @State private var themeNotice: String?
    /// A chosen theme playing on the pad before it is applied. See `ThemeSwitch`.
    @State private var themeSwitch = ThemeSwitch()
    /// Workspace id → worktree path, read from Superset's database when the pane opens.
    @State private var worktrees: [String: String] = [:]

    private var prefs: Preferences { board.preferences }
    private var transition: Preferences.WorkspaceTransition { prefs.workspaceTransition }

    private func edit(_ change: (inout Preferences) -> Void) {
        board.updatePreferences(change)
        commands.bindingsChanged()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(tr("Qué sesiones muestran las teclas"), tr("Mientras Superset está en primer plano."))
                scopeSection

                PaneHeader(tr("Cambio de espacio de trabajo"), tr("Una luz breve al cambiar de espacio de trabajo y luego el pad como siempre."))
                transitionSection

                // Above the workspace colors because it sets them too: pick a theme,
                // then fine-tune the palette below it.
                PaneHeader(tr("Tema"), tr("Colores del pad de un golpe: estados, paleta de espacios y confirmación. Cada estado conserva su significado."))
                themeSection

                PaneHeader(tr("Colores de espacios"), tr("Solo se ven de pasada: el barrido y el guiño de la tecla prestada."))
                identitySection

                PaneHeader(tr("Tecla prestada"), tr("La tecla 6, prestada a una sesión urgente de otro espacio de trabajo."))
                overflowSection
            }
            .padding(22)
        }
        .onAppear(perform: loadWorktrees)
    }

    // MARK: - scope

    private var scopeBinding: Binding<PadScope> {
        Binding(
            get: { prefs.padScope },
            set: { scope in edit { SettingsEditing.setPadScope(scope, in: &$0) } }
        )
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: scopeBinding) {
                Text(tr("Solo el espacio activo")).tag(PadScope.focusedWorkspace)
                Text(tr("Todas las sesiones")).tag(PadScope.all)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

            Text(
                prefs.padScope == .focusedWorkspace
                    ? tr("Las teclas muestran las sesiones del espacio de trabajo en primer plano; lo urgente de otros toma prestada la tecla 6.")
                    : tr("Cada sesión conserva su tecla, esté en primer plano el espacio de trabajo que esté.")
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - transition

    private func transitionBinding<T>(
        _ path: WritableKeyPath<Preferences.WorkspaceTransition, T>
    ) -> Binding<T> {
        Binding(
            get: { transition[keyPath: path] },
            set: { value in edit { SettingsEditing.setTransition({ $0[keyPath: path] = value }, in: &$0) } }
        )
    }

    private func transitionMs(
        _ path: WritableKeyPath<Preferences.WorkspaceTransition, Int>
    ) -> Binding<Double> {
        Binding(
            get: { Double(transition[keyPath: path]) },
            set: { value in
                edit { SettingsEditing.setTransition({ $0[keyPath: path] = Int(value.rounded()) }, in: &$0) }
            }
        )
    }

    private var animates: Bool { transition.style != .off }
    private var sweeps: Bool { transition.style == .sweepCascade && transition.ringSweep }

    private var styleExplanation: String {
        switch transition.style {
        case .sweepCascade: tr("El anillo hace un barrido con el color del espacio de trabajo mientras las teclas se encienden una a una.")
        case .cut: tr("Todas las teclas a la vez, con el anillo fijo un instante en el color del espacio de trabajo.")
        case .off: tr("Las teclas cambian de golpe. Nada en el anillo.")
        }
    }

    private var transitionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("", selection: transitionBinding(\.style)) {
                    Text(tr("Barrido y cuenta")).tag(Preferences.WorkspaceTransition.Style.sweepCascade)
                    Text(tr("Corte")).tag(Preferences.WorkspaceTransition.Style.cut)
                    Text(tr("Apagado")).tag(Preferences.WorkspaceTransition.Style.off)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Spacer(minLength: 12)
                Button(tr("Probar el barrido")) { commands.previewWorkspaceSweep() }
                    .disabled(!board.device.isUsable || !animates)
            }

            Text(styleExplanation)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsBox {
                SettingRow(tr("Respetar Reducir movimiento"), tr("Si está activado en macOS, un cambio pasa las teclas de golpe.")) {
                    Toggle("", isOn: transitionBinding(\.respectReduceMotion)).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingRow(tr("Barrido en el anillo"), tr("Desactivado deja la cuenta solo en las teclas.")) {
                    Toggle("", isOn: transitionBinding(\.ringSweep)).labelsHidden().toggleStyle(.switch)
                }
                .disabled(transition.style != .sweepCascade)
                RowDivider()
                SettingRow(tr("Entre teclas"), tr("Lo rápido que se encienden las teclas en cuenta.")) {
                    ValueSlider(
                        value: transitionMs(\.keyStaggerMs),
                        range: 0...Double(SettingsEditing.keyStaggerRange.upperBound), step: 10,
                        label: "\(transition.keyStaggerMs) ms"
                    )
                }
                .disabled(transition.style != .sweepCascade)
                RowDivider()
                SettingRow(tr("Velocidad del anillo"), tr("Busca más o menos una vuelta antes del fundido.")) {
                    ValueSlider(
                        value: transitionBinding(\.ringSpeed), range: 0...1, step: 0.01,
                        label: "\(Int(transition.ringSpeed * 100))%"
                    )
                }
                .disabled(!sweeps)
                RowDivider()
                SettingRow(tr("Brillo del anillo")) {
                    ValueSlider(
                        value: transitionBinding(\.ringBrightness), range: 0...1, step: 0.05,
                        label: "\(Int(transition.ringBrightness * 100))%"
                    )
                }
                .disabled(!sweeps)
                RowDivider()
                DisclosureGroup(isExpanded: $showTiming) {
                    timingRows.padding(.top, 4)
                } label: {
                    Text(tr("Tiempos")).font(.system(size: 12.5))
                }
                .padding(.vertical, 7)
            }
            .disabled(!animates)
            .opacity(animates ? 1 : 0.45)
        }
    }

    private var timingRows: some View {
        VStack(spacing: 0) {
            SettingRow(tr("Primera tecla tras")) {
                ValueSlider(value: transitionMs(\.firstKeyDelayMs), range: 0...500, step: 10,
                            label: "\(transition.firstKeyDelayMs) ms")
            }
            RowDivider()
            SettingRow(tr("Tecla prestada tras las demás")) {
                ValueSlider(value: transitionMs(\.overflowDelayMs), range: 0...500, step: 10,
                            label: "\(transition.overflowDelayMs) ms")
            }
            RowDivider()
            SettingRow(tr("El anillo se mantiene antes del fundido")) {
                ValueSlider(value: transitionMs(\.ringHoldMs), range: 0...3000, step: 50,
                            label: "\(transition.ringHoldMs) ms")
            }
            RowDivider()
            SettingRow(tr("Pasos del fundido")) {
                ValueSlider(value: transitionMs(\.ringFadeSteps),
                            range: Double(SettingsEditing.ringFadeStepsRange.lowerBound)
                                ... Double(SettingsEditing.ringFadeStepsRange.upperBound),
                            step: 1, label: "\(transition.ringFadeSteps)")
            }
            RowDivider()
            SettingRow(tr("Cada paso del fundido")) {
                ValueSlider(value: transitionMs(\.ringFadeStepMs), range: 10...200, step: 10,
                            label: "\(transition.ringFadeStepMs) ms")
            }
            RowDivider()
            SettingRow(tr("Esperar a que el cambio se asiente"), tr("Al recorrer espacios de trabajo solo se anima donde te detienes.")) {
                ValueSlider(value: transitionMs(\.debounceMs), range: 0...1000, step: 10,
                            label: "\(transition.debounceMs) ms")
            }
            RowDivider()
            SettingRow(tr("Cambiar de nuevo en"), tr("Cambia las teclas de golpe, sin un nuevo barrido.")) {
                ValueSlider(value: transitionMs(\.rapidWindowMs), range: 0...5000, step: 100,
                            label: seconds(transition.rapidWindowMs))
            }
            RowDivider()
            SettingRow(tr("Como mucho un barrido cada"), tr("Entre medias, las teclas siguen encendiéndose en cuenta.")) {
                ValueSlider(value: transitionMs(\.minSweepIntervalMs), range: 0...20000, step: 500,
                            label: seconds(transition.minSweepIntervalMs))
            }
        }
    }

    // MARK: - theme

    private let themeColumns = [GridItem(.adaptive(minimum: 138), spacing: 10)]

    private var themeSection: some View {
        let selection = SettingsEditing.themeSelection(prefs)
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: themeColumns, alignment: .leading, spacing: 10) {
                ForEach(ColorTheme.available(in: prefs)) { theme in
                    let custom = prefs.customThemes.first { $0.id == theme.id }
                    // Built-in themes pass by construction; only a custom one can
                    // have been saved over a warning.
                    let warnings = theme.isBuiltIn ? [] : ThemeRules.violations(theme).map(\.message)
                    ThemeCard(
                        title: theme.displayName,
                        // The count is on the card, not only in ⚠︎'s tooltip: a hover
                        // is not a place to find out a theme breaks the rules.
                        summary: theme.isBuiltIn ? tr(theme.summary)
                            : warnings.isEmpty ? tr("Tema propio")
                            : tr("Tema propio · avisos: %@", String(warnings.count)),
                        looks: ColorTheme.themedStates.map { theme.appearance(for: $0) },
                        palette: theme.palette,
                        selected: selection == .theme(theme.id),
                        warnings: warnings,
                        choose: { choose(theme) },
                        // Disabled rather than hidden without a pad: the button says
                        // what the card can do even before one is attached.
                        preview: { commands.previewTheme(theme) },
                        canPreview: board.device.isUsable,
                        playing: themeSwitch.pending == theme.id,
                        menu: ThemeCard.Menu(
                            duplicate: {
                                edit { SettingsEditing.duplicateTheme(theme, in: &$0) }
                                themeNotice = nil
                            },
                            rename: custom.map { c in { themeSheet = .rename(c) } },
                            export: { exportTheme(theme) },
                            copy: { copyTheme(theme) },
                            delete: custom.map { c in { deletingTheme = c } }
                        )
                    )
                }
            }

            HStack(spacing: 10) {
                Button(tr("Guardar como tema…")) { themeSheet = .save }
                SwiftUI.Menu(tr("Importar")) {
                    Button(tr("Desde un archivo…"), action: importFromFile)
                    Button(tr("Pegar del portapapeles"), action: importFromPasteboard)
                }
                .fixedSize()
                Spacer(minLength: 12)
                // No card is marked once a color was edited by hand; saying so beats a
                // picker that silently shows nothing selected.
                if selection == .custom {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(tr("Personalizado")).font(.system(size: 11.5, weight: .medium))
                    Text(tr("Tus colores, editados a mano."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)

            if let themeNotice {
                Text(themeNotice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $themeSheet) { sheet in
            themeNameSheet(sheet)
                .environmentObject(board)
        }
        .confirmationDialog(
            tr("¿Borrar el tema «%@»?", deletingTheme?.name ?? ""),
            isPresented: Binding(get: { deletingTheme != nil }, set: { if !$0 { deletingTheme = nil } }),
            titleVisibility: .visible
        ) {
            Button(tr("Borrar"), role: .destructive) {
                if let id = deletingTheme?.id { edit { SettingsEditing.deleteTheme(id: id, in: &$0) } }
                deletingTheme = nil
            }
            Button(tr("Cancelar"), role: .cancel) { deletingTheme = nil }
        } message: {
            Text(tr("Los colores que lleva ahora el pad no cambian."))
        }
        .alert(
            tr("No se pudo importar el tema"),
            isPresented: Binding(get: { themeError != nil }, set: { if !$0 { themeError = nil } })
        ) {
            Button(tr("Aceptar"), role: .cancel) { themeError = nil }
        } message: {
            Text(themeError ?? "")
        }
    }

    private func themeNameSheet(_ sheet: ThemeSheet) -> some View {
        switch sheet {
        case .save:
            let candidate = CustomTheme(current: prefs, id: "", name: "")
            return ThemeNameSheet(
                title: tr("Guardar como tema"),
                detail: tr("Guarda los colores que lleva ahora el pad: estados, paleta y confirmación."),
                initialName: SettingsEditing.uniqueThemeName(tr("Mi tema"), in: prefs),
                warnings: ThemeRules.violations(candidate.theme).map(\.message),
                action: tr("Guardar"),
                problem: { SettingsEditing.themeNameProblem($0, in: prefs) },
                done: { name in
                    edit { SettingsEditing.saveCurrentAsTheme(name: name, in: &$0) }
                    themeSheet = nil
                },
                cancel: { themeSheet = nil }
            )
        case let .importing(theme):
            return ThemeNameSheet(
                title: tr("Importar tema"),
                detail: tr("Se añade a tus temas; no se aplica hasta que elijas su tarjeta."),
                initialName: SettingsEditing.uniqueThemeName(theme.name, in: prefs),
                warnings: ThemeRules.violations(theme.theme).map(\.message),
                action: tr("Importar"),
                problem: { SettingsEditing.themeNameProblem($0, in: prefs) },
                done: { name in
                    var named = theme
                    named.name = name
                    edit { SettingsEditing.addTheme(named, in: &$0) }
                    themeSheet = nil
                },
                cancel: { themeSheet = nil }
            )
        case let .rename(theme):
            return ThemeNameSheet(
                title: tr("Renombrar tema"),
                detail: nil,
                initialName: theme.name,
                warnings: [],
                action: tr("Renombrar"),
                problem: { SettingsEditing.themeNameProblem($0, excluding: theme.id, in: prefs) },
                done: { name in
                    edit { SettingsEditing.renameTheme(id: theme.id, to: name, in: &$0) }
                    themeSheet = nil
                },
                cancel: { themeSheet = nil }
            )
        }
    }

    /**
     Choose a theme: the pad plays it first, filling every key, and the colors land
     when that ends — the board comes back already wearing them. Without a pad it
     applies at once. Choosing again while one plays: the last choice wins.
     */
    private func choose(_ theme: ColorTheme) {
        switch themeSwitch.select(theme.id, padReady: board.device.isUsable) {
        case .applyNow:
            edit { SettingsEditing.setTheme(theme, in: &$0) }
        case let .preview(ticket):
            commands.previewThemeThen(theme) {
                guard themeSwitch.previewEnded(ticket: ticket) != nil else { return }
                edit { SettingsEditing.setTheme(theme, in: &$0) }
            }
        }
    }

    // MARK: - theme files

    private func exportTheme(_ theme: ColorTheme) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(theme.displayName).openboard-theme.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ThemeFile.encode(theme).write(to: url, options: .atomic)
            themeNotice = tr("Tema exportado a %@.", url.lastPathComponent)
        } catch {
            themeError = tr("No se pudo escribir %@.", url.lastPathComponent)
        }
    }

    private func copyTheme(_ theme: ColorTheme) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(decoding: ThemeFile.encode(theme), as: UTF8.self), forType: .string)
        themeNotice = tr("JSON de «%@» copiado al portapapeles.", theme.displayName)
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            themeError = tr("No se pudo leer %@.", url.lastPathComponent)
            return
        }
        importTheme(data)
    }

    private func importFromPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            themeError = tr("El portapapeles no tiene texto.")
            return
        }
        importTheme(Data(text.utf8))
    }

    private func importTheme(_ data: Data) {
        do {
            themeSheet = .importing(try ThemeFile.decode(data))
        } catch let error as ThemeFileError {
            themeError = error.message
        } catch {
            themeError = ThemeFileError.notATheme.message
        }
    }

    // MARK: - identity

    private var stateColors: [RGB] { board.appearances.values.map(\.color) }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupLabel(tr("PALETA — UN ESPACIO DE TRABAJO SIN COLOR PROPIO TOMA UNO DE ESTOS"))
            PaletteEditor(
                palette: prefs.workspaceIdentity.palette,
                usable: WorkspaceColors.usablePalette(prefs.workspaceIdentity.palette, stateColors: stateColors),
                edit: edit
            )

            GroupLabel(tr("ESPACIOS DE TRABAJO"))
            workspaceList
        }
    }

    /// Superset's workspaces, plus any pinned id Superset no longer lists — a color
    /// that cannot be seen is still one that can be removed.
    private var workspaceIDs: [String] {
        let ids = Set(worktrees.keys).union(prefs.workspaceIdentity.colors.keys)
        return ids.sorted { workspaceName($0).localizedStandardCompare(workspaceName($1)) == .orderedAscending }
    }

    private func workspaceName(_ id: String) -> String {
        guard let path = worktrees[id] else { return id }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var workspaceList: some View {
        SettingsBox {
            if workspaceIDs.isEmpty {
                Text(tr("No se han encontrado espacios de trabajo de Superset en este Mac."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
            }
            ForEach(Array(workspaceIDs.enumerated()), id: \.element) { index, id in
                if index > 0 { RowDivider() }
                WorkspaceColorRow(
                    name: workspaceName(id),
                    path: worktrees[id],
                    pinned: prefs.workspaceIdentity.colors[id],
                    effective: WorkspaceColors.color(
                        for: id, identity: prefs.workspaceIdentity, stateColors: stateColors
                    ),
                    palette: prefs.workspaceIdentity.palette,
                    pin: { color in edit { SettingsEditing.setWorkspaceColor(color, workspaceID: id, in: &$0) } }
                )
            }
        }
    }

    /// Read-only, and not in a snapshot run: a rendering of the pane must not open the
    /// real `~/.superset` database.
    private func loadWorktrees() {
        let env = ProcessInfo.processInfo.environment
        guard env[SettingsSnapshots.environmentKey] == nil,
              let url = SupersetFocus.databaseURL(),
              let db = SupersetHostDatabase(url: url) else { return }
        worktrees = db.worktrees()
    }

    // MARK: - overflow

    private func overflowBinding<T>(_ path: WritableKeyPath<Preferences.Overflow, T>) -> Binding<T> {
        Binding(
            get: { prefs.overflow[keyPath: path] },
            set: { value in edit { SettingsEditing.setOverflow({ $0[keyPath: path] = value }, in: &$0) } }
        )
    }

    private func overflowMs(_ path: WritableKeyPath<Preferences.Overflow, Int>) -> Binding<Double> {
        Binding(
            get: { Double(prefs.overflow[keyPath: path]) },
            set: { value in
                edit { SettingsEditing.setOverflow({ $0[keyPath: path] = Int(value.rounded()) }, in: &$0) }
            }
        )
    }

    private var overflowSection: some View {
        SettingsBox {
            SettingRow(tr("Prestar la tecla 6"), tr("Solo si el espacio de trabajo en primer plano tiene cinco sesiones o menos.")) {
                Toggle("", isOn: overflowBinding(\.enabled)).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            Group {
                SettingRow(tr("Aspecto"), tr("Fija por defecto: todas las teclas locales respiran, así que fija se lee como «no es de aquí».")) {
                    HStack(spacing: 10) {
                        Picker("", selection: overflowBinding(\.effect)) {
                            ForEach([LEDEffect.solid, .breath, .shallowBreath], id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        Slider(value: overflowBinding(\.brightness), in: 0...1).frame(width: 90)
                    }
                }
                RowDivider()
                SettingRow(tr("Guiño con el color del espacio de origen"), tr("Un destello breve que indica dónde está la sesión.")) {
                    Toggle("", isOn: overflowBinding(\.winkOriginColor)).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                Group {
                    SettingRow(tr("Guiño cada")) {
                        ValueSlider(value: overflowMs(\.winkEveryMs), range: 1000...10000, step: 500,
                                    label: seconds(prefs.overflow.winkEveryMs))
                    }
                    RowDivider()
                    SettingRow(tr("Cada guiño dura")) {
                        ValueSlider(value: overflowMs(\.winkMs), range: 50...1000, step: 50,
                                    label: "\(prefs.overflow.winkMs) ms")
                    }
                }
                .disabled(!prefs.overflow.winkOriginColor)
            }
            .disabled(!prefs.overflow.enabled)
        }
    }

    private func seconds(_ ms: Int) -> String {
        ms % 1000 == 0 ? "\(ms / 1000) s" : String(format: "%.1f s", Double(ms) / 1000)
    }
}

// MARK: - theme card

/// What the theme naming sheet is for.
private enum ThemeSheet: Identifiable {
    case save
    case importing(CustomTheme)
    case rename(CustomTheme)

    var id: String {
        switch self {
        case .save: "save"
        case let .importing(theme): "import-" + theme.id
        case let .rename(theme): "rename-" + theme.id
        }
    }
}

/**
 One theme, as the board would look in it: the seven states in the order a glance reads
 them (idle to error), then the workspace palette.

 The card is the choice; the play button and the "…" menu inside it act on it without
 choosing it. A plain tap target rather than a `Button`, because a button nested in a
 button does not get its own clicks on macOS.
 */
private struct ThemeCard: View {
    struct Menu {
        var duplicate: () -> Void
        /// `nil` for a built-in theme, which cannot be renamed or deleted.
        var rename: (() -> Void)?
        var export: () -> Void
        var copy: () -> Void
        var delete: (() -> Void)?
    }

    let title: String
    let summary: String
    let looks: [Appearance]
    let palette: [RGB]
    let selected: Bool
    /// Readability rules this theme breaks; the card shows ⚠︎ with them as its help.
    var warnings: [String] = []
    let choose: () -> Void
    let preview: (() -> Void)?
    var canPreview = true
    /// Chosen and playing on the pad; applied when that ends.
    var playing = false
    var menu: Menu?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                        .help(tr("Tema en uso"))
                }
                if !warnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(RGB(0xFF6A00)))
                        .help(warnings.joined(separator: "\n"))
                        .accessibilityLabel(tr("Incumple reglas de legibilidad"))
                }
                Spacer(minLength: 0)
                if playing {
                    ProgressView()
                        .controlSize(.mini)
                        .help(tr("Probándolo en el pad; se aplica al terminar."))
                } else if let preview {
                    Button(action: preview) {
                        Image(systemName: "play.fill").font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .help(tr("Muestra el tema en las teclas unos segundos, sin aplicarlo."))
                    .accessibilityLabel(tr("Probar en el pad"))
                    .disabled(!canPreview)
                }
                if let menu {
                    SwiftUI.Menu {
                        Button(tr("Duplicar"), action: menu.duplicate)
                        if let rename = menu.rename { Button(tr("Renombrar…"), action: rename) }
                        Divider()
                        Button(tr("Exportar a archivo…"), action: menu.export)
                        Button(tr("Copiar como JSON"), action: menu.copy)
                        if let delete = menu.delete {
                            Divider()
                            Button(tr("Borrar…"), role: .destructive, action: delete)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(tr("Más acciones"))
                }
            }

            HStack(spacing: 3) {
                ForEach(Array(looks.enumerated()), id: \.offset) { _, look in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(look.color))
                        // Brightness as opacity, like the state rows on Colors.
                        .opacity(0.35 + 0.65 * look.brightness)
                        .frame(width: 14, height: 14)
                }
            }

            HStack(spacing: 5) {
                ForEach(Array(palette.prefix(8).enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(Color(color))
                        .frame(width: 10, height: 10)
                        .overlay { Circle().strokeBorder(.black.opacity(0.2), lineWidth: 0.5) }
                }
            }

            Text(summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(.quaternary.opacity(selected ? 0.5 : 0.3), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contentShape(.rect(cornerRadius: 10))
        .onTapGesture(perform: choose)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/**
 Name a theme — to save it, import it or rename it — and, when it breaks a readability
 rule, see every breach before saving anyway.

 One sheet for the three, so the warnings sit next to the button that accepts them:
 with breaches the button reads "Save anyway", which is the explicit confirmation.
 */
private struct ThemeNameSheet: View {
    let title: String
    let detail: String?
    let initialName: String
    let warnings: [String]
    let action: String
    let problem: (String) -> String?
    let done: (String) -> Void
    let cancel: () -> Void

    @State private var name = ""
    @FocusState private var focused: Bool

    private var nameProblem: String? { problem(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField(tr("Nombre"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { if nameProblem == nil { done(name) } }
                Text(nameProblem ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(RGB(0xD41145)))
            }

            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(tr("Este tema incumple reglas de legibilidad:"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color(RGB(0xFF6A00)))
                    ForEach(warnings, id: \.self) { warning in
                        Text("• " + warning)
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(tr("Puedes guardarlo igualmente; su tarjeta llevará ⚠︎."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
            }

            HStack {
                Spacer()
                Button(tr("Cancelar"), action: cancel).keyboardShortcut(.cancelAction)
                Button(warnings.isEmpty ? action : tr("Guardar de todas formas")) { done(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameProblem != nil)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            name = initialName
            focused = true
        }
    }
}

// MARK: - palette

/**
 The palette as swatches: click one to change it, "+" to add.

 A swatch too close to a state's color is marked rather than refused — the pad skips
 it (`WorkspaceColors.usablePalette`), and saying so beats a color that silently never
 shows.
 */
private struct PaletteEditor: View {
    let palette: [RGB]
    let usable: [RGB]
    let edit: ((inout Preferences) -> Void) -> Void

    @State private var editing: Int?

    /// Offered first when adding: the shipped colors not already in the palette.
    private var nextColor: RGB {
        Preferences.WorkspaceIdentity.defaultPalette.first { !palette.contains($0) } ?? RGB(0xD6E4FF)
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(palette.enumerated()), id: \.offset) { index, color in
                Button { editing = index } label: {
                    Swatch(color: color)
                        .overlay(alignment: .topTrailing) {
                            if !usable.contains(color) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white, Color(RGB(0xFF6A00)))
                                    .offset(x: 4, y: -4)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(usable.contains(color) ? color.hex : tr("%@ — demasiado parecido al color de un estado; se omite", color.hex))
                .popover(isPresented: Binding(
                    get: { editing == index },
                    set: { if !$0 { editing = nil } }
                ), arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        ColorEditor(title: tr("Color de la paleta"), color: colorBinding(index))
                        Button(tr("Quitar de la paleta"), role: .destructive) {
                            editing = nil
                            var next = palette
                            next.remove(at: index)
                            edit { SettingsEditing.setPalette(next, in: &$0) }
                        }
                        .controlSize(.small)
                        .disabled(palette.count <= 1)
                    }
                    .padding(14)
                }
            }

            Button {
                let next = palette + [nextColor]
                edit { SettingsEditing.setPalette(next, in: &$0) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("Añadir un color"))

            if usable.count < palette.count {
                Text(tr("Los colores marcados se parecen demasiado a un estado y se omiten."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func colorBinding(_ index: Int) -> Binding<RGB> {
        Binding(
            get: { index < palette.count ? palette[index] : nextColor },
            set: { color in
                guard index < palette.count else { return }
                var next = palette
                next[index] = color
                edit { SettingsEditing.setPalette(next, in: &$0) }
            }
        )
    }
}

// MARK: - one workspace

private struct WorkspaceColorRow: View {
    let name: String
    let path: String?
    let pinned: RGB?
    let effective: RGB
    let palette: [RGB]
    let pin: (RGB?) -> Void

    @State private var editingCustom = false

    private var customBinding: Binding<RGB> {
        Binding(get: { pinned ?? effective }, set: { pin($0) })
    }

    var body: some View {
        HStack(spacing: 12) {
            Swatch(color: effective)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12.5)).lineLimit(1)
                Text(pinned == nil ? tr("De la paleta") : tr("Color propio"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .help(path ?? tr("Superset ya no lo muestra"))
            Spacer(minLength: 12)
            Menu {
                ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                    Button(color.hex) { pin(color) }
                }
                Divider()
                Button(tr("Otro color…")) { editingCustom = true }
                if pinned != nil {
                    Divider()
                    Button(tr("Usar la paleta")) { pin(nil) }
                }
            } label: {
                Text(tr("Color"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .popover(isPresented: $editingCustom, arrowEdge: .bottom) {
                ColorEditor(title: name, color: customBinding).padding(14)
            }
        }
        .padding(.vertical, 7)
    }
}
