import AppKit
import OpenBoardKit
import SwiftUI

/**
 Guided setup — the four things that have to be true before anything lights.

 A checklist rather than a wizard, and that is forced by the platform: granting Input
 Monitoring only takes effect after OpenBoard restarts, so a linear flow would be killed
 by its own first step. This recomputes from the world every time it appears, which
 means quitting halfway and coming back lands where you left off.

 The pad itself is not in the list. Pairing and Layer 1 are things done on the hardware,
 neither is detectable from here, and an unticked box for something that is probably
 fine is worse than a sentence. They are stated at the bottom instead.
 */
struct SetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.boardCommands) private var commands
    @EnvironmentObject private var setup: SetupState
    @EnvironmentObject private var board: BoardModel

    @State private var permissions = PermissionProbe.inspect()
    @State private var loginStatus = LoginItem.status
    @State private var note: String?
    @State private var working = false
    @State private var calibrating = false
    /// A refusal macOS has on record. Distinct from "not asked": once someone has said
    /// no to an Apple Events prompt, the system never asks again — every further
    /// request returns denied instantly. Asking a second time is guaranteed to fail, so
    /// the button has to stop offering and point at the only thing that can undo it.
    @State private var automationRefused = false
    /// Read so a language change rebuilds the whole sheet: every string is resolved
    /// when the body runs, and `.id` below forces that for the subviews too.
    @AppStorage(UIStrings.defaultsKey) private var uiLanguage = UIStrings.defaultLanguage.rawValue

    private var progress: SetupProgress { setup.progress }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 0) {
                ForEach(SetupProgress.Step.allCases, id: \.self) { step in
                    row(step)
                    if step != SetupProgress.Step.allCases.last {
                        Divider().opacity(0.35)
                    }
                }
            }
            .padding(.horizontal, 20)

            Divider()
            footer
        }
        .frame(width: 520)
        .id(uiLanguage)
        // Re-read on every appearance: these are granted outside the app, and a stale
        // list is what sends someone back to System Settings to fix something they
        // already fixed.
        .onAppear(perform: refresh)
        .sheet(isPresented: $calibrating, onDismiss: refresh) { CalibrationSheet() }
        /*
         The one moment worth marking.

         Everything until now has been obligations — permissions the app needs, a file
         it has to edit, an order it has to confirm. None of it was a choice. What comes
         next is the first part that is: what each key does and what it looks like. So
         the finish is also a handoff, and it names the next thing rather than leaving
         someone in a window whose work is done.

         Fires once ever, tracked by a marker in the state directory. A congratulation
         that reappears is not a congratulation.
        */
        .alert(tr("OpenBoard está configurado"), isPresented: $setup.justCompleted) {
            Button(tr("Asignar tus teclas")) {
                setup.markCompletionSeen()
                dismiss()
                commands.openSettings()
            }
            Button(tr("Más tarde"), role: .cancel) {
                setup.markCompletionSeen()
                dismiss()
            }
        } message: {
            Text(tr("El pad está en vivo y tus sesiones le informarán. Siguiente: elige qué hace cada tecla y cómo se ve; esa parte es toda tuya."))
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(progress.isReady ? tr("OpenBoard está listo") : tr("Configura OpenBoard"))
                .font(.system(size: 16, weight: .semibold))
            Text(progress.isReady
                 ? tr("Todo lo que necesita está concedido. Abre una sesión nueva de Claude Code y las teclas se iluminarán.")
                 : tr("%ld de %ld hechos. Cada uno lleva unos segundos, y puedes parar y volver luego.",
                      progress.requiredDone, progress.requiredTotal))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    // MARK: rows

    private func row(_ step: SetupProgress.Step) -> some View {
        let done = progress.isDone(step)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(done ? Color(RGB(0x09B821)) : Color.secondary.opacity(0.5))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(step)).font(.system(size: 13, weight: .medium))
                    if !step.isRequired {
                        Text(tr("opcional"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(detail(step))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Said on the row rather than in a dialog afterwards, because it is the
                // reason a grant looks like it did nothing.
                if step.needsRestart && !done {
                    Text(tr("Se aplica al reiniciar OpenBoard."))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(RGB(0xFF6A00)))
                }
            }

            Spacer(minLength: 8)
            action(step, done: done)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func action(_ step: SetupProgress.Step, done: Bool) -> some View {
        switch step {
        case .inputMonitoring:
            Button(tr("Abrir")) { openPane("Privacy_ListenEvent") }.controlSize(.small)
        case .accessibility:
            Button(tr("Abrir")) { openPane("Privacy_Accessibility") }.controlSize(.small)
        case .automation:
            // Normally the only step the app can grant without sending anyone anywhere.
            // A recorded refusal takes that away: macOS will not re-prompt, so the
            // button changes to the one action that can still work.
            if automationRefused && !done {
                Button(tr("Abrir")) { openPane("Privacy_Automation") }.controlSize(.small)
            } else {
                Button(working ? tr("Preguntando") : tr("Conceder")) { grantAutomation() }
                    .controlSize(.small)
                    .disabled(working || done)
            }
        case .calibration:
            // Needs the pad open, because the check paints six colours on it. Disabled
            // rather than hidden: it is a real step, and hiding it would make the count
            // shrink and grow as the pad connects.
            Button(done ? tr("Volver a comprobar") : tr("Comprobar")) { calibrating = true }
                .controlSize(.small)
                .disabled(!board.device.isUsable)
        case .hooks:
            Button(done ? tr("Reinstalar") : tr("Instalar")) { wireHooks() }
                .controlSize(.small)
                .disabled(working)
        case .openAtLogin:
            Toggle("", isOn: Binding(
                get: { loginStatus.isOn },
                set: { setLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(!LoginItem.isInstalledProperly)
        }
    }

    private func title(_ step: SetupProgress.Step) -> String {
        switch step {
        case .inputMonitoring: permissionName("Input Monitoring")
        case .accessibility: permissionName("Accessibility")
        case .automation: permissionName("Automation")
        case .calibration: tr("Orden de teclas")
        case .hooks: tr("Hooks de Claude Code")
        case .openAtLogin: tr("Abrir al iniciar sesión")
        }
    }

    private func detail(_ step: SetupProgress.Step) -> String {
        switch step {
        case .inputMonitoring:
            tr("Leer el pad. Sin él no se ilumina nada y no se detecta ninguna pulsación.")
        case .accessibility:
            tr("Escribir textos, enviar ⏎ y ⎋ y desplazarse con el dial.")
        case .automation:
            tr("Controlar System Events, que es lo que usan las teclas de acción. OpenBoard se lo pide directamente a macOS, sin pasar por Ajustes del Sistema.")
        case .calibration:
            board.device.isUsable
                ? tr("Confirma qué tecla física es la posición 1. El tablero asume el orden que reportan todos los pads, así que esto lleva diez segundos; pero los colores y las asignaciones van por posición, y un orden sin comprobar los pone en las teclas equivocadas.")
                : tr("Conecta antes el pad: la comprobación pinta seis colores en él.")
        case .hooks:
            tr("Añade OpenBoard a ~/.claude/settings.json para que las sesiones informen de lo que hacen. Se conservan los demás ajustes y antes se respalda el archivo.")
        case .openAtLogin:
            tr("Un tablero que tienes que acordarte de abrir no es un tablero ambiental.")
        }
    }

    // MARK: footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Two things this cannot check, and both are on the hardware. Stated rather
            // than shown as boxes that would sit unticked forever.
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("En el propio pad"))
                    .font(.system(size: 11.5, weight: .medium))
                Text(tr("Empareja el Codex Micro con este Mac por Bluetooth o USB y mantenlo en la capa 1: el estado por tecla solo se muestra ahí."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(tr("Comprobar de nuevo"), action: refresh)
                    .controlSize(.small)
                if !progress.isReady, !setup.isSkipped {
                    // Not a step and not a finish — an exit. The checklist survives
                    // it untouched; only the walls come down.
                    Button(tr("Omitir por ahora"), action: skipAndClose)
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                if !progress.isReady {
                    // Offered here because two of the four need it, and hunting for the
                    // menu bar item to quit and reopen is a poor reward for granting a
                    // permission correctly.
                    Button(tr("Reiniciar OpenBoard"), action: restart)
                        .controlSize(.small)
                }
                Button(progress.isReady ? tr("Listo") : tr("Cerrar")) { dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: actions

    private func refresh() {
        setup.refresh()
        permissions = PermissionProbe.inspect()
        loginStatus = LoginItem.status
    }

    private func skipAndClose() {
        setup.skip()
        dismiss()
    }

    private func openPane(_ pane: String) {
        guard let url = PermissionProbe.settingsURL(forPane: pane) else { return }
        NSWorkspace.shared.open(url)
    }

    private func grantAutomation() {
        working = true
        note = nil
        Task {
            let results = await AutomationRequest.requestAll(current: permissions.automation)
            working = false
            refresh()

            let systemEvents = results.first { $0.name == "System Events" }?.status
            switch systemEvents {
            case .granted, .none:
                note = nil
            case .denied:
                // The specific case that had no message of its own. Saying "was not
                // granted" invited another click, and another click cannot work.
                automationRefused = true
                note = tr("macOS tiene registrada una negativa para System Events, así que no volverá a preguntar. Activa OpenBoard en Automatización, en Ajustes del Sistema, y luego vuelve y pulsa Comprobar de nuevo.")
            case .unavailable:
                note = tr("System Events no se inició, así que macOS no tenía nada que preguntar. Vuelve a intentarlo en un momento.")
            case .unknown:
                note = tr("No hubo respuesta. Pulsa Conceder otra vez y acepta en el diálogo que muestra macOS.")
            }
        }
    }

    private func wireHooks() {
        do {
            try HookInstall.install(command: HookInstall.hookCommandPath())
            note = tr("Hooks instalados. Abre una sesión nueva de Claude Code para verlo: se cargan al iniciar la sesión, así que las que ya están en marcha no se iluminarán.")
        } catch {
            note = error.localizedDescription
        }
        refresh()
    }

    private func setLogin(_ on: Bool) {
        switch LoginItem.set(on) {
        case let .success(status):
            loginStatus = status
            note = nil
        case let .failure(error):
            note = error.localizedDescription
            loginStatus = LoginItem.status
        }
    }

    /// Relaunch, because Input Monitoring and Accessibility are read at launch.
    ///
    /// A detached `open` after this process exits, rather than asking macOS to restart
    /// us: an app that terminates itself and expects something to notice is an app that
    /// does not come back.
    private func restart() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }
}
