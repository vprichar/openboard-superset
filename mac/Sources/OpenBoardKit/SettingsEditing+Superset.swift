import Foundation

/**
 The Superset and Workspaces panes' edits, as pure functions on `Preferences`.

 The same contract as `SettingsEditing`: a control calls one of these and then
 `commands.bindingsChanged`. Every numeric field is clamped here to the range
 `Preferences.merging` accepts from the file (or narrower, where the pane's slider is),
 so a value typed into a field can never be one the next launch would silently
 rewrite — the pane shows exactly what the pad runs on.

 The group-wide setters (`setSuperset`, `setTargeted`…) take a closure and clamp the
 whole group afterwards. That keeps one edit path per group rather than a function per
 field, while still guaranteeing no control can store an out-of-range value.
 */
extension SettingsEditing {
    // MARK: - Ranges, shared with the panes' sliders

    public static let supersetStartDebounceRange = 0...5000
    public static let supersetDedupeWindowRange = 0...10000
    public static let supersetCoalesceRange = 0...1000
    public static let confirmWindowRange = 1000...10000
    public static let targetedWindowRange = 500...10000
    public static let snapshotLinesRange = 1...200
    public static let maxSendBytesRange = 1...16384
    public static let handoffContextRange = 1...1_000_000
    public static let createCooldownRange = 0...60000
    /// Narrower than the file's 0…1000: past half a second a count-up stops reading as
    /// one gesture.
    public static let keyStaggerRange = 0...500
    public static let transitionDelayRange = 0...1000
    public static let debounceRange = 0...2000
    public static let rapidWindowRange = 0...10000
    public static let ringHoldRange = 0...5000
    public static let ringFadeStepsRange = 1...20
    public static let ringFadeStepMsRange = 10...500
    public static let minSweepIntervalRange = 0...60000
    public static let winkEveryRange = 500...60000
    public static let winkRange = 50...2000

    // MARK: - Superset connection

    public static func setHostClient(_ mode: Preferences.Superset.HostClient, in p: inout Preferences) {
        p.superset.hostClient = mode
    }

    /// Any field of `superset`, clamped afterwards. A blank org id is stored as `nil`,
    /// which means "the one org with a manifest" — never as an empty id that matches
    /// nothing.
    public static func setSuperset(_ change: (inout Preferences.Superset) -> Void, in p: inout Preferences) {
        var s = p.superset
        change(&s)
        s.orgID = s.orgID?.trimmingCharacters(in: .whitespaces)
        if s.orgID?.isEmpty == true { s.orgID = nil }
        let version = s.testedVersion.trimmingCharacters(in: .whitespaces)
        s.testedVersion = version.isEmpty ? p.superset.testedVersion : version
        s.startDebounceMs = clamp(s.startDebounceMs, supersetStartDebounceRange)
        s.dedupeWindowMs = clamp(s.dedupeWindowMs, supersetDedupeWindowRange)
        s.padWriteCoalesceMs = clamp(s.padWriteCoalesceMs, supersetCoalesceRange)
        p.superset = s
    }

    // MARK: - Remote sends

    /// Add, replace or (with `nil`) remove a named targeted snippet. A blank name is
    /// ignored rather than stored as a key nobody can see or select.
    public static func setTargetedSnippet(name: String, text: String?, in p: inout Preferences) {
        let key = name.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        p.targeted.snippets[key] = text
    }

    /// Rename a snippet, keeping its text. Refused onto a blank name or one already
    /// taken — a rename must never quietly delete another snippet.
    public static func renameTargetedSnippet(from old: String, to new: String, in p: inout Preferences) {
        let key = new.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key != old,
              p.targeted.snippets[key] == nil,
              let text = p.targeted.snippets[old] else { return }
        p.targeted.snippets[old] = nil
        p.targeted.snippets[key] = text
    }

    /**
     The snippets in the order the pane lists them.

     `targeted.snippets` is a dictionary on disk, so the only order that survives a
     save is one derived from the names. Sorting them the way Finder does means an
     add, a rename or a delete never moves any *other* snippet relative to the rest.
     */
    public static func targetedSnippetNames(_ p: Preferences) -> [String] {
        p.targeted.snippets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func setMaxSendBytes(_ bytes: Int, in p: inout Preferences) {
        p.targeted.maxSendBytes = clamp(bytes, maxSendBytesRange)
    }

    /// Any field of `targeted`, clamped afterwards. `requireStopForSend` is put back to
    /// `true` whatever the closure did: typing into a busy agent is a safety rule, and
    /// the pane shows it locked.
    public static func setTargeted(_ change: (inout Preferences.Targeted) -> Void, in p: inout Preferences) {
        var t = p.targeted
        change(&t)
        t.requireStopForSend = true
        t.windowMs = clamp(t.windowMs, targetedWindowRange)
        t.snapshotLines = clamp(t.snapshotLines, snapshotLinesRange)
        t.maxSendBytes = clamp(t.maxSendBytes, maxSendBytesRange)
        if t.defaultSnippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            t.defaultSnippet = p.targeted.defaultSnippet
        }
        p.targeted = t
    }

    // MARK: - Two-step confirmation

    /// Any of the confirmation light's fields; `nil` leaves one as it is.
    public static func setConfirm(
        color: RGB? = nil,
        windowMs: Int? = nil,
        effect: LEDEffect? = nil,
        brightness: Double? = nil,
        in p: inout Preferences
    ) {
        if let color { p.confirm.color = color }
        if let windowMs { p.confirm.windowMs = clamp(windowMs, confirmWindowRange) }
        if let effect { p.confirm.effect = effect }
        if let brightness { p.confirm.brightness = unit(brightness) }
    }

    // MARK: - Launch

    /// Any field of `launch`. A blank agent keeps the previous one: NEW with no agent
    /// would be a key that does nothing, with no way to tell why.
    public static func setLaunch(_ change: (inout Preferences.Launch) -> Void, in p: inout Preferences) {
        var l = p.launch
        change(&l)
        l.newAgent = l.newAgent.trimmingCharacters(in: .whitespaces)
        if l.newAgent.isEmpty { l.newAgent = p.launch.newAgent }
        l.handoffAgent = l.handoffAgent.trimmingCharacters(in: .whitespaces)
        if l.handoffAgent.isEmpty { l.handoffAgent = p.launch.handoffAgent }
        l.handoffContextChars = l.handoffContextChars.map { clamp($0, handoffContextRange) }
        l.createCooldownMs = clamp(l.createCooldownMs, createCooldownRange)
        p.launch = l
    }

    // MARK: - Workspaces

    /// Any field of the switch animation, each clamped to its range afterwards.
    public static func setTransition(
        _ change: (inout Preferences.WorkspaceTransition) -> Void,
        in p: inout Preferences
    ) {
        var t = p.workspaceTransition
        change(&t)
        t.debounceMs = clamp(t.debounceMs, debounceRange)
        t.rapidWindowMs = clamp(t.rapidWindowMs, rapidWindowRange)
        t.keyStaggerMs = clamp(t.keyStaggerMs, keyStaggerRange)
        t.firstKeyDelayMs = clamp(t.firstKeyDelayMs, transitionDelayRange)
        t.overflowDelayMs = clamp(t.overflowDelayMs, transitionDelayRange)
        t.ringSpeed = unit(t.ringSpeed)
        t.ringBrightness = unit(t.ringBrightness)
        t.ringHoldMs = clamp(t.ringHoldMs, ringHoldRange)
        t.ringFadeSteps = clamp(t.ringFadeSteps, ringFadeStepsRange)
        t.ringFadeStepMs = clamp(t.ringFadeStepMs, ringFadeStepMsRange)
        t.minSweepIntervalMs = clamp(t.minSweepIntervalMs, minSweepIntervalRange)
        p.workspaceTransition = t
    }

    /// Pin a workspace's color, or with `nil` go back to the palette. The entry is
    /// removed rather than stored as black.
    public static func setWorkspaceColor(_ color: RGB?, workspaceID: String, in p: inout Preferences) {
        let id = workspaceID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        if let color {
            p.workspaceIdentity.colors[id] = color
        } else {
            p.workspaceIdentity.colors.removeValue(forKey: id)
        }
    }

    /// Replace the palette. An empty one is refused and the default restored: the hash
    /// needs at least one color to land on.
    public static func setPalette(_ colors: [RGB], in p: inout Preferences) {
        p.workspaceIdentity.palette = colors.isEmpty
            ? Preferences.WorkspaceIdentity.defaultPalette
            : colors
    }

    /// Any field of the borrowed key's look, clamped afterwards.
    public static func setOverflow(_ change: (inout Preferences.Overflow) -> Void, in p: inout Preferences) {
        var o = p.overflow
        change(&o)
        o.brightness = unit(o.brightness)
        o.winkEveryMs = clamp(o.winkEveryMs, winkEveryRange)
        o.winkMs = clamp(o.winkMs, winkRange)
        p.overflow = o
    }

    // MARK: - Unconfirmed

    /// The look of a session restored at launch but not yet confirmed live. Stored
    /// under `states["unconfirmed"]`, beside the real states, because it is edited on
    /// the same pane and saved the same way.
    public static func setUnconfirmedAppearance(_ appearance: Appearance, in p: inout Preferences) {
        var next = appearance
        next.brightness = unit(next.brightness)
        next.speed = unit(next.speed)
        p.states[Preferences.unconfirmedKey] = next
    }

    // MARK: - Color themes

    /// Which theme card the picker marks.
    public enum ThemeSelection: Equatable, Sendable {
        case theme(String)
        /// Colors edited by hand since the last theme: no card matches.
        case custom
    }

    /// Wear a theme: its state colors, palette and confirmation color, nothing else.
    public static func setTheme(_ theme: ColorTheme, in p: inout Preferences) {
        p = ColorTheme.apply(theme, to: p)
    }

    public static func themeSelection(_ p: Preferences) -> ThemeSelection {
        ColorTheme.current(in: p).map { .theme($0.id) } ?? .custom
    }

    // MARK: - Custom themes

    /**
     Why `name` cannot name a theme, in the interface language, or `nil` if it can.

     Names are compared trimmed and ignoring case and accents, against every custom
     theme but `excluding` (the one being renamed) and against the built-in names in
     both languages — "classic" would otherwise sit beside "Clásico" as a different
     theme to one reader and the same one to another.
     */
    public static func themeNameProblem(_ name: String, excluding id: String? = nil, in p: Preferences) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return tr("Ponle un nombre.") }
        guard trimmed.count <= ThemeFile.maxNameLength else {
            return tr("El nombre puede tener como mucho %@ caracteres.", String(ThemeFile.maxNameLength))
        }
        let key = folded(trimmed)
        let builtIn = ColorTheme.all.flatMap { [$0.name, UIStrings.table[$0.name] ?? $0.name] }
        let custom = p.customThemes.filter { $0.id != id }.map(\.name)
        if (builtIn + custom).contains(where: { folded($0) == key }) {
            return tr("Ya hay un tema que se llama «%@».", trimmed)
        }
        return nil
    }

    /// `name`, or `name 2`, `name 3`… — the first one free.
    public static func uniqueThemeName(_ name: String, in p: Preferences) -> String {
        let base = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ThemeFile.maxNameLength - 3))
        let start = base.isEmpty ? tr("Tema") : base
        if themeNameProblem(start, in: p) == nil { return start }
        var n = 2
        while themeNameProblem("\(start) \(n)", in: p) != nil { n += 1 }
        return "\(start) \(n)"
    }

    /// Save what the pad wears now — a theme or hand-edited colors — as a new custom
    /// theme. `nil`, and nothing written, when the name is taken or blank.
    @discardableResult
    public static func saveCurrentAsTheme(name: String, in p: inout Preferences) -> CustomTheme? {
        guard themeNameProblem(name, in: p) == nil else { return nil }
        let theme = CustomTheme(
            current: p, id: CustomTheme.newID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        p.customThemes.append(theme)
        return theme
    }

    /// A copy of any theme, built-in or custom, under "Name (copia)" or the next free
    /// variant of it.
    @discardableResult
    public static func duplicateTheme(_ theme: ColorTheme, in p: inout Preferences) -> CustomTheme {
        let name = uniqueThemeName(tr("%@ (copia)", theme.displayName), in: p)
        let copy = CustomTheme(from: theme, id: CustomTheme.newID(), name: name)
        p.customThemes.append(copy)
        return copy
    }

    /// Add an imported theme. Its name is made unique rather than refused — the user
    /// asked for this file to come in — and so is its id.
    @discardableResult
    public static func addTheme(_ theme: CustomTheme, in p: inout Preferences) -> CustomTheme {
        var added = theme
        added.name = uniqueThemeName(theme.name, in: p)
        if added.id.isEmpty || ColorTheme.available(in: p).contains(where: { $0.id == added.id }) {
            added.id = CustomTheme.newID()
        }
        p.customThemes.append(added)
        return added
    }

    /// Rename a custom theme. False for a built-in id or a name that is taken.
    @discardableResult
    public static func renameTheme(id: String, to name: String, in p: inout Preferences) -> Bool {
        guard let index = p.customThemes.firstIndex(where: { $0.id == id }),
              themeNameProblem(name, excluding: id, in: p) == nil else { return false }
        p.customThemes[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return true
    }

    /// Delete a custom theme. A built-in id is ignored. The colors the pad wears are
    /// left alone: deleting a theme is not undoing it.
    public static func deleteTheme(id: String, in p: inout Preferences) {
        p.customThemes.removeAll { $0.id == id }
    }

    private static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: - Helpers

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func unit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
