import Foundation
import OpenBoardKit

/*
 The interface speaks Spanish or English (Spanish by default). Every visible string goes
 through `tr(_:)`, keyed by its Spanish text, and `UIStrings.table` gives the English.

 */
func runUIStringsTests() {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // OpenBoardTests
        .deletingLastPathComponent()      // Sources

    func read(_ directory: String) -> [(name: String, text: String)] {
        let dir = sources.appendingPathComponent(directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".swift") }.sorted().compactMap { name in
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)).map { (name, $0) }
        }
    }
    /// Lines that are code, not comments.
    func codeLines(_ text: String) -> [(number: Int, line: String)] {
        var out: [(Int, String)] = []
        var inBlock = false
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inBlock { if line.contains("*/") { inBlock = false }; continue }
            if line.hasPrefix("/*") || line.hasPrefix("/**") { if !line.contains("*/") { inBlock = true }; continue }
            if line.hasPrefix("//") || line.hasPrefix("*") { continue }
            out.append((index + 1, raw))
        }
        return out
    }
    func specifiers(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(@|d|ld|\\.\\df|%)")
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
    }

    test("ui strings: every entry has Spanish and English, with the same placeholders") {
        expect(UIStrings.table.count > 100, "the table has \(UIStrings.table.count) entries — too few to be the UI")
        for (es, en) in UIStrings.table {
            expect(!es.trimmingCharacters(in: .whitespaces).isEmpty, "an empty Spanish key")
            expect(!en.trimmingCharacters(in: .whitespaces).isEmpty, "no English for «\(es)»")
            expectEqual(specifiers(es).sorted(), specifiers(en).sorted(), "placeholders differ for «\(es)»")
        }
    }

    test("ui strings: every tr(…) in the app and the kit is in the table") {
        let call = try! NSRegularExpression(pattern: #"\btr\("((?:[^"\\]|\\.)*)""#)
        var missing: [String] = []
        var calls = 0
        for directory in ["OpenBoard", "OpenBoardKit"] {
            for file in read(directory) {
                for (number, line) in codeLines(file.text) {
                    for match in call.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                        calls += 1
                        let key = String(line[Range(match.range(at: 1), in: line)!])
                            .replacingOccurrences(of: #"\""#, with: "\"")
                            .replacingOccurrences(of: #"\\"#, with: "\\")
                        if UIStrings.table[key] == nil { missing.append("\(file.name):\(number) «\(key)»") }
                    }
                }
            }
        }
        expect(calls > 100, "found only \(calls) tr(…) calls — the scan is matching nothing")
        expect(missing.isEmpty, "not in UIStrings.table:\n  " + missing.joined(separator: "\n  "))
    }

    test("ui strings: no view shows a literal that bypasses the table") {
        // A visible string handed straight to a view: Text("…"), Button("…"), .help("…"),
        // and the pane's own helpers. Glyph-only and proper-name literals are allowed.
        let visible = try! NSRegularExpression(pattern:
            #"(?:\b(?:Text|Button|Label|Toggle|Section|TextField|Menu|PaneHeader|InspectorCaption|SettingRow|StatusRow|chip|confirmationDialog|requiresSetup|help|inert)\(|\b(?:noneLabel|title|detail|message|placeholder):\s*)"((?:[^"\\]|\\.)*)""#)
        let allowed: Set<String> = ["Superset", "OpenBoard", "Codex Micro", "DIAL", "STICK", "HARNESS", "hex", "claude", "codex", "Tab"]
        var leaks: [String] = []
        // Not views: the harness writes file names, and Actions' `detail:` results go to
        // the log (never on screen).
        for file in read("OpenBoard") where !["SettingsSnapshots.swift", "Actions.swift"].contains(file.name) {
            for (number, line) in codeLines(file.text) where !line.contains("Log.write") {
                for match in visible.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let literal = String(line[Range(match.range(at: 1), in: line)!])
                    let letters = literal.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
                    guard letters >= 2, !allowed.contains(literal) else { continue }
                    // Interpolation only (\(x)) is data, not wording.
                    if literal.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "", options: .regularExpression)
                        .unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count < 2 { continue }
                    leaks.append("\(file.name):\(number) «\(literal)»")
                }
            }
        }
        expect(leaks.isEmpty, "\(leaks.count) visible literals bypass UIStrings:\n  " + leaks.prefix(40).joined(separator: "\n  "))
    }

    test("ui strings: the check would notice a literal") {
        // The same pattern over a line that bypasses the table.
        let line = #"                Text("Map keys")"#
        expect(line.contains(#"Text(""#), "fixture broken")
        expect(!UIStrings.table.keys.contains("Map keys"), "an English key would hide the leak")
    }

    test("ui strings: switching the language switches action and state labels") {
        let saved = UIStrings.override
        defer { UIStrings.override = saved }

        UIStrings.override = .en
        expectEqual(KeyAction.approve.short, "approve")
        expectEqual(KeyAction.reject.long, "reject pending prompt (⎋) / cancel fun mode")
        expectEqual(SessionState.done.label, "done")
        expectEqual(LEDEffect.shallowBreath.displayName, "shallow breath")
        expectEqual(tr("Asignar teclas"), "Map keys")
        expectEqual(tr("Conectado a %@", "Pad"), "Connected to Pad")

        UIStrings.override = .es
        expectEqual(KeyAction.approve.short, "aprobar")
        expectEqual(SessionState.done.label, "terminada")
        expectEqual(LEDEffect.shallowBreath.displayName, "respiración suave")
        expectEqual(tr("Asignar teclas"), "Asignar teclas")
        expectEqual(tr("Conectado a %@", "Pad"), "Conectado a Pad")
    }

    test("ui strings: the harness catalog's shown texts are all in the table") {
        // Built once as static data, so it holds Spanish keys and HarnessPane translates
        // them where shown; the scan of tr("…") calls cannot see these.
        var missing: [String] = []
        for harness in OpenBoardKit.Harness.all {
            // A dash or a bare identifier in backticks is not wording.
            func isWording(_ text: String) -> Bool {
                let prose = text.replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)
                return prose.filter(\.isLetter).count >= 2
            }
            for text in harness.limitations where UIStrings.table[text] == nil && isWording(text) { missing.append(text) }
            for surface in harness.surfaces {
                for text in [surface.detection, surface.jump] + [surface.unsupported].compactMap({ $0 })
                where UIStrings.table[text] == nil && isWording(text) { missing.append(text) }
            }
        }
        expect(missing.isEmpty, "harness texts not in the table:\n  " + missing.joined(separator: "\n  "))
    }

    test("ui strings: Spanish is written with its accents") {
        // Words that exist only with an accent, so a bare form is always a typo — "tecla
        // de accion" shipped once. Ambiguous pairs (esta/está, mas/más, si/sí) are left
        // out: both spellings are words.
        let bare: Set<String> = [
            "accion", "sesion", "configuracion", "conexion", "posicion", "version",
            "funcion", "opcion", "atencion", "confirmacion", "automatizacion", "monitorizacion",
            "informacion", "aplicacion", "direccion", "tambien", "aqui", "despues", "todavia",
            "ultimo", "ultima", "numero", "linea", "lineas", "pagina", "rapido", "dialogo",
            "calibracion", "grabacion", "pestana", "anadir", "senal", "extension", "raton",
            "boton", "menu", "podras", "estan", "seran", "segun", "facil", "dificil", "util",
            "codigo", "bateria", "diversion", "navegacion", "transicion", "animacion", "sincronizacion",
        ]
        func typos(_ text: String) -> [String] {
            text.lowercased().split { !$0.isLetter }.map(String.init).filter { bare.contains($0) }
        }
        expectEqual(typos("tecla de accion"), ["accion"], "the check notices a missing accent")
        expect(typos("tecla de acción · menú").isEmpty)
        var found: [String] = []
        for spanish in UIStrings.table.keys {
            let words = typos(spanish)
            if !words.isEmpty { found.append("«\(spanish)» (\(words.joined(separator: ", ")))") }
        }
        expect(found.isEmpty, "Spanish without its accent:\n  " + found.sorted().joined(separator: "\n  "))
    }

    test("ui strings: no translated text is set in the monospaced font") {
        // SF Mono's acute is a short stub: at 10pt in a secondary grey it vanished and
        // the chip read "tecla de accion". Monospace is for data — paths, numbers, ids —
        // never for wording, which goes through tr(). A Text in the monospaced font may
        // not show a tr(…) directly, nor a String property or function of the same file
        // whose body calls tr(…).
        let textArg = try! NSRegularExpression(pattern: #"Text\((.*)$"#)
        let stringMember = try! NSRegularExpression(pattern: #"(?:var|func)\s+(\w+)[^{]*?(?::|->)\s*String\s*\{"#)
        var offenders: [String] = []
        var sites = 0
        for file in read("OpenBoard") where file.name != "SettingsSnapshots.swift" {
            let lines = file.text.components(separatedBy: "\n")
            // String members whose body resolves wording through tr(…).
            var translated: Set<String> = []
            for (index, line) in lines.enumerated() {
                guard let match = stringMember.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let range = Range(match.range(at: 1), in: line) else { continue }
                var depth = 0, body = ""
                for next in lines[index...] {
                    body += next + "\n"
                    depth += next.filter { $0 == "{" }.count - next.filter { $0 == "}" }.count
                    if depth <= 0 && next.contains("}") { break }
                }
                if body.contains("tr(") { translated.insert(String(line[range])) }
            }
            for (index, line) in lines.enumerated() where line.contains(".monospaced()") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                sites += 1
                // The Text this modifier applies to: the nearest one at or above it.
                for back in stride(from: index, through: max(index - 4, 0), by: -1) {
                    let candidate = lines[back]
                    guard let match = textArg.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
                          let range = Range(match.range(at: 1), in: candidate) else { continue }
                    // A Text can span lines before its modifiers: take them all.
                    let argument = ([String(candidate[range])] + (back < index ? Array(lines[(back + 1)...index]) : [])).joined(separator: " ")
                    let identifiers = Set(argument.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
                    if argument.contains("tr(") || !identifiers.isDisjoint(with: translated) {
                        offenders.append("\(file.name):\(back + 1) \(candidate.trimmingCharacters(in: .whitespaces))")
                    }
                    break
                }
            }
        }
        expect(sites > 10, "found only \(sites) monospaced sites — the scan is matching nothing")
        expect(offenders.isEmpty, "translated wording in the monospaced font:\n  " + offenders.joined(separator: "\n  "))
    }

    test("ui strings: Spanish is the default") {
        expectEqual(UIStrings.defaultLanguage, .es)
        expectEqual(UILanguage.allCases.map(\.rawValue), ["es", "en"])
    }
}
