import OpenBoardKit
import SwiftUI

/**
 Device — connection, permissions, calibration, and what is deliberately inert.

 The permissions section is the important one. Several families, granted separately and
 independently — Input Monitoring and Bluetooth are both "talking to the pad" and having
 one says nothing about the other. Each produces a differently-shaped silent failure,
 and the app cannot fix any of them, so the least it can do is say precisely which is
 missing and open the right pane.
 */
struct DevicePane: View {
    @EnvironmentObject private var board: BoardModel
    @EnvironmentObject private var updater: Updater
    @Environment(\.boardCommands) private var commands

    @State private var permissions = PermissionProbe.inspect()
    @State private var hooks = HookInstall.Audit(statuses: [:], settingsExists: false)
    @State private var calibrating = false
    @State private var hookNote: String?
    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?
    @State private var allGranted = false
    @State private var requestingAutomation = false
    @State private var automationNote: String?
    @State private var keybinding = KeybindingInstall.Audit(status: .missing, fileExists: false)
    @State private var chordNote: String?
    /// The interface language. Written here for SwiftUI, and through
    /// `UIStrings.storedLanguage` for everything else — see `languageBinding`.
    @AppStorage(UIStrings.defaultsKey) private var uiLanguage = UIStrings.defaultLanguage.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // First, because someone who cannot read the rest has to find it
                // without reading the rest.
                languageSection

                HStack(spacing: 10) {
                    Circle()
                        .fill(board.device.isUsable ? Color(RGB(0x09B821)) : Color(RGB(0xD41145)))
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(board.device.headline(board.deviceName)).font(.system(size: 13, weight: .semibold))
                        Text(board.device.message)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))

                // Kept: someone grants a permission, comes back, sees no change, and
                // concludes the app is broken.
                PaneHeader(tr("Permisos"), tr("Cada uno se aplica al reiniciar OpenBoard."))
                VStack(spacing: 0) {
                    permissionRow(
                        "Input Monitoring", tr("leer el pad: toda la iluminación y cada tecla"),
                        status: permissions.inputMonitoring, pane: "Privacy_ListenEvent"
                    )
                    permissionRow(
                        "Accessibility", tr("escribir textos, enviar ⏎ y ⎋, desplazarse"),
                        status: permissions.accessibility, pane: "Privacy_Accessibility"
                    )
                    // Separate from Input Monitoring, even though both are "talking to
                    // the pad": the battery is read as a Bluetooth central, and macOS
                    // gates that on its own.
                    permissionRow(
                        "Bluetooth", tr("leer el nivel de batería del pad"),
                        status: permissions.bluetooth, pane: "Privacy_Bluetooth"
                    )
                    // iTerm2's row would nag anyone who does not use iTerm2 at all.
                    // `optional` now already tracks whether iTerm2 is installed, but
                    // `optional` only ever changes what a rendered row *says* — the
                    // "when needed" label further down — not whether a row appears at
                    // all. Every entry in `automationTargets` gets a row from this
                    // `ForEach`, so filtering iTerm2 out here when it is not installed
                    // is still the only thing making it invisible rather than merely
                    // quiet; `automation(bundleID:)` itself is already harmless either
                    // way.
                    ForEach(
                        PermissionProbe.automationTargets.filter {
                            $0.bundleID != "com.googlecode.iterm2"
                                || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
                        },
                        id: \.bundleID
                    ) { target in
                        permissionRow(
                            "Automation → \(target.name)", why(automating: target.name),
                            status: permissions.automation[target.name] ?? .unknown,
                            pane: "Privacy_Automation",
                            subject: target.name,
                            optional: target.optional
                        )
                    }
                }
                HStack(spacing: 8) {
                    /*
                     The button worked and looked like it did not.

                     Re-probing is instant and usually finds exactly what was already on
                     screen, so pressing it changed nothing visible — and a button that
                     appears to do nothing is indistinguishable from one that is broken.
                     It is pressed precisely when someone has just granted something in
                     System Settings and wants to be told, so now it answers out loud.

                     Only on success. A failure already has an answer on screen: the row
                     that is not green, and the list beside this button.
                     */
                    Button(tr("Comprobar ahora")) {
                        permissions = PermissionProbe.inspect()
                        allGranted = permissions.missing.isEmpty
                    }
                    .controlSize(.small)
                    .disabled(requestingAutomation)

                    /*
                     Automation is the only permission the app can raise a prompt for
                     itself, and until now it was the only one it did not.

                     The other three send you to System Settings because that is where
                     they are granted. Automation is not: it has no "request access"
                     API, macOS asks when something tries to drive the target, and
                     System Events — the one the key actions need — is a launch-on-demand
                     helper that is asleep most of the time. So its row sat at "not
                     running" beside an Open button leading to a pane where OpenBoard was
                     not yet listed, because it had never asked for anything.

                     QuickTime is not in this. It prompts itself the first time fun mode
                     opens the video, which is the better moment — the user has just
                     asked for the thing the dialog is about.

                     Shown only while there is something to ask for. Once the required
                     targets have answered the button is not a control, it is a leftover.
                     */
                    if !automationSettled {
                        Button(requestingAutomation ? tr("Preguntando") : tr("Conceder permisos")) {
                            requestAutomation()
                        }
                        .controlSize(.small)
                        .disabled(requestingAutomation)
                        .help(tr("Pide a macOS permiso para controlar System Events y las terminales a las que salta una tecla: Terminal, e iTerm2 si está instalado. QuickTime no se incluye: el modo diversión lo pide por su cuenta la primera vez que lo reproduces."))
                    }

                    if !permissions.missing.isEmpty {
                        Text(tr("Faltan: %@", permissions.missing.map(permissionName).joined(separator: ", ")))
                            .font(.system(size: 11))
                            .foregroundStyle(Color(RGB(0xFF6A00)))
                    }
                }

                if let automationNote {
                    Text(automationNote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                /*
                 Key order and Hooks are gone from this pane.

                 Both were one-time setup wearing the clothes of a setting. The key order
                 is the layout every pad reports and is now assumed rather than gated on;
                 the hooks are wired once and then never thought about again. A settings
                 window is for things you change, and a permanent readout of two answered
                 questions is furniture.

                 Neither check went away — see `refresh()`. The audit still runs at
                 launch and writes its verdict to the log, which is where a *broken*
                 install has always been diagnosed from.

                 Repair did not go away either. `hooksProblem` below still offers it,
                 and has to: a new install has all eight hooks missing, which is the
                 one state where the app runs, the pad connects, and nothing ever
                 lights. What is gone is the permanent readout on a healthy machine.
                */
                // Hooks have no section either, but a *broken* install still has to be
                // fixable: without them the app runs, the pad connects, and nothing ever
                // lights. So this appears only when the audit finds a problem, and is
                // absent entirely on a healthy machine — an error, not a readout.
                if !hooks.isHealthy {
                    hooksProblem
                }

                PaneHeader(tr("La tecla de voz"), tr("Cómo llega un toque de voz a Claude Code."))
                voiceChordSection

                PaneHeader(tr("Inicio"), tr("Configurar OpenBoard y mantenerlo en marcha."))
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: loginItemBinding) {
                        Text(tr("Abrir OpenBoard al iniciar sesión")).font(.system(size: 12.5))
                    }
                    .toggleStyle(.switch)
                    .disabled(!LoginItem.isInstalledProperly)

                    if !LoginItem.isInstalledProperly {
                        // Registration is tied to the bundle path, so a copy running
                        // from a build directory registers a path that will vanish.
                        Text(tr("Mueve antes OpenBoard a /Applications: un ítem de inicio registrado desde otro sitio falla cuando esa carpeta cambia."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(RGB(0xFF6A00)))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if loginStatus == .awaitingApproval {
                        Text(tr("Esperando aprobación en Ajustes del Sistema → General → Ítems de inicio."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(RGB(0xFF6A00)))
                    } else if case let .unavailable(reason) = loginStatus {
                        Text(reason)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(RGB(0xFF6A00)))
                    }
                    if let loginError {
                        Text(loginError).font(.system(size: 11.5))
                            .foregroundStyle(Color(RGB(0xD41145)))
                    }

                    // Grouped here as the other thing you do once when setting up, and
                    // then never again. It is not a setting — nothing about it changes
                    // in daily use — but it is the only way to fix a pad whose keys are
                    // in an order this app did not expect, and deleting the button
                    // would leave the capture sheet as code nothing calls, which is how
                    // four separate bugs got into this app.
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Orden de teclas")).font(.system(size: 12.5))
                        Text(calibrationStatus)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button(board.isCalibrationConfirmed ? tr("Recalibrar") : tr("Comprobar orden de teclas")) {
                                calibrating = true
                            }
                            .controlSize(.small)
                            .disabled(!board.device.isUsable)

                            if !board.device.isUsable {
                                Text(tr("Conecta antes el pad."))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                // Before Files, not after. Files is reference and this is actionable,
                // and the actionable thing should not sit below the list of paths
                // nobody scrolls past.
                PaneHeader(tr("Versión"), tr("Qué compilación es y cómo se actualiza."))
                updateSection

                PaneHeader(tr("Archivos"), tr("Dónde se guardan tus ajustes y el registro."))
                configFileSection
            }
            .padding(22)
        }
        // Re-probed on appearance because these are granted *outside* the app: someone
        // flips a switch in System Settings and comes straight back here, and a stale
        // red would send them round the loop again.
        .onAppear { refresh() }
        .sheet(isPresented: $calibrating) { CalibrationSheet() }
        // Everything, not just what lighting and keys need: someone checking after a
        // trip to System Settings wants to know the whole list is clear. A target that
        // is merely not running does not count against it — see PermissionProbe.Status.
        .alert(tr("Todos los permisos concedidos"), isPresented: $allGranted) {
            Button(tr("Aceptar"), role: .cancel) {}
        }
    }

    /**
     What the board currently believes about which key is which.

     The button had no context: "Recalibrate" on its own answers neither "is anything
     wrong?" nor "what would I be changing?", so the honest reading was that pressing it
     might break something that currently works.

     Three states, and the middle one is why this is not a boolean. A calibration that
     was checked and came out identity behaves exactly like the assumption — but one is
     an answer and the other is a guess that has held so far, and collapsing them would
     throw away the only thing the check produces.
     */
    private var calibrationStatus: String {
        let calibration = board.calibration
        if calibration.isAssumed {
            return tr("Sin comprobar. Se usa el orden que reportan todos los pads hasta ahora: posición 1 arriba a la izquierda y luego en orden de lectura.")
        }

        // Dated in the interface language, not the system's, so the sentence and its
        // date agree.
        let when = calibration.recordedAt.map {
            $0.formatted(
                Date.FormatStyle(date: .abbreviated, time: .omitted)
                    .locale(Locale(identifier: UIStrings.current.rawValue))
            )
        }

        guard calibration.isCustom else {
            return when.map { tr("Comprobado el %@: el orden estándar, posición 1 arriba a la izquierda.", $0) }
                ?? tr("Comprobado: el orden estándar, posición 1 arriba a la izquierda.")
        }
        let moved = calibration.movedSlots
            .map { tr("posición %ld → tecla %ld", $0.slot, $0.key) }
            .joined(separator: ", ")
        return when.map { tr("Orden personalizado registrado el %@: %@.", $0, moved) }
            ?? tr("Orden personalizado registrado: %@.", moved)
    }

    /**
     Nothing left to ask about.

     Optional targets do not count. QuickTime Player prompts itself the first time fun
     mode runs, so it is never something this button could obtain — leaving it in the
     sum meant the button stayed on screen forever, offering to do a thing it would then
     skip.

     A denial counts as settled: macOS will not re-prompt once someone has said no, and
     only System Settings can undo it. `unavailable` does not — that is a target asleep
     rather than an answer, and `refresh()` wakes it before this is read.
     */
    private var automationSettled: Bool {
        PermissionProbe.automationTargets
            .filter { !$0.optional }
            .allSatisfy { target in
                let status = permissions.automation[target.name] ?? .unknown
                return status == .granted || status == .denied
            }
    }

    /**
     Ask macOS for the automation grants, one target at a time.

     The summary afterwards matters more than it looks. Each target produces a *system*
     dialog, and someone who clicks through two of them has no idea which they answered
     which way — least of all when one of them briefly opened QuickTime Player. So the
     result is stated rather than left to be inferred from two dots changing colour.

     A denial is reported without alarm. Automation is optional: without System Events
     the snippet keys stop working, without QuickTime fun mode does, and neither is the
     board. Painting a refusal red would imply something is broken that is not.
     */
    private func requestAutomation() {
        requestingAutomation = true
        automationNote = nil
        // Captured before, so the summary can report what this click *did* rather than
        // what happens to be true afterwards. Listing everything currently granted read
        // as "I just granted these three" when all three were already on — taking
        // credit for work it did not do, and leaving the real answer ("nothing needed
        // asking") unsaid.
        let before = permissions.automation

        Task {
            let results = await AutomationRequest.requestAll(current: before)
            permissions = PermissionProbe.inspect()
            requestingAutomation = false

            let changed = results.filter { before[$0.name]?.isGranted != true }
            let granted = changed.filter { $0.status.isGranted }.map(\.name)
            let refused = changed.filter { $0.status == .denied }.map(\.name)
            let unanswered = changed.filter { $0.status != .granted && $0.status != .denied }

            var parts: [String] = []
            if !granted.isEmpty { parts.append(tr("Concedido: %@.", granted.joined(separator: ", "))) }
            if !refused.isEmpty {
                parts.append(tr("Denegado: %@. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Automatización.",
                                refused.joined(separator: ", ")))
            }
            if !unanswered.isEmpty {
                // Dismissing the dialog without choosing, or a target that would not
                // start. Neither is a decision, so the button stays available.
                parts.append(tr("Aún sin respuesta de %@.", unanswered.map(\.name).joined(separator: ", ")))
            }
            automationNote = parts.isEmpty
                ? tr("Nada que conceder: todo lo que OpenBoard necesita ya está permitido.")
                : parts.joined(separator: " ")
        }
    }

    /**
     Where the settings live, read from the store rather than written down.

     A hardcoded path is a caption that can be wrong: `OPENBOARD_HOME` moves the whole
     state directory, and a label claiming otherwise sends someone to edit a file the
     app is not reading.

     Two rows, because state and logs are deliberately in different places: logs live
     where Console.app looks, and can be thrown away without losing a setting.
     */
    private var configFileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fileRow(tr("Ajustes"), url: PreferencesStore.url())
            fileRow(tr("Registro"), url: Log.url)
            // Kept: it names capabilities that exist nowhere else in the UI.
            Text(tr("Se puede editar a mano. Guarda algunos ajustes que esta ventana no muestra."))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /**
     Which build this is, and how it gets a newer one.

     Its own section rather than a line under Files, which is where it started. Files is
     reference — here is where things live, nothing to do. This is the opposite: a
     status that changes and a button that acts on it, and burying an action under a
     list of paths is how it stays unfound.

     There is no About window, so this is also the only answer to "what version are you
     on?" short of reading Info.plist in a terminal — a poor first question to ask
     someone reporting a bug. Selectable, because the point is to paste it into an issue.

     The controls are hidden rather than disabled in a build that cannot update. A
     disabled control is a promise that something would happen if only you were allowed;
     a locally-built copy will never have an update feed, so there is nothing to promise
     — the status line says why instead.
     */
    private var updateSection: some View {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(tr("Versión"))
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 54, alignment: .leading)
                Text("\(short) (\(build))")
                    .font(.system(size: 11.5).monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text(updateStatusText)
                .font(.system(size: 11.5))
                .foregroundStyle(
                    updater.status.isFailure
                        ? AnyShapeStyle(Color(RGB(0xD41145)))
                        : AnyShapeStyle(.secondary)
                )
                .fixedSize(horizontal: false, vertical: true)

            if commands.canUpdate {
                HStack(spacing: 10) {
                    // A switch, matching Starting up. Both are "should the app do this
                    // on its own", and two different controls for one question read as
                    // two different kinds of setting.
                    Toggle(isOn: Binding(
                        get: { commands.automaticUpdates() },
                        set: { commands.setAutomaticUpdates($0) }
                    )) {
                        Text(tr("Buscar actualizaciones automáticamente")).font(.system(size: 12.5))
                    }
                    .toggleStyle(.switch)

                    Spacer(minLength: 0)

                    Button(updater.status.updateVersion == nil ? tr("Comprobar ahora") : tr("Instalar")) {
                        if updater.status.updateVersion == nil {
                            commands.checkForUpdates()
                        } else {
                            commands.showAvailableUpdate()
                        }
                    }
                    .controlSize(.small)
                    .disabled(updater.status == .checking)
                }
            }
        }
    }

    /**
     One line under the version, saying what the updater knows.

     "Never checked" and "no update found" are told apart on purpose. A status line that
     only knows a boolean renders both as silence, and the difference is the entire
     question when someone is wondering why they have not been offered a release they
     know shipped.
     */
    private var updateStatusText: String {
        switch updater.status {
        case .disabled:
            return tr("Las actualizaciones están desactivadas en esta compilación del fork: recompílala para actualizar.")
        case .notChecked:
            // Sparkle remembers the last check across launches, so "not checked yet"
            // alone would be misleading the morning after one — the app has checked,
            // just not since it started.
            guard let last = updater.lastCheck else { return tr("Aún sin comprobar.") }
            return tr("Última comprobación: %@.", Self.relative(last))
        case .checking:
            return tr("Comprobando")
        case .available(let version):
            return tr("La versión %@ está disponible.", version)
        case .upToDate:
            guard let last = updater.lastCheck else { return tr("Al día.") }
            return tr("Al día. Última comprobación: %@.", Self.relative(last))
        case .failed(let message):
            return tr("No se pudo comprobar: %@", message)
        }
    }

    /// Shared so the two branches above cannot drift into phrasing the same instant
    /// two different ways.
    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        // The interface language, not the system's, so "3 minutes ago" matches the
        // sentence it sits in.
        f.locale = Locale(identifier: UIStrings.current.rawValue)
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// One path, shortened to `~` and openable. Disabled rather than hidden when the
    /// file does not exist yet: the path is still the answer to "where would it be?".
    private func fileRow(_ label: String, url: URL) -> some View {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        return HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 54, alignment: .leading)
            Text(shown)
                .font(.system(size: 11.5).monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(tr("Mostrar")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .controlSize(.small)
            .disabled(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginStatus.isOn },
            set: { wanted in
                switch LoginItem.set(wanted) {
                case let .success(status):
                    loginStatus = status
                    loginError = nil
                case let .failure(error):
                    loginError = error.localizedDescription
                    loginStatus = LoginItem.status
                }
            }
        )
    }

    private func refresh() {
        permissions = PermissionProbe.inspect()
        // System Events is asleep most of the time, and a permission it has held for
        // months then reads as "not running". Wake it and ask again, so the row shows
        // the grant rather than the helper's nap schedule.
        if permissions.automation["System Events"] == .unavailable {
            Task {
                await AutomationRequest.wakeProbeableTargets()
                permissions = PermissionProbe.inspect()
            }
        }
        // Read live rather than remembered: the registration is tied to the bundle
        // path and signature, so it can go stale exactly like a hook path can.
        loginStatus = LoginItem.status
        hooks = HookInstall.audit(
            settings: HookInstall.loadSettings(),
            expectedCommand: HookInstall.hookCommandPath()
        )
        keybinding = KeybindingInstall.audit(document: KeybindingInstall.load())
    }

    /**
     The one voice setting that is genuinely a choice.

     Space starts dictation only when the chat input is empty; otherwise the tap
     types a space. The ⌃Y chord invokes `voice:pushToTalk` directly and types
     nothing — but needs its binding in `~/.claude/keybindings.json`, which is
     written when the toggle goes on (backup first, nothing else touched). A chord
     the user already bound to something else is reported, never overwritten.
     */
    private var voiceChordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: voiceChordBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Tocar ⌃Y en vez de espacio")).font(.system(size: 12.5))
                    Text(tr("Espacio escribe un espacio si la entrada ya tiene texto. ⌃Y inicia el dictado y no escribe nada: OpenBoard añade por ti la línea del atajo a ~/.claude/keybindings.json."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if board.preferences.voiceChord, case .conflict(let other) = keybinding.status {
                Text(tr("⌃Y ya está asignado a %@ en tus keybindings: la tecla de voz no hará nada hasta que liberes ese atajo o lo cambies aquí.", other))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(RGB(0xFF6A00)))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let chordNote {
                Text(chordNote).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }

    private var voiceChordBinding: Binding<Bool> {
        Binding(
            get: { board.preferences.voiceChord },
            set: { enabled in
                chordNote = nil
                if enabled {
                    let audit = KeybindingInstall.audit(document: KeybindingInstall.load())
                    if audit.status == .missing {
                        do {
                            try KeybindingInstall.install()
                            // Same caveat as hooks, same reason: keybindings load
                            // when a session starts, so the ones already open keep
                            // tapping into the void.
                            chordNote = tr("⌃Y asignado a voice:pushToTalk. Las sesiones nuevas de Claude Code lo toman; las ya abiertas conservan sus atajos anteriores hasta que las reinicies.")
                        } catch {
                            chordNote = error.localizedDescription
                            refresh()
                            return  // The pref stays off: a chord that reaches nothing
                                    // is a dead key wearing a setting's clothes.
                        }
                    }
                }
                board.updatePreferences { $0.voiceChord = enabled }
                commands.bindingsChanged()
                refresh()
            }
        )
    }

    /**
     Only ever shown when something is wrong.

     Writing to `~/.claude/settings.json` changes behaviour for every Claude Code
     session on the machine, so it never happens on launch — only on this press, and the
     current file is backed up beside itself first.
     */
    @ViewBuilder
    private var hooksProblem: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(Color(RGB(0xFF6A00))).frame(width: 9, height: 9)
                Text(hooks.settingsExists
                    ? (hooks.problems.count == 1
                        ? tr("%ld de %ld hooks necesita atención.", hooks.problems.count, HookInstall.events.count)
                        : tr("%ld de %ld hooks necesitan atención.", hooks.problems.count, HookInstall.events.count))
                    : tr("No se encontró ~/.claude/settings.json."))
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                Button(tr("Reparar hooks")) {
                    do {
                        try HookInstall.install(command: HookInstall.hookCommandPath())
                        // Naming the next step is the whole message. Hooks are read by
                        // Claude Code when a session *starts*, so every session already
                        // open keeps running without them — the board stays dark, the
                        // pane says it succeeded, and the obvious conclusion is that it
                        // did not. Sessions already running do get a key (the app walks
                        // the process table), which makes it worse: they appear on the
                        // board and then never change.
                        hookNote = tr("Instalados. Abre una sesión nueva de Claude Code para verlo: los hooks se cargan al iniciar la sesión, así que las que ya están en marcha no se iluminarán. El archivo de ajustes anterior queda respaldado a su lado.")
                    } catch {
                        hookNote = error.localizedDescription
                    }
                    refresh()
                }
                .controlSize(.small)
            }

            ForEach(hooks.problems, id: \.self) { event in
                HStack(spacing: 6) {
                    Text(event).font(.system(size: 11.5).monospaced())
                    Text(describe(hooks.statuses[event]))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if let hookNote {
                Text(hookNote).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }

    private func describe(_ status: HookInstall.EventStatus?) -> String {
        switch status {
        case .missing, nil: tr("sin instalar")
        case .stalePath(let path): tr("apunta a un binario que ya no existe: %@", path)
        case .otherPath(let path): tr("apunta a otra instalación: %@", path)
        case .ok: tr("ok")
        }
    }

    /// What each automation target is actually for. All three said "jumping to a chat",
    /// which is true of one of them: System Events types every snippet and sends every
    /// ⏎, and QuickTime only ever plays the countdown.
    private func why(automating target: String) -> String {
        switch target {
        case "System Events": tr("escribir textos, ⏎ y ⎋, flechas")
        case "Terminal": tr("saltar a un chat")
        case "iTerm2": tr("saltar a un chat")
        // Names the feature, because that is the whole answer to "do I need this?".
        case "QuickTime Player": tr("solo modo diversión: macOS lo pide la primera vez que lo reproduces")
        default: tr("controlar %@", target)
        }
    }

    private func permissionRow(
        _ name: String, _ why: String,
        status: PermissionProbe.Status, pane: String,
        subject: String? = nil,
        optional: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color(for: status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(permissionName(name)).font(.system(size: 12.5, weight: .medium))
                Text(why).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // An optional target that has not answered is not missing anything —
            // macOS asks the first time the feature runs. "not running" invited people
            // to go and fix a permission that was never a problem.
            Text(optional && !status.isGranted && status != .denied
                 ? tr("cuando haga falta")
                 : label(for: status))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(hint(for: status, name: subject ?? permissionName(name)) ?? "")
            Button(tr("Abrir")) {
                if let url = PermissionProbe.settingsURL(forPane: pane) {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private func color(for status: PermissionProbe.Status) -> Color {
        switch status {
        case .granted: Color(RGB(0x09B821))
        case .denied: Color(RGB(0xD41145))
        // Not the same as denied: nobody has been asked yet. Sending someone to a
        // settings pane where the app is not even listed is worse than saying so.
        case .unknown: Color(RGB(0xFF6A00))
        // Nothing is wrong and there is nothing to do, so it must not look like an
        // alert. This was orange, which read as "you are missing a permission" for a
        // grant the user had already given.
        case .unavailable: Color.secondary.opacity(0.5)
        }
    }

    private func label(for status: PermissionProbe.Status) -> String {
        switch status {
        case .granted: tr("concedido")
        case .denied: tr("denegado")
        case .unknown: tr("sin pedir")
        // Deliberately describes the *target*, not the permission: the permission is
        // very likely granted and simply cannot be read while the app is asleep.
        case .unavailable: tr("inactivo")
        }
    }

    /// Only where it is not obvious. A row that explains itself does not need a tooltip.
    private func hint(for status: PermissionProbe.Status, name: String) -> String? {
        guard status == .unavailable else { return nil }
        return tr("%@ no está en ejecución, así que no se puede preguntar a macOS si OpenBoard puede controlarlo. Se inicia cuando hace falta: usa una tecla que lo necesite y esto se resuelve solo.", name)
    }

    /**
     The interface language, in the same boxed-row shape as the voice key.

     Each name is in its own language, as macOS does, so the control stays usable by
     someone who cannot read the one currently showing.
     */
    private var languageSection: some View {
        HStack(spacing: 10) {
            Text(tr("Idioma")).font(.system(size: 12.5))
            Spacer(minLength: 0)
            Picker(tr("Idioma"), selection: languageBinding) {
                ForEach(UILanguage.allCases, id: \.self) { language in
                    Text(language.name).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }

    /// `@AppStorage` redraws SwiftUI; `storedLanguage` is the one persistence point and
    /// the one that tells the menu bar.
    private var languageBinding: Binding<UILanguage> {
        Binding(
            // The language in effect: the override when one is forced (snapshots),
            // otherwise the stored choice this view observes.
            get: { UIStrings.override ?? UILanguage(rawValue: uiLanguage) ?? UIStrings.defaultLanguage },
            set: { language in
                uiLanguage = language.rawValue
                UIStrings.storedLanguage = language
            }
        )
    }
}

/// Display name for a permission. `PermissionProbe` names them in English because tests
/// and logic key on those strings; only what is shown is translated.
func permissionName(_ en: String) -> String {
    let automationPrefix = "Automation → "
    if en.hasPrefix(automationPrefix) {
        return tr("Automatización → %@", String(en.dropFirst(automationPrefix.count)))
    }
    switch en {
    case "Input Monitoring": return tr("Monitorización de entrada")
    case "Accessibility": return tr("Accesibilidad")
    case "Automation": return tr("Automatización")
    case "Screen Recording": return tr("Grabación de pantalla")
    default: return en
    }
}

struct ShowCard: View {
    let show: Show
    let running: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if show.auto {
                        Circle().fill(tint).frame(width: 8, height: 8)
                    }
                    Text(show.label).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    if running {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(show.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(format: "%.1f s", show.duration.seconds))
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            // Interactive, because it is a button: the material has to react to a press
            // rather than sit there as a texture.
            .glassControl(cornerRadius: 10)
        }
        .buttonStyle(.plain)
    }

    /// Auto-fire shows borrow the color of the state they announce.
    private var tint: Color {
        switch show.name {
        case "completion": Color(RGB(0x09B821))
        case "question": Color(RGB(0xFF6A00))
        case "error": Color(RGB(0xD41145))
        default: .secondary
        }
    }
}

/**
 A section heading and one line under it.

 Every section carries one. The line is still held to a standard: it says something the
 title does not, in one sentence, and never restates it in longer words. "Permissions —
 each takes effect after OpenBoard restarts" earns its place; "Permissions — the
 permissions OpenBoard needs" would not.

 The subtitle stays optional in the type rather than required, so a section that
 genuinely has nothing to add is not forced to invent something.
 */
struct PaneHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, _ subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
