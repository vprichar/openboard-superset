import OpenBoardKit
import SwiftUI

/**
 Superset — the host-service connection, NEW and the handoff, the two-step
 confirmation and remote sends: every `superset`, `launch`, `confirm` and `targeted`
 setting.

 Ordered the way the questions come up. First "is it connected?", because nothing else
 on the pane works until it is; then what the keys start, how they ask before doing it,
 and last the remote sends, which are the most involved and the least often changed.

 Every control writes through `SettingsEditing` and then `commands.bindingsChanged`,
 like the rest of the window: no save button, and the pad follows without a restart.

 Two things are never on screen: the manifest's token and the host-service's URL. The
 org id is shown because it is only a name for which manifest is in use.
 */
struct SupersetPane: View {
    @EnvironmentObject private var board: BoardModel
    @Environment(\.boardCommands) private var commands

    @State private var editingConfirmColor = false
    @State private var showAdvanced = false

    private var prefs: Preferences { board.preferences }

    /// One edit, saved and applied. The single path every control on this pane uses.
    private func edit(_ change: (inout Preferences) -> Void) {
        board.updatePreferences(change)
        commands.bindingsChanged()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SupersetStatusCard(
                    link: board.supersetLink,
                    hostClient: prefs.superset.hostClient,
                    reconnect: commands.reconnectSuperset
                )

                PaneHeader(tr("Conexión"), tr("Cómo OpenBoard lee los agentes de Superset y actúa sobre ellos."))
                connectionSection

                PaneHeader(tr("Agente nuevo y traspaso"), tr("Qué inician NEW y el traspaso en el espacio de trabajo activo."))
                launchSection

                PaneHeader(tr("Confirmación en dos pasos"), tr("La luz que pregunta antes de hacer un traspaso."))
                confirmSection

                PaneHeader(tr("Envíos remotos"), tr("Texto que se escribe en un agente sin cambiar a él."))
                targetedSection
            }
            .padding(22)
        }
    }

    // MARK: - connection

    private var hostClientBinding: Binding<Preferences.Superset.HostClient> {
        Binding(
            get: { prefs.superset.hostClient },
            set: { mode in edit { SettingsEditing.setHostClient(mode, in: &$0) } }
        )
    }

    private func supersetBinding<T>(_ path: WritableKeyPath<Preferences.Superset, T>) -> Binding<T> {
        Binding(
            get: { prefs.superset[keyPath: path] },
            set: { value in edit { SettingsEditing.setSuperset({ $0[keyPath: path] = value }, in: &$0) } }
        )
    }

    private func supersetMs(_ path: WritableKeyPath<Preferences.Superset, Int>) -> Binding<Double> {
        Binding(
            get: { Double(prefs.superset[keyPath: path]) },
            set: { value in
                edit { SettingsEditing.setSuperset({ $0[keyPath: path] = Int(value.rounded()) }, in: &$0) }
            }
        )
    }

    private var connectionSection: some View {
        SettingsBox {
            SettingRow(tr("Host-service"), tr("Apagado usa solo hooks y enlaces profundos, como antes.")) {
                Picker("", selection: hostClientBinding) {
                    Text(tr("Auto")).tag(Preferences.Superset.HostClient.auto)
                    Text(tr("Apagado")).tag(Preferences.Superset.HostClient.off)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            RowDivider()
            SettingRow(tr("Organización"), tr("Qué sesión de Superset sigue el pad.")) {
                HStack(spacing: 8) {
                    // The id is data and keeps the monospaced face; the fallback is
                    // wording, and SF Mono's accents are too faint for it.
                    Group {
                        if let org = prefs.superset.orgID {
                            Text(org)
                                .font(.system(size: 11.5).monospaced())
                        } else {
                            Text(tr("Detectada automáticamente"))
                                .font(.system(size: 11.5))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    if prefs.superset.orgID != nil {
                        Button(tr("Detectar")) {
                            edit { SettingsEditing.setSuperset({ $0.orgID = nil }, in: &$0) }
                        }
                        .controlSize(.small)
                        .help(tr("Seguir la organización que tenga manifiesto"))
                    }
                }
            }
            RowDivider()
            SettingRow(tr("Eventos en vivo"), tr("Ilumina las teclas en cuanto un agente empieza o se detiene.")) {
                Toggle("", isOn: supersetBinding(\.events)).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            SettingRow(
                tr("Otra versión de Superset"),
                tr("Probado con %@. Solo lectura permite consultas, nunca escribir.", prefs.superset.testedVersion)
            ) {
                Picker("", selection: supersetBinding(\.onVersionMismatch)) {
                    Text(tr("Solo lectura")).tag(Preferences.Superset.MismatchPolicy.readOnly)
                    Text(tr("Completo")).tag(Preferences.Superset.MismatchPolicy.full)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            RowDivider()
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(spacing: 0) {
                    SettingRow(tr("Agrupar inicios en"), tr("Un agente informa de un inicio en cada uso de herramienta.")) {
                        ValueSlider(
                            value: supersetMs(\.startDebounceMs),
                            range: 0...2000, step: 50, label: "\(prefs.superset.startDebounceMs) ms"
                        )
                    }
                    RowDivider()
                    SettingRow(tr("Contar duplicados una vez en"), tr("El mismo evento desde un hook y desde Superset.")) {
                        ValueSlider(
                            value: supersetMs(\.dedupeWindowMs),
                            range: 0...5000, step: 100, label: "\(prefs.superset.dedupeWindowMs) ms"
                        )
                    }
                    RowDivider()
                    SettingRow(tr("Como mucho una escritura al pad cada"), tr("Evita que una ráfaga de eventos sature el pad.")) {
                        ValueSlider(
                            value: supersetMs(\.padWriteCoalesceMs),
                            range: 0...500, step: 10, label: "\(prefs.superset.padWriteCoalesceMs) ms"
                        )
                    }
                    RowDivider()
                    SettingRow(tr("Comprobar sesiones al abrir"), tr("Confirma o cierra las restauradas de la última vez.")) {
                        Toggle("", isOn: supersetBinding(\.reconcileOnLaunch))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text(tr("Avanzado")).font(.system(size: 12.5))
            }
            .padding(.vertical, 7)
        }
    }

    // MARK: - launch

    private func launchBinding(_ path: WritableKeyPath<Preferences.Launch, String>) -> Binding<String> {
        Binding(
            get: { prefs.launch[keyPath: path] },
            set: { value in edit { SettingsEditing.setLaunch({ $0[keyPath: path] = value }, in: &$0) } }
        )
    }

    private var cooldownBinding: Binding<Double> {
        Binding(
            get: { Double(prefs.launch.createCooldownMs) },
            set: { value in
                edit { SettingsEditing.setLaunch({ $0.createCooldownMs = Int(value.rounded()) }, in: &$0) }
            }
        )
    }

    private var launchSection: some View {
        SettingsBox {
            SettingRow(tr("NEW inicia"), tr("En el espacio de trabajo en primer plano. Fuera de uno no pasa nada.")) {
                AgentField(agent: launchBinding(\.newAgent))
            }
            RowDivider()
            SettingRow(tr("El traspaso pasa la sesión activa a"), tr("Pregunta antes, con la luz de abajo.")) {
                AgentField(agent: launchBinding(\.handoffAgent))
            }
            RowDivider()
            SettingRow(tr("Contexto que se pasa"), handoffContextDetail) {
                Text(prefs.launch.handoffContextChars.map { tr("%ld caracteres", $0) } ?? tr("Sin verificar aún"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            RowDivider()
            SettingRow(tr("Ignorar un segundo NEW en"), tr("Una doble pulsación inicia un agente, no dos.")) {
                ValueSlider(
                    value: cooldownBinding,
                    range: 0...10000, step: 250,
                    label: seconds(prefs.launch.createCooldownMs)
                )
            }
        }
    }

    /// Informative until Superset's own limit is confirmed: offering a slider for a
    /// number nobody has checked would invite a value the host-service truncates.
    private var handoffContextDetail: String {
        prefs.launch.handoffContextChars == nil
            ? tr("Se aplica el límite propio de Superset hasta comprobarlo.")
            : tr("El final de la pantalla de la sesión activa.")
    }

    // MARK: - confirmation

    private var confirmColorBinding: Binding<RGB> {
        Binding(
            get: { prefs.confirm.color },
            set: { color in edit { SettingsEditing.setConfirm(color: color, in: &$0) } }
        )
    }

    private var confirmEffectBinding: Binding<LEDEffect> {
        Binding(
            get: { prefs.confirm.effect },
            set: { effect in edit { SettingsEditing.setConfirm(effect: effect, in: &$0) } }
        )
    }

    private var confirmBrightnessBinding: Binding<Double> {
        Binding(
            get: { prefs.confirm.brightness },
            set: { value in edit { SettingsEditing.setConfirm(brightness: value, in: &$0) } }
        )
    }

    private var confirmWindowBinding: Binding<Double> {
        Binding(
            get: { Double(prefs.confirm.windowMs) },
            set: { value in edit { SettingsEditing.setConfirm(windowMs: Int(value.rounded()), in: &$0) } }
        )
    }

    private var confirmSection: some View {
        SettingsBox {
            SettingRow(tr("Luz"), tr("Blanca por defecto: el ámbar ya significa que una sesión te espera.")) {
                HStack(spacing: 10) {
                    Button { editingConfirmColor = true } label: {
                        Swatch(color: prefs.confirm.color, brightness: prefs.confirm.brightness)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Color y hex"))
                    .popover(isPresented: $editingConfirmColor, arrowEdge: .bottom) {
                        ColorEditor(title: tr("Confirmación"), color: confirmColorBinding).padding(14)
                    }
                    Picker("", selection: confirmEffectBinding) {
                        ForEach([LEDEffect.solid, .breath, .shallowBreath], id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    Slider(value: confirmBrightnessBinding, in: 0...1).frame(width: 90)
                }
            }
            RowDivider()
            SettingRow(tr("Espera"), tr("Pulsa la tecla otra vez dentro de este tiempo para confirmar; cualquier otra cosa cancela.")) {
                ValueSlider(
                    value: confirmWindowBinding,
                    range: Double(SettingsEditing.confirmWindowRange.lowerBound)
                        ... Double(SettingsEditing.confirmWindowRange.upperBound),
                    step: 500,
                    label: seconds(prefs.confirm.windowMs)
                )
            }
            RowDivider()
            HStack {
                Text(tr("Reproduce la luz en el pad con una prueba inofensiva armada: APPR confirma, cualquier otra tecla cancela. En ningún caso se ejecuta nada."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button(tr("Probar en el pad")) { commands.previewConfirm() }
                    .disabled(!board.device.isUsable)
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - remote sends

    private func targetedBinding<T>(_ path: WritableKeyPath<Preferences.Targeted, T>) -> Binding<T> {
        Binding(
            get: { prefs.targeted[keyPath: path] },
            set: { value in edit { SettingsEditing.setTargeted({ $0[keyPath: path] = value }, in: &$0) } }
        )
    }

    private func targetedCount(_ path: WritableKeyPath<Preferences.Targeted, Int>) -> Binding<Double> {
        Binding(
            get: { Double(prefs.targeted[keyPath: path]) },
            set: { value in
                edit { SettingsEditing.setTargeted({ $0[keyPath: path] = Int(value.rounded()) }, in: &$0) }
            }
        )
    }

    private var maxSendBinding: Binding<Int> {
        Binding(
            get: { prefs.targeted.maxSendBytes },
            set: { value in edit { SettingsEditing.setMaxSendBytes(value, in: &$0) } }
        )
    }

    /// The gesture in force, spelled out: the mode's name alone does not say which
    /// keys to press.
    private var gestureExplanation: String {
        switch prefs.targeted.mode {
        case .armed: tr("Mantén FAST para armar, pulsa REJ para convertirlo en interrupción y luego la tecla del agente.")
        case .chord: tr("Mantén la tecla del agente y pulsa FAST para enviar o REJ para interrumpir.")
        }
    }

    private var targetedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsBox {
                SettingRow(tr("Apuntar con"), gestureExplanation) {
                    Picker("", selection: targetedBinding(\.mode)) {
                        Text(tr("Armado")).tag(Preferences.Targeted.Mode.armed)
                        Text(tr("Acorde")).tag(Preferences.Targeted.Mode.chord)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                RowDivider()
                SettingRow(tr("Envía"), tr("Lo que recibe una tecla de agente si no se elige otra cosa.")) {
                    CommitField(
                        placeholder: tr("texto"),
                        text: prefs.targeted.defaultSnippet,
                        width: 200
                    ) { text in
                        edit { SettingsEditing.setTargeted({ $0.defaultSnippet = text }, in: &$0) }
                    }
                }
                RowDivider()
                SettingRow(tr("Sigue armado durante"), tr("Después se cancela solo.")) {
                    ValueSlider(
                        value: targetedCount(\.windowMs),
                        range: 500...10000, step: 250,
                        label: seconds(prefs.targeted.windowMs)
                    )
                }
                RowDivider()
                SettingRow(tr("Envío máximo"), tr("El texto más largo se corta en el límite de un carácter.")) {
                    HStack(spacing: 6) {
                        TextField("", value: maxSendBinding, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5).monospaced())
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text(tr("bytes")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                RowDivider()
                SettingRow(tr("Pantalla leída antes"), tr("Líneas que se revisan antes de enviar o interrumpir.")) {
                    ValueSlider(
                        value: targetedCount(\.snapshotLines),
                        range: 1...100, step: 1,
                        label: tr("%ld líneas", prefs.targeted.snapshotLines)
                    )
                }
                RowDivider()
                // Locked on purpose: typing into an agent mid-turn interleaves with
                // whatever it is writing. Shown so the rule is visible, not hidden.
                SettingRow(
                    tr("Solo a un agente detenido"),
                    tr("Una regla de seguridad, no una preferencia: nunca se escribe en un agente ocupado.")
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Toggle("", isOn: .constant(prefs.targeted.requireStopForSend))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(true)
                    }
                    .help(tr("Siempre activado"))
                }
            }

            GroupLabel(tr("TEXTOS CON NOMBRE"))
            TargetedSnippetList(edit: edit)
        }
    }

    private func seconds(_ ms: Int) -> String {
        ms % 1000 == 0 ? "\(ms / 1000) s" : String(format: "%.1f s", Double(ms) / 1000)
    }
}

// MARK: - status

/**
 Whether the host-service is there, and what that allows.

 The read-only state is spelled out as a sentence rather than a badge: "read-only" alone
 does not say that NEW, the handoff and remote sends are the things that stopped.
 */
private struct SupersetStatusCard: View {
    let link: SupersetLinkState
    let hostClient: Preferences.Superset.HostClient
    let reconnect: @MainActor () -> Void

    private enum Tone { case good, caution, bad, neutral }

    private var tone: Tone {
        switch link {
        case .connected(_, let readOnly): readOnly ? .caution : .good
        case .versionMismatch: .caution
        case .unreachable: .bad
        case .off, .searching: .neutral
        }
    }

    private var dotColor: Color {
        switch tone {
        case .good: Color(RGB(0x09B821))
        case .caution: Color(RGB(0xFF6A00))
        case .bad: Color(RGB(0xD41145))
        case .neutral: Color.secondary.opacity(0.6)
        }
    }

    private var headline: String {
        switch link {
        case .off:
            hostClient == .off ? tr("Apagado") : tr("Sin conexión")
        case .searching:
            tr("Buscando…")
        case let .connected(version, readOnly):
            readOnly ? tr("Solo lectura · %@", version) : tr("Conectado · %@", version)
        case let .versionMismatch(found, tested):
            tr("Solo lectura: versión %@ ≠ probada %@", found, tested)
        case .unreachable:
            tr("Sin conexión")
        }
    }

    private var message: String {
        switch link {
        case .off:
            hostClient == .off
                ? tr("El pad solo sigue hooks y enlaces profundos. Cambia a Auto para usar Superset directamente.")
                : tr("Esperando a que arranque el host-service de Superset.")
        case .searching:
            tr("Leyendo el manifiesto de Superset y comprobando su versión.")
        case let .connected(_, readOnly):
            readOnly
                ? tr("Las teclas muestran agentes, pero NEW, el traspaso y los envíos remotos están desactivados hasta comprobar esta versión.")
                : tr("Las teclas siguen a los agentes de Superset y todas las acciones de Superset están disponibles.")
        case .versionMismatch:
            tr("Las teclas muestran agentes, pero NEW, el traspaso y los envíos remotos están desactivados hasta comprobar esta versión.")
        case let .unreachable(reason):
            tr("%@. El pad vuelve a usar hooks.", reason)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if case .searching = link {
                ProgressView().controlSize(.small)
            } else if hostClient == .auto {
                Button(tr("Reconectar")) { reconnect() }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }
}

// MARK: - snippets

/**
 The named remote snippets, sorted by name.

 Sorted, not hand-ordered: `targeted.snippets` is a dictionary on disk, and an order
 the file cannot keep would be one the list forgets on the next launch.
 */
private struct TargetedSnippetList: View {
    @EnvironmentObject private var board: BoardModel
    let edit: ((inout Preferences) -> Void) -> Void

    @State private var newName = ""
    @State private var newText = ""

    private var names: [String] { SettingsEditing.targetedSnippetNames(board.preferences) }

    private var canAdd: Bool {
        let name = newName.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty
            && !newText.trimmingCharacters(in: .whitespaces).isEmpty
            && board.preferences.targeted.snippets[name] == nil
    }

    var body: some View {
        SettingsBox {
            if names.isEmpty {
                Text(tr("Aún no hay ninguno. Una tecla de agente envía el texto de arriba."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
            }
            ForEach(names, id: \.self) { name in
                TargetedSnippetRow(
                    name: name,
                    text: board.preferences.targeted.snippets[name] ?? "",
                    edit: edit
                )
                RowDivider()
            }
            HStack(spacing: 8) {
                TextField(tr("nombre"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                TextField(tr("texto que enviar"), text: $newText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(tr("Añadir"), action: add).disabled(!canAdd)
            }
            .font(.system(size: 12))
            .padding(.vertical, 8)
        }
    }

    private func add() {
        guard canAdd else { return }
        let (name, text) = (newName, newText)
        edit { SettingsEditing.setTargetedSnippet(name: name, text: text, in: &$0) }
        newName = ""
        newText = ""
    }
}

private struct TargetedSnippetRow: View {
    let name: String
    let text: String
    let edit: ((inout Preferences) -> Void) -> Void

    var body: some View {
        HStack(spacing: 8) {
            CommitField(placeholder: tr("nombre"), text: name, width: 130) { renamed in
                edit { SettingsEditing.renameTargetedSnippet(from: name, to: renamed, in: &$0) }
            }
            CommitField(placeholder: tr("texto que enviar"), text: text, width: nil) { changed in
                guard !changed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                edit { SettingsEditing.setTargetedSnippet(name: name, text: changed, in: &$0) }
            }
            Button {
                edit { SettingsEditing.setTargetedSnippet(name: name, text: nil, in: &$0) }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(tr("Quitar %@", name))
        }
        .font(.system(size: 12))
        .padding(.vertical, 6)
    }
}

// MARK: - agent picker

/**
 `claude`, `codex`, or a Superset agent preset by its UUID.

 A menu for the two everyone uses and a text field for the rest, rather than a free
 field for all three: a typo in "claude" is a NEW that silently starts nothing.
 */
private struct AgentField: View {
    @Binding var agent: String
    @State private var custom = false

    private static let known = ["claude", "codex"]
    private static let customTag = "\u{0}custom"

    private var isKnown: Bool { Self.known.contains(agent) && !custom }

    var body: some View {
        HStack(spacing: 8) {
            if !isKnown {
                CommitField(placeholder: tr("UUID del preset"), text: Self.known.contains(agent) ? "" : agent, width: 150) {
                    agent = $0
                }
                .font(.system(size: 11.5).monospaced())
            }
            Picker("", selection: Binding(
                get: { isKnown ? agent : Self.customTag },
                set: { picked in
                    if picked == Self.customTag {
                        custom = true
                    } else {
                        custom = false
                        agent = picked
                    }
                }
            )) {
                Text("claude").tag("claude")
                Text("codex").tag("codex")
                Divider()
                Text(tr("Preset…")).tag(Self.customTag)
            }
            .labelsHidden()
            .frame(width: 110)
        }
    }
}

// MARK: - shared row pieces (also used by WorkspacePane)

/// A rounded group of rows, the same surface `ColorsPane` uses.
struct SettingsBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}

/// Title and a one-line explanation on the left, the control hard right.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    init(_ title: String, _ detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 7)
    }
}

struct RowDivider: View {
    var body: some View { Divider().opacity(0.3) }
}

/// A slider with its value, in its unit, beside it.
struct ValueSlider: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            // Rounded in the binding rather than `step:` on the slider: AppKit draws a
            // tick per step, and at 10 ms steps that is a dotted rule under every row.
            Slider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { raw in
                        let snapped = (raw / step).rounded() * step
                        value.wrappedValue = min(max(snapped, range.lowerBound), range.upperBound)
                    }
                ),
                in: range
            )
            .frame(width: 150)
            Text(label)
                .font(.system(size: 11).monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

/// The swatch a color popover hangs off, brightness shown as opacity like the state rows.
struct Swatch: View {
    let color: RGB
    var brightness: Double = 1

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(color))
            .opacity(0.35 + 0.65 * brightness)
            .frame(width: 26, height: 26)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
            }
    }
}

/**
 A text field that writes on Return or on losing focus, not per keystroke.

 Per keystroke would rename a snippet once per letter, saving the config each time and
 re-sorting the list under the cursor.
 */
struct CommitField: View {
    let placeholder: String
    let text: String
    let width: CGFloat?
    let commit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .focused($focused)
            .onSubmit(send)
            .onChange(of: focused) { _, now in
                guard !now else { return }
                send()
                // A refused edit (blank, or a name already taken) snaps back to what
                // is stored; an accepted one arrives through `onChange(of: text)`.
                draft = text
            }
            .onAppear { draft = text }
            .onChange(of: text) { _, new in draft = new }
    }

    private func send() {
        guard draft != text else { return }
        commit(draft)
    }
}
