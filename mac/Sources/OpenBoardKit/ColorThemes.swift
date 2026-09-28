import Foundation

/**
 Predefined color themes for the pad: a skin over its vocabulary, never a new one.

 A theme repaints the session states, the "unconfirmed" look, the workspace palette and
 the confirmation light. It never changes what a color *means*. Whatever the taste, on
 every theme:

 - **awaiting / stalled** are a warm attention hue (orange-ish, 5–45°), and stalled is the
   same color at half the brightness — "still waiting, gone quiet";
 - **error** is red (330–10°), at least 20° away from awaiting, and still the only state
   that pulses with a full `breath`;
 - **done** is green, **working** is blue/cold;
 - **idle / viewing / unconfirmed** never borrow an attention hue, and idle stays clearly
   dimmer than working, so a board at rest does not read as a board at work;
 - the **workspace palette** keeps 20° of hue from every state of the *same* theme (the
   rule `WorkspaceColors.usablePalette` enforces at runtime) and, for the desaturated
   colors that have no hue, stays visibly distinct in RGB;
 - the **confirmation light** is never amber: amber already means "a session waits on
   you" (D3).

 Only the colors change. Effects, brightness and speed come from Classic, which is where
 the motion language lives — shallow breath for the calm states, a full breath for
 errors — so switching theme never makes the board *move* differently. `SupersetSettingsTests`
 checks every one of the rules above against every theme.

 Hardware colors: each hex below is what the LED is told to emit, not a screen color.
 The LED renders desaturated colors as tinted whites and dark ones as dim, which the
 palettes account for. **[Por verificar en el pad]**: each theme's look at 1 m.
 */
public struct ColorTheme: Equatable, Sendable, Identifiable {
    public let id: String
    /// Spanish, the key `tr` translates — like every visible string.
    public let name: String
    /// One line for the picker, also a `tr` key.
    public let summary: String
    /// The seven themed states. `ended` is never themed: it is off.
    public let states: [SessionState: Appearance]
    /// `states["unconfirmed"]`: a session restored at launch, not yet seen live.
    public let unconfirmed: Appearance
    /// `workspaceIdentity.palette`: seen only in passing, in the sweep and the wink.
    public let palette: [RGB]
    /// `confirm.color`: the "are you sure?" light.
    public let confirmColor: RGB

    public init(
        id: String,
        name: String,
        summary: String,
        states: [SessionState: Appearance],
        unconfirmed: Appearance,
        palette: [RGB],
        confirmColor: RGB
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.states = states
        self.unconfirmed = unconfirmed
        self.palette = palette
        self.confirmColor = confirmColor
    }

    public func appearance(for state: SessionState) -> Appearance {
        states[state] ?? state.defaultAppearance
    }

    /// One of the five that ship. Their `name` and `summary` are `tr` keys; a custom
    /// theme's name is the user's own text and is shown as typed.
    public var isBuiltIn: Bool { Self.all.contains { $0.id == id } }

    /// What the picker calls it, in the current language.
    public var displayName: String { isBuiltIn ? tr(name) : name }

    /// The states that carry a theme's color.
    public static let themedStates: [SessionState] = [
        .idle, .viewing, .working, .awaiting, .stalled, .done, .error,
    ]

    // MARK: - Applying

    /**
     `prefs` with this theme's colors, and nothing else changed.

     Pure: the state appearances, `states["unconfirmed"]`, the workspace palette and the
     confirmation color are replaced; pinned workspace colors, the confirmation's effect
     and window, `ended`, and every other setting are left exactly as they were.
     */
    public static func apply(_ theme: ColorTheme, to prefs: Preferences) -> Preferences {
        var next = prefs
        for state in themedStates {
            next.setAppearance(theme.appearance(for: state), for: state)
        }
        next.states[Preferences.unconfirmedKey] = theme.unconfirmed
        next.workspaceIdentity.palette = theme.palette
        next.confirm.color = theme.confirmColor
        return next
    }

    /// Every theme the picker offers: the built-in ones, then the user's.
    public static func available(in prefs: Preferences) -> [ColorTheme] {
        all + prefs.customThemes.map(\.theme)
    }

    /// The theme `prefs` is wearing, or `nil` once any of its colors was edited by hand.
    /// A built-in theme is named before a custom copy with the same colors.
    public static func current(in prefs: Preferences) -> ColorTheme? {
        available(in: prefs).first { theme in
            themedStates.allSatisfy { prefs.appearance(for: $0) == theme.appearance(for: $0) }
                && prefs.unconfirmedAppearance == theme.unconfirmed
                && prefs.workspaceIdentity.palette == theme.palette
                && prefs.confirm.color == theme.confirmColor
        }
    }

    // MARK: - The themes

    public static let all: [ColorTheme] = [classic, gamer, ai, pop, claude]

    /**
     Classic — the shipped defaults, exactly. Always a way back.

     The hardware legend: slate idle, blue working, orange awaiting, green done, crimson
     error; the workspace palette of the transition design (violet, turquoise, lime, cool
     white) and a white confirmation.
     */
    public static let classic = ColorTheme(
        id: "classic",
        name: "Clásico",
        summary: "Los colores de fábrica del pad.",
        states: Dictionary(uniqueKeysWithValues: themedStates.map { ($0, $0.defaultAppearance) }),
        unconfirmed: Preferences.unconfirmedDefault,
        palette: Preferences.WorkspaceIdentity.defaultPalette,
        confirmColor: Preferences.Confirm().color
    )

    /**
     Gamer — neon on black.

     Every signal at full saturation: neon orange for a prompt (22°), electric sky blue
     for work (202°), acid green for done (111°), hot red for a failure (345°, 37° from the
     orange). Idle is a deep indigo (231°) that nearly disappears, so the neon has
     something dark to stand on. The workspaces are the colors a gaming rig would use for
     its zones: magenta (306°), ultraviolet (267°), toxic lime (70°) and aqua (167°) —
     each at least 35° from any state.
     */
    public static let gamer = themed(
        id: "gamer",
        name: "Gamer",
        summary: "Neón sobre negro: saturado y con mucho contraste.",
        idle: RGB(0x141E5A),
        working: RGB(0x00A3FF),
        awaiting: RGB(0xFF5F00),
        done: RGB(0x39FF14),
        error: RGB(0xFF0040),
        palette: [RGB(0xFF00E6), RGB(0x8A2BFF), RGB(0xD4FF00), RGB(0x00FFC8)],
        confirm: RGB(0xFFFFFF)
    )

    /**
     AI — cool blues and violets, with the signals kept warm.

     The calm of the board is cold: an indigo idle (235°) and a clean cobalt for work
     (221°), mint for done (154°). Attention does not join the mood — a prompt is still
     amber-orange (29°) and a failure a rose red (345°), because a cool theme where the
     prompt is also cool would bury the one thing that must stand out. The workspaces
     live in the same family, spaced away from the states: lavender (262°), ice cyan
     (191°), orchid (296°) and a frost white with no hue at all.
     */
    public static let ai = themed(
        id: "ai",
        name: "IA",
        summary: "Azules y violetas fríos; los avisos siguen siendo cálidos.",
        idle: RGB(0x2A2F66),
        working: RGB(0x3D7BFF),
        awaiting: RGB(0xFF8A1F),
        done: RGB(0x26D98A),
        error: RGB(0xFF2E63),
        palette: [RGB(0xA06BFF), RGB(0x5FE3FF), RGB(0xE85CF2), RGB(0xE6ECFF)],
        confirm: RGB(0xFFFFFF)
    )

    /**
     Pop — candy colors.

     Bright, friendly and a little playful: tangerine for a prompt (29°), candy blue for
     work (217°), apple green for done (142°), cherry red for a failure (348°). Idle is a
     dusty blueberry (223°) so the candy has a soft ground. Workspaces are the rest of the
     sweet shop: bubblegum (313°), lime (78°), soda cyan (183°) and grape (266°). No
     yellow: on these LEDs a dim yellow drifts to orange and would read as a prompt.
     */
    public static let pop = themed(
        id: "pop",
        name: "Pop",
        summary: "Colores vivos de caramelo.",
        idle: RGB(0x3F4A66),
        working: RGB(0x3B82F6),
        awaiting: RGB(0xFF7A00),
        done: RGB(0x2BD96B),
        error: RGB(0xFF1F4B),
        palette: [RGB(0xFF4FD8), RGB(0xA8F000), RGB(0x00D5E0), RGB(0x9B4DFF)],
        confirm: RGB(0xFFFFFF)
    )

    /**
     Claude — Anthropic's palette.

     Terracotta `#D97757` is the brand's accent, and here it is what it should be: the
     color that asks for you — awaiting (15°), and stalled at half brightness. The brand
     blue `#6A9BCC` is work (210°). Done is a sage green, saturated just enough to read as
     green on an LED (103°); the brand's own olive is too grey to carry a hue there. A
     failure is a muted raspberry (343°, 32° from the terracotta) rather than a fire-truck
     red, to stay in the family. Idle is a warm charcoal, and the confirmation is the
     brand's ivory `#FAF9F5`.

     The workspaces are the quiet brand neutrals — cream, sand, slate and sage — which is
     exactly why the terracotta is free to mean "waiting": none of them has enough hue to
     compete with it, and each sits at least 60 RGB steps from the others and from every
     state.
     */
    public static let claude = themed(
        id: "claude",
        name: "Claude",
        summary: "El terracota, el marfil y los neutros de Anthropic.",
        idle: RGB(0x4A4945),
        working: RGB(0x6A9BCC),
        awaiting: RGB(0xD97757),
        done: RGB(0x6FA35B),
        error: RGB(0xB83A5E),
        palette: [RGB(0xF0E6D2), RGB(0xD2B48C), RGB(0x64708C), RGB(0x8CAF91)],
        confirm: RGB(0xFAF9F5)
    )

    // MARK: - Building one

    /// A theme from its six colors, on Classic's motion: effects, brightness and speed
    /// are Classic's, viewing and unconfirmed reuse the idle color, and stalled the
    /// awaiting one — the same relationships the defaults have.
    private static func themed(
        id: String,
        name: String,
        summary: String,
        idle: RGB,
        working: RGB,
        awaiting: RGB,
        done: RGB,
        error: RGB,
        palette: [RGB],
        confirm: RGB
    ) -> ColorTheme {
        let colors: [SessionState: RGB] = [
            .idle: idle, .viewing: idle, .working: working,
            .awaiting: awaiting, .stalled: awaiting, .done: done, .error: error,
        ]
        var states: [SessionState: Appearance] = [:]
        for state in themedStates {
            var look = state.defaultAppearance
            look.color = colors[state] ?? look.color
            states[state] = look
        }
        var unconfirmed = Preferences.unconfirmedDefault
        unconfirmed.color = idle
        return ColorTheme(
            id: id, name: name, summary: summary,
            states: states, unconfirmed: unconfirmed,
            palette: palette, confirmColor: confirm
        )
    }
}


// MARK: - Custom themes

/**
 A theme the user saved, duplicated or imported.

 The same content as a `ColorTheme` — the seven state looks, `unconfirmed`, the palette
 and the confirmation color — but mutable, with a stable `custom-<uuid>` id and a name
 the user typed. Applied, previewed and recognised exactly like a built-in one, through
 `theme`.
 */
public struct CustomTheme: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var states: [SessionState: Appearance]
    public var unconfirmed: Appearance
    public var palette: [RGB]
    public var confirmColor: RGB

    public init(
        id: String,
        name: String,
        states: [SessionState: Appearance],
        unconfirmed: Appearance,
        palette: [RGB],
        confirmColor: RGB
    ) {
        self.id = id
        self.name = name
        self.states = states
        self.unconfirmed = unconfirmed
        self.palette = palette
        self.confirmColor = confirmColor
    }

    /// A copy of any theme's colors under a new id and name.
    public init(from theme: ColorTheme, id: String, name: String) {
        self.init(
            id: id, name: name,
            states: Dictionary(uniqueKeysWithValues: ColorTheme.themedStates.map { ($0, theme.appearance(for: $0)) }),
            unconfirmed: theme.unconfirmed,
            palette: theme.palette,
            confirmColor: theme.confirmColor
        )
    }

    /// A copy of what `prefs` is wearing now, hand edits included.
    public init(current prefs: Preferences, id: String, name: String) {
        self.init(
            id: id, name: name,
            states: Dictionary(uniqueKeysWithValues: ColorTheme.themedStates.map { ($0, prefs.appearance(for: $0)) }),
            unconfirmed: prefs.unconfirmedAppearance,
            palette: prefs.workspaceIdentity.palette,
            confirmColor: prefs.confirm.color
        )
    }

    public static func newID() -> String { "custom-" + UUID().uuidString }

    /// As a theme the picker, `apply` and the preview understand.
    public var theme: ColorTheme {
        ColorTheme(
            id: id, name: name, summary: "",
            states: states, unconfirmed: unconfirmed,
            palette: palette, confirmColor: confirmColor
        )
    }
}

// MARK: - The file format

/**
 A theme as a JSON file: what "Export" writes and "Import" reads.

 Version 1 — kept in step with `temas-propios/formato.md`, which a theme-designer page
 reads:

 ```json
 {
   "openboardTheme": 1,
   "name": "Mi tema",
   "states": {
     "idle":        { "color": "#2E4A6B", "effect": "shallow-breath", "brightness": 0.55, "speed": 0.25 },
     "viewing":     { … }, "working": { … }, "awaiting": { … }, "stalled": { … },
     "done":        { … }, "error":   { … },
     "unconfirmed": { "color": "#2E4A6B", "effect": "solid", "brightness": 0.3, "speed": 0 }
   },
   "palette": ["#9B30FF", "#00C9A7", "#B4E600", "#D6E4FF"],
   "confirm": "#FFFFFF"
 }
 ```

 - `openboardTheme` is required and must be `1`; a different number is refused rather
   than guessed at.
 - All eight `states` keys are required. `color` is `#RRGGBB` (an integer is accepted
   too); `effect` is one of `solid`, `breath`, `shallow-breath`, `rainbow`, `off` — the
   ring-only `snake` and `gradient` render a single key dark; `brightness` and `speed`
   are 0…1, `speed` optional (0).
 - `palette` holds 1…12 colors, in order. `confirm` is a color only: the confirmation's
   effect, brightness and window stay the user's.
 - `name` is 1…40 characters. Unknown keys are ignored, so a designer can add its own.

 Inside `config.json` the same object, minus `openboardTheme` and plus a stable `"id"`,
 is one entry of `"customThemes"` (`entry` / `custom(fromEntry:)`).

 The readability rules (`ThemeRules`) are not part of the format: a theme that breaks
 them is still a valid file, and the UI warns before saving it.
 */
public enum ThemeFile {
    public static let version = 1
    public static let maxNameLength = 40
    public static let maxPaletteCount = 12
    /// The key order a file is written and checked in.
    public static let stateKeys: [String] = ColorTheme.themedStates.map(\.rawValue) + [Preferences.unconfirmedKey]
    public static let allowedEffects: [LEDEffect] = [.solid, .breath, .shallowBreath, .rainbow, .off]

    /// The export: pretty-printed, keys sorted, colors as hex.
    public static func encode(_ theme: ColorTheme) -> Data {
        var body = content(of: theme)
        body["openboardTheme"] = version
        body["name"] = theme.displayName
        return (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// An import, as a new custom theme with a fresh id. The name is the file's; making
    /// it unique among the user's themes is `SettingsEditing.addTheme`'s job.
    public static func decode(_ data: Data) throws -> CustomTheme {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let rawVersion = root["openboardTheme"] else {
            throw ThemeFileError.notATheme
        }
        guard let number = rawVersion as? NSNumber, number.intValue == version,
              number.doubleValue == Double(version) else {
            throw ThemeFileError.unsupportedVersion((rawVersion as? NSNumber)?.intValue ?? 0)
        }
        return try parse(root, id: CustomTheme.newID())
    }

    /// One `customThemes` entry of `config.json`.
    public static func entry(_ theme: CustomTheme) -> [String: Any] {
        var body = content(of: theme.theme)
        body["id"] = theme.id
        body["name"] = theme.name
        return body
    }

    /// Reads a `customThemes` entry back; `nil` for one that does not decode.
    public static func custom(fromEntry entry: [String: Any]) -> CustomTheme? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        return try? parse(entry, id: id)
    }

    // MARK: - Internals

    private static func content(of theme: ColorTheme) -> [String: Any] {
        var states: [String: Any] = [:]
        for key in stateKeys {
            let look = key == Preferences.unconfirmedKey
                ? theme.unconfirmed
                : theme.appearance(for: SessionState(rawValue: key) ?? .idle)
            states[key] = [
                "color": look.color.hex,
                "effect": look.effect.rawValue,
                "brightness": look.brightness,
                "speed": look.speed,
            ]
        }
        return [
            "states": states,
            "palette": theme.palette.map(\.hex),
            "confirm": theme.confirmColor.hex,
        ]
    }

    private static func parse(_ root: [String: Any], id: String) throws -> CustomTheme {
        let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { throw invalid(tr("falta %@", "name")) }
        guard name.count <= maxNameLength else {
            throw invalid(tr("%@ tiene más de %@ caracteres", "name", String(maxNameLength)))
        }

        guard let states = root["states"] as? [String: Any] else { throw invalid(tr("falta %@", "states")) }
        var looks: [String: Appearance] = [:]
        for key in stateKeys {
            let path = "states.\(key)"
            guard let fields = states[key] as? [String: Any] else { throw invalid(tr("falta %@", path)) }
            let color = try parseColor(fields["color"], path: path + ".color")
            guard let rawEffect = fields["effect"] else { throw invalid(tr("falta %@", path + ".effect")) }
            guard let text = rawEffect as? String, let effect = LEDEffect(rawValue: text),
                  allowedEffects.contains(effect) else {
                throw invalid(tr("%@ «%@» no es un efecto válido", path + ".effect", "\(rawEffect)"))
            }
            let brightness = try unit(fields["brightness"], path: path + ".brightness", required: true)
            let speed = try unit(fields["speed"], path: path + ".speed", required: false)
            looks[key] = Appearance(color: color, effect: effect, brightness: brightness, speed: speed)
        }

        guard let rawPalette = root["palette"] as? [Any] else { throw invalid(tr("falta %@", "palette")) }
        guard !rawPalette.isEmpty else { throw invalid(tr("%@ está vacía", "palette")) }
        guard rawPalette.count <= maxPaletteCount else {
            throw invalid(tr("%@ tiene más de %@ colores", "palette", String(maxPaletteCount)))
        }
        let palette = try rawPalette.enumerated().map { try parseColor($1, path: "palette[\($0)]") }
        let confirm = try parseColor(root["confirm"], path: "confirm")

        var stateLooks: [SessionState: Appearance] = [:]
        for state in ColorTheme.themedStates { stateLooks[state] = looks[state.rawValue] }
        return CustomTheme(
            id: id, name: name, states: stateLooks,
            unconfirmed: looks[Preferences.unconfirmedKey] ?? Preferences.unconfirmedDefault,
            palette: palette, confirmColor: confirm
        )
    }

    private static func parseColor(_ raw: Any?, path: String) throws -> RGB {
        guard let raw else { throw invalid(tr("falta %@", path)) }
        if let text = raw as? String, let rgb = RGB(hex: text) { return rgb }
        if let number = raw as? NSNumber, !isBoolean(number),
           number.doubleValue == number.doubleValue.rounded(),
           (0...0xFF_FFFF).contains(number.intValue) {
            return RGB(UInt32(number.intValue))
        }
        throw invalid(tr("%@ «%@» no es un color", path, "\(raw)"))
    }

    private static func unit(_ raw: Any?, path: String, required: Bool) throws -> Double {
        guard let raw else {
            if required { throw invalid(tr("falta %@", path)) }
            return 0
        }
        guard let number = raw as? NSNumber, !isBoolean(number), (0...1).contains(number.doubleValue) else {
            throw invalid(tr("%@ debe estar entre 0 y 1", path))
        }
        return number.doubleValue
    }

    private static func invalid(_ detail: String) -> ThemeFileError { .invalid(detail) }

    /// `true`/`false` arrive as NSNumber too, and `raw is Bool` also matches 0 and 1 —
    /// only the CoreFoundation type tells a real boolean apart.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

/// Why a file is not a theme this version can read.
public enum ThemeFileError: Error, Equatable, Sendable {
    /// Not JSON, or JSON without `openboardTheme`.
    case notATheme
    case unsupportedVersion(Int)
    /// The field and what is wrong with it, already in the interface language.
    case invalid(String)

    public var message: String {
        switch self {
        case .notATheme:
            tr("No es un tema de OpenBoard: falta «openboardTheme».")
        case let .unsupportedVersion(found):
            tr("Tema de la versión %@, y este OpenBoard solo lee la versión 1.", String(found))
        case let .invalid(detail):
            tr("El tema no es válido: %@.", detail)
        }
    }
}

// MARK: - Readability rules

/**
 The rules every built-in theme passes, as a pure check a custom one can be held to.

 Warnings, not refusals: a custom theme that breaks them can still be saved once the
 user has seen each breach and confirmed, and its card carries ⚠︎. The rules and their
 reasons are the ones in `ColorTheme`'s documentation; `SupersetSettingsTests` checks
 the built-in themes against its own copy of them, so a change here that loosened a rule
 would not quietly loosen the test.
 */
public enum ThemeRules {
    public enum Rule: String, Equatable, Sendable, CaseIterable {
        /// (a) Each state keeps its meaning.
        case meaning
        /// (b) The workspace palette never imitates a state.
        case palette
        /// (c) Idle stays visibly quieter than working.
        case contrast
    }

    public struct Violation: Equatable, Sendable {
        public var rule: Rule
        /// One sentence in the interface language, with the numbers that matter.
        public var message: String
    }

    public static let attentionHues: ClosedRange<Double> = 5...45
    public static let greenHues: ClosedRange<Double> = 75...165
    public static let coldHues: ClosedRange<Double> = 180...275
    public static func isRed(_ hue: Double) -> Bool { hue >= 330 || hue <= 10 }
    public static let minimumAwaitingErrorGap: Double = 20
    public static let minimumStateDistance: Double = 40
    public static let minimumPaletteDistance: Double = 60
    public static let minimumWorkingToIdle: Double = 1.5

    public static func violations(_ theme: ColorTheme) -> [Violation] {
        meaning(theme) + palette(theme) + contrast(theme)
    }

    // MARK: (a)

    private static func meaning(_ theme: ColorTheme) -> [Violation] {
        var out: [Violation] = []
        func add(_ message: String) { out.append(Violation(rule: .meaning, message: message)) }
        func hue(_ state: SessionState) -> Double? { WorkspaceColors.hue(of: theme.appearance(for: state).color) }
        func degrees(_ value: Double) -> String { String(Int(value.rounded()) % 360) }

        func check(
            _ state: SessionState,
            fits: (Double) -> Bool,
            _ describe: (String, String) -> String
        ) -> Double? {
            guard let h = hue(state) else {
                add(tr("«%@» es demasiado gris para leerse como un color.", state.label))
                return nil
            }
            if !fits(h) { add(describe(state.label, degrees(h))) }
            return h
        }
        let warm = { (label: String, deg: String) in tr("«%@» debe ser cálido (5–45°); este está en %@°.", label, deg) }
        let awaiting = check(.awaiting, fits: { attentionHues.contains($0) }, warm)
        _ = check(.stalled, fits: { attentionHues.contains($0) }, warm)
        let error = check(.error, fits: { isRed($0) }) { tr("«%@» debe ser rojo (330–10°); este está en %@°.", $0, $1) }
        _ = check(.done, fits: { greenHues.contains($0) }) { tr("«%@» debe ser verde (75–165°); este está en %@°.", $0, $1) }
        _ = check(.working, fits: { coldHues.contains($0) }) { tr("«%@» debe ser azul o frío (180–275°); este está en %@°.", $0, $1) }

        if let awaiting, let error, gap(awaiting, error) < minimumAwaitingErrorGap {
            add(tr("«%@» y «%@» están a solo %@° y se confunden.",
                   SessionState.awaiting.label, SessionState.error.label, degrees(gap(awaiting, error))))
        }

        let quiet: [(String, RGB)] = [
            (SessionState.idle.label, theme.appearance(for: .idle).color),
            (SessionState.viewing.label, theme.appearance(for: .viewing).color),
            (tr("sin confirmar"), theme.unconfirmed.color),
            (tr("la confirmación"), theme.confirmColor),
        ]
        for (label, color) in quiet {
            if let h = WorkspaceColors.hue(of: color), attentionHues.contains(h) || isRed(h) {
                add(tr("«%@» usa un tono de atención (%@°) y parecería un aviso.", label, degrees(h)))
            }
        }
        return out
    }

    // MARK: (b)

    private static func palette(_ theme: ColorTheme) -> [Violation] {
        var out: [Violation] = []
        func add(_ message: String) { out.append(Violation(rule: .palette, message: message)) }
        let named: [(String, RGB)] = ColorTheme.themedStates.map { ($0.label, theme.appearance(for: $0).color) }
            + [(tr("sin confirmar"), theme.unconfirmed.color)]

        for color in theme.palette {
            var reported = false
            for (label, stateColor) in named {
                if let a = WorkspaceColors.hue(of: color), let b = WorkspaceColors.hue(of: stateColor),
                   gap(a, b) < WorkspaceColors.minimumHueDistance {
                    add(tr("El color de espacio %@ está a %@° de «%@»: el pad lo saltará.",
                           color.hex, String(Int(gap(a, b).rounded())), label))
                    reported = true
                    break
                }
            }
            guard !reported else { continue }
            for (label, stateColor) in named where distance(color, stateColor) < minimumStateDistance {
                add(tr("El color de espacio %@ se parece demasiado a «%@».", color.hex, label))
                break
            }
        }
        for (i, a) in theme.palette.enumerated() {
            for b in theme.palette[(i + 1)...] where distance(a, b) < minimumPaletteDistance {
                add(tr("Los colores de espacio %@ y %@ se distinguen mal.", a.hex, b.hex))
            }
        }
        return out
    }

    // MARK: (c)

    private static func contrast(_ theme: ColorTheme) -> [Violation] {
        var out: [Violation] = []
        let idle = emitted(theme.appearance(for: .idle))
        let working = emitted(theme.appearance(for: .working))
        let viewing = emitted(theme.appearance(for: .viewing))
        if working < idle * minimumWorkingToIdle {
            out.append(Violation(rule: .contrast, message: tr(
                "«%@» debe brillar claramente más que «%@» (al menos 1,5 veces).",
                SessionState.working.label, SessionState.idle.label
            )))
        }
        if viewing <= idle {
            out.append(Violation(rule: .contrast, message: tr(
                "«%@» debe brillar más que «%@».", SessionState.viewing.label, SessionState.idle.label
            )))
        }
        return out
    }

    // MARK: - Measures

    static func gap(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 360 - d)
    }

    /// Euclidean distance in 8-bit RGB: below ~40 two colors light a key the same.
    public static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = (a.red - b.red) * 255, dg = (a.green - b.green) * 255, db = (a.blue - b.blue) * 255
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// What a key emits: linear-light luminance scaled by the brightness.
    public static func emitted(_ look: Appearance) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * linear(look.color.red) + 0.7152 * linear(look.color.green) + 0.0722 * linear(look.color.blue)
        return l * look.brightness
    }
}

// MARK: - Choosing a theme

/**
 What happens when a theme card is chosen: the pad plays the theme first, filling every
 key with it, and the colors are applied when that ends — so the board comes back
 already wearing them.

 Pure bookkeeping; the playing is `BoardCommands.previewThemeThen`. Each choice takes a
 ticket, and only the latest ticket's end applies: choosing another card while one plays
 means the first never lands. Without a pad there is nothing to play, and the theme
 applies at once (which also supersedes any preview still running).
 */
public struct ThemeSwitch: Equatable, Sendable {
    public enum Start: Equatable, Sendable {
        case applyNow
        case preview(ticket: Int)
    }

    /// The theme on its way — playing on the pad, not applied yet.
    public private(set) var pending: String?
    private var ticket = 0

    public init() {}

    public mutating func select(_ themeID: String, padReady: Bool) -> Start {
        ticket += 1
        guard padReady else {
            pending = nil
            return .applyNow
        }
        pending = themeID
        return .preview(ticket: ticket)
    }

    /// The preview for `ticket` ended. The theme to apply, or `nil` when a later choice
    /// superseded it (or it was already applied).
    public mutating func previewEnded(ticket ended: Int) -> String? {
        guard ended == ticket, let id = pending else { return nil }
        pending = nil
        return id
    }
}
