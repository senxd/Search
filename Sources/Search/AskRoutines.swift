import SwiftUI
import AppKit

// The Automations tab — routines in the Ask window: the nav's list of
// schedules on the left, the routine's page on the right. A run's
// transcript reuses the same TurnView/WorkedFor a chat draws — the
// AskVerdicts env (AskParts.swift) is what keeps its parked cards and
// retry pills pointed at Routines instead of the interactive rail
// (design/automation-frontend.md).

// MARK: - the schedule's own words

extension RoutineSchedule {
    /// The compact readout rows and cards wear — "Daily · 9:00 AM",
    /// "Weekdays · 9:00 AM", "Every 3 hours · :15", "Cron · */15 * * * *".
    var sentence: String {
        let at = RoutineUI.clock(hour, minute)
        switch frequency {
        case .hourly:
            let mm = String(format: ":%02d", minute)
            return interval <= 1 ? "Hourly \(mm)" : "Every \(interval) hours \(mm)"
        case .daily:
            return interval <= 1 ? "Daily · \(at)" : "Every \(interval) days · \(at)"
        case .weekdays:
            return "Weekdays · \(at)"
        case .weekly:
            let names = weekdays.sorted().map(RoutineUI.day)
            return "Weekly · \(names.joined(separator: " ")) · \(at)"
        case .custom:
            return "Cron · \(cron ?? "—")"
        }
    }
}

/// Small routine-facing formatters, kept out of the views.
enum RoutineUI {
    /// The "waiting" hue — FluidTone is neutral/destructive only, so the
    /// amber reads off FluidChipColor's own token.
    static let amber = Color(red: 0xF5/255, green: 0x9E/255, blue: 0x0B/255)

    /// "9:00 AM" in the person's locale.
    static func clock(_ hour: Int, _ minute: Int) -> String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let date = Calendar.current.date(from: comps) ?? Date()
        return When.clock(date)
    }

    /// "Mon" — Calendar.weekday 1 is Sunday.
    static func day(_ weekday: Int) -> String {
        let names = Calendar.current.shortWeekdaySymbols
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : "?"
    }

    /// The next-fire phrasing: "Next in 3h", "Paused" while disabled, "Not
    /// scheduled" when the clock has nothing to say.
    static func nextLine(_ routine: Routine) -> String {
        if !routine.enabled { return "Paused" }
        guard let next = routine.nextRunAt else { return "Not scheduled" }
        return "Next \(When.said(next))"
    }

    /// A run's span — "41s", "4m 39s"; nil while it's still going.
    static func duration(_ run: RoutineRun) -> String? {
        guard let started = run.startedAt else { return nil }
        let end = run.finishedAt ?? Date()
        return AskTurns.worked(end.timeIntervalSince(started))
    }

    /// The run to surface and steer: the one actually on the seat (or
    /// parked for a person) beats a queued run behind it — the runs list
    /// is newest-first, so a fresh queued retry must not mask the live
    /// run it waits on.
    static func liveRun(in runs: [RoutineRun]) -> RoutineRun? {
        runs.first { $0.state == .running || $0.state == .waiting }
            ?? runs.first { $0.state == .queued }
    }

    /// One routine's at-a-glance state — the live run if any, the status
    /// line and its hue, and the unacknowledged-run count. Shared by the
    /// nav row and the new-tab card so neither can drift from the other.
    struct Status {
        let live: RoutineRun?
        let line: String
        let color: Color
        let unacknowledged: Int
    }

    @MainActor
    static func status(of routine: Routine, in routines: Routines) -> Status {
        let runs = routines.runs(of: routine)
        let live = liveRun(in: runs)
        let failed = routines.lastRun(of: routine)
        let line: String
        let color: Color
        if let run = live {
            switch run.state {
            case .running:
                line = run.activity.isEmpty ? "Running" : run.activity
                color = FluidTone.foreground.opacity(0.75)
            case .waiting:
                line = "Waiting on you"
                color = amber
            case .queued:
                line = "Queued"
                color = FluidTone.foreground.opacity(0.75)
            default:
                line = nextLine(routine)
                color = FluidTone.mutedForeground
            }
        } else if let last = failed, last.state == .failed {
            line = "Failed \(AskUI.ago(last.finishedAt ?? last.queuedAt))"
            color = FluidTone.destructive.opacity(0.85)
        } else {
            line = nextLine(routine)
            color = FluidTone.mutedForeground
        }
        return Status(
            live: live, line: line, color: color,
            unacknowledged: runs.filter { $0.state.isTerminal && !$0.acknowledged }.count
        )
    }
}

/// The badge a run's state wears — color, glyph and word all distinct so
/// the state never depends on hue or motion alone (accessibility pass).
struct RunStateChip: View {
    let state: RunState
    @Environment(\.colorScheme) private var scheme

    private var spec: (label: String, color: FluidChipColor, icon: String) {
        switch state {
        case .queued: ("Queued", .gray, "clock")
        case .running: ("Running", .blue, "play")
        case .waiting: ("Waiting on you", .amber, "pause")
        case .succeeded: ("Succeeded", .green, "checkmark")
        case .failed: ("Failed", .red, "exclamationmark")
        case .cancelled: ("Cancelled", .gray, "xmark")
        }
    }

    /// One plain sentence of what the state means — the tooltip the
    /// chip's glyph can't carry on its own.
    private var tip: String {
        switch state {
        case .queued: "Waiting for the run ahead to finish"
        case .running: "On the seat now"
        case .waiting: "Parked until you answer"
        case .succeeded: "Finished cleanly"
        case .failed: "Ended on an error"
        case .cancelled: "Stopped before it finished"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: spec.icon)
                .font(.system(size: 7, weight: .bold))
            Text(spec.label)
        }
        .font(.system(size: FluidChipSize.sm.fontSize, weight: .medium))
        .foregroundStyle(chipText)
        .padding(.horizontal, FluidChipSize.sm.hPadding)
        .frame(height: FluidChipSize.sm.height)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(chipFill)
        )
        .help(tip)
    }
}

/// A live run's mark — the spinner everywhere except under Reduce
/// Motion, where a still asterisk says "working" without animating.
private struct LiveGlyph: View {
    var size: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var calm

    var body: some View {
        Group {
            if calm {
                Image(systemName: "asterisk.circle.fill")
                    .font(.system(size: size + 1))
                    .foregroundStyle(FluidTone.mutedForeground)
            } else {
                Ring(size: size)
            }
        }
    }
}

/// The chip colors, lifted so RunStateChip can paint a glyph + label in
/// the same swatch FluidChip's gray/color math produces.
private extension RunStateChip {
    var chipText: Color {
        if spec.color == .gray { return FluidTone.foreground.opacity(0.8) }
        let fg: CGFloat = scheme == .dark ? 0.985 : 0x17/255
        return Color(
            red: spec.color.rgb.0 * 0.85 + fg * 0.15,
            green: spec.color.rgb.1 * 0.85 + fg * 0.15,
            blue: spec.color.rgb.2 * 0.85 + fg * 0.15
        )
    }

    var chipFill: Color {
        if spec.color == .gray { return FluidTone.foreground.opacity(0.10) }
        return Color(red: spec.color.rgb.0, green: spec.color.rgb.1, blue: spec.color.rgb.2, opacity: 0.18)
    }
}

// MARK: - the form's draft

/// The routine form's working copy — `editing` nil means create. The
/// schedule fields stay flat so the frequency pick swaps what it shows
/// without migrating a nested struct.
struct RoutineDraft: Equatable {
    /// The routine being edited — nil on "New routine".
    var editing: Routine? = nil
    var name = ""
    var prompt = ""
    var enabled = true
    var frequency: RoutineSchedule.Frequency = .daily
    var interval = 1
    /// Weekly's days — Calendar.weekday (1 = Sunday).
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    /// "9:00" free text — validated, so a typo is a field error not a
    /// silently wrong schedule.
    var clock = "9:00"
    var cron = "0 9 * * *"
    var timezone = TimeZone.current.identifier
    /// "" means the chat default — the run picks the saved model.
    var model = ""
    var mode = AskMode.guard
    var timeoutSeconds = 1800
    var notify = true

    init() {}

    init(_ routine: Routine) {
        editing = routine
        name = routine.name
        prompt = routine.prompt
        enabled = routine.enabled
        frequency = routine.schedule.frequency
        interval = routine.schedule.interval
        weekdays = routine.schedule.weekdays.isEmpty
            ? [2, 3, 4, 5, 6] : routine.schedule.weekdays
        clock = String(format: "%d:%02d", routine.schedule.hour, routine.schedule.minute)
        cron = routine.schedule.cron ?? "0 9 * * *"
        timezone = routine.timezone
        model = routine.model ?? ""
        mode = routine.mode
        timeoutSeconds = routine.timeoutSeconds
        notify = routine.notify ?? true
    }

    /// The parsed wall-clock — nil while the field isn't "H:MM".
    var parsedClock: (hour: Int, minute: Int)? {
        let parts = clock.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// The weekdays init materialized for this routine — the field shows
    /// Mon–Fri for an empty set, so the materialized value is what an
    /// untouched field compares equal to.
    private var materializedWeekdays: Set<Int> {
        guard let editing else { return weekdays }
        return editing.schedule.weekdays.isEmpty ? [2, 3, 4, 5, 6] : editing.schedule.weekdays
    }

    /// The assembled schedule — what Save writes.
    var schedule: RoutineSchedule {
        var s = RoutineSchedule()
        s.frequency = frequency
        s.interval = interval
        // An untouched weekday field writes back what the routine
        // already had — a legacy empty set stays empty instead of
        // materializing Mon–Fri into a routine the person never edited.
        s.weekdays = editing != nil && weekdays == materializedWeekdays
            ? editing!.schedule.weekdays : weekdays
        let (h, m) = parsedClock ?? (9, 0)
        s.hour = h
        s.minute = m
        s.cron = frequency == .custom ? cron : nil
        return s
    }

    /// Whether the schedule reads honest — the field-level errors key off
    /// this (and Save stays shut until it's true).
    var clockValid: Bool { parsedClock != nil }
    var cronValid: Bool { RoutineCron(cron) != nil }
    var scheduleValid: Bool {
        switch frequency {
        case .custom: return cronValid
        case .weekly: return clockValid && !weekdays.isEmpty
        default: return clockValid
        }
    }

    var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && scheduleValid
    }

    /// The routine this draft writes — new id on create, the edited one's
    /// identity on save.
    func assemble() -> Routine {
        var routine = editing ?? Routine(name: name, prompt: prompt)
        routine.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        routine.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        routine.enabled = enabled
        routine.schedule = schedule
        routine.timezone = timezone
        routine.model = model.isEmpty ? nil : model
        routine.mode = mode
        routine.timeoutSeconds = timeoutSeconds
        // nil means "the app default" — keep it until the toggle actually
        // moves, or every untouched edit-open reads dirty.
        routine.notify = editing != nil && notify == (editing!.notify ?? true)
            ? editing!.notify : notify
        return routine
    }

    /// Anything changed — the dirty guard on Cancel/Esc. A create-form
    /// with any typing counts as dirty.
    var dirty: Bool {
        guard let editing else {
            return !name.isEmpty || !prompt.isEmpty
        }
        return assemble() != editing
    }
}

// MARK: - the nav row

/// One routine in the nav — name, its schedule's words, and a status
/// line on the 48pt row; badges trailing, ⋯ menu on hover. Same anatomy
/// as the chat row above it (fullscreen-ux §3).
struct RoutineRow: View {
    var routine: Routine
    let index: Int
    var menuOpen = false
    var onMenu: (Bool) -> Void = { _ in }
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    @ObservedObject private var routines = Routines.shared

    /// The row's whole "how is it doing" — shared with the new-tab card
    /// so the two can never drift.
    private var status: RoutineUI.Status {
        RoutineUI.status(of: routine, in: routines)
    }

    var body: some View {
        FluidSidebarMenuButton(
            index: index,
            size: .large
        ) {
            RoutinesUI.select(routine.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                FluidSidebarMenuRowLabel(label: routine.name)
                Text(routine.schedule.sentence)
                    .font(.system(size: 11))
                    .foregroundStyle(FluidTone.mutedForeground)
                    .lineLimit(1)
                Text(status.line)
                    .font(.system(size: 10))
                    .foregroundStyle(status.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
        } trailing: {
            FluidSidebarMenuActions(showOnHover: true) {
                FluidSidebarMenuAction("ellipsis", popupOpen: menuOpen) {
                    onMenu(true)
                }
                .fluidMenuPopup(isPresented: Binding(
                    get: { menuOpen }, set: { onMenu($0) }),
                    width: 180, maxHeight: nil) {
                    FluidMenuItem(index: 0, icon: "play", label: "Run now") {
                        routines.runNow(routine)
                    }
                    FluidMenuItem(index: 1, icon: "pencil", label: "Edit…") {
                        onEdit()
                    }
                    FluidMenuItem(index: 2,
                                  icon: routine.enabled ? "pause" : "play",
                                  label: routine.enabled ? "Pause" : "Resume") {
                        var copy = routine
                        copy.enabled.toggle()
                        routines.save(copy)
                    }
                    FluidMenuItem(index: 3, icon: "trash", label: "Delete…") {
                        onDelete()
                    }
                }
            }
            if let run = status.live {
                RowGutterSlot {
                    if run.state == .waiting {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(RoutineUI.amber)
                            .frame(width: MenuGutter.slot)
                    } else {
                        LiveGlyph(size: 9)
                            .frame(width: MenuGutter.slot)
                    }
                }
            } else {
                // The switch is the row's always-on affordance — enabled
                // or paused at a glance and a click, no menu dive.
                RowGutterSlot {
                    FluidSwitch(
                        isOn: Binding(
                            get: { routine.enabled },
                            set: { on in
                                var copy = routine
                                copy.enabled = on
                                routines.save(copy)
                            }),
                        size: .compact)
                        .accessibilityLabel("\(routine.name) schedule")
                        .accessibilityValue(routine.enabled ? "on" : "paused")
                }
            }
        }
        .contextMenu {
            Button("Run now") { routines.runNow(routine) }
            Button("Edit…") { onEdit() }
            Button(routine.enabled ? "Pause" : "Resume") {
                var copy = routine
                copy.enabled.toggle()
                routines.save(copy)
            }
            Divider()
            Button("Delete…", role: .destructive) { onDelete() }
        }
        .accessibilityLabel("\(routine.name), \(routine.schedule.sentence), \(status.line)")
        .accessibilityHint("Routine")
    }
}

/// Where the nav row sends its selection — a plain global so the row
/// doesn't carry a binding through two view layers. AskPage sets it once
/// (to its dirty-guarded requestSelect).
enum RoutinesUI {
    static var select: (UUID) -> Void = { _ in }
}

/// A trailing control that isn't a FluidSidebarMenuAction still needs the
/// row's gutter to leave room — registering a pinned phantom slot is the
/// reservation (the switch is a hair wider than one slot, which the
/// label's truncation tolerates).
private struct RowGutterSlot<Content: View>: View {
    @Environment(\.fluidMenuRow) private var row
    @State private var id = UUID()
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .onAppear { row?.register(id, showOnHover: false, popupOpen: false) }
            .onDisappear { row?.unregister(id) }
    }
}

// MARK: - the board

/// The column's whole Automations half — header band, then the form, the
/// selected routine's page, or the empty hero. Selection and dialogs are
/// the page's (its Esc cascade consults them); the rest is local.
struct RoutineBoard: View {
    @ObservedObject var browser: Browser
    @Binding var routineID: UUID?
    @Binding var draft: RoutineDraft?
    @Binding var discarding: Bool
    @Binding var deleting: Routine?
    @ObservedObject private var routines = Routines.shared

    private var routine: Routine? {
        routineID.flatMap { routines.routine($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            head
            if let draft {
                RoutineForm(draft: Binding(
                    get: { draft },
                    set: { self.draft = $0 }
                ), onDone: { self.draft = nil }, discarding: $discarding)
            } else if let routine {
                RoutineDetail(routine: routine, browser: browser,
                              onEdit: { draft = RoutineDraft(routine) },
                              onDelete: { deleting = routine })
                    .id(routine.id)
            } else {
                RoutineBoardEmpty(hasRoutines: !routines.routines.isEmpty) {
                    draft = RoutineDraft()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FluidTone.surface(1))
    }

    /// The same 52pt band the chat page wears — trigger, the surface's
    /// name, and nothing else: the detail's actions live on the page
    /// itself, under it.
    private var head: some View {
        HStack(spacing: 8) {
            SidebarLeadRoom()
            FluidSidebarTrigger()
            Text(draft != nil
                 ? (draft?.editing == nil ? "New routine" : "Edit routine")
                 : "Automations")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FluidTone.foreground)
            if routines.badge > 0, draft == nil {
                // The aggregate unread/waiting count — the same number the
                // nav tab's dot rides.
                Text("\(routines.badge)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(FluidTone.destructive)
                    .frame(minWidth: 16)
                    .frame(height: 16)
                    .padding(.horizontal, 3)
                    .background(FluidTone.destructiveLight, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(FluidTone.surface(1))
    }
}

/// No routine selected — or none exist yet: the mark, one line of what it
/// is, and the door in when there's nothing to pick.
private struct RoutineBoardEmpty: View {
    var hasRoutines = false
    var onNew: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "clock.badge")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 64, height: 64)
                .background(FluidTone.surface(2), in: Circle())
                .overlay(Circle().strokeBorder(FluidTone.border, lineWidth: 1))
            Text("Automations")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(FluidTone.foreground)
            Text(hasRoutines
                 ? "Pick a routine on the left."
                 : "Tasks the agent runs on a schedule —\ndigests, checks, rounds of gathering.")
                .font(.system(size: 13))
                .foregroundStyle(FluidTone.mutedForeground)
                .multilineTextAlignment(.center)
            if !hasRoutines {
                FluidButton("New routine", variant: .secondary,
                            leadingIcon: "plus") { onNew() }
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}

// MARK: - the routine's page

/// One routine — status line, the prompt it runs, the live run's strip
/// and parked cards while it needs a person, then run history, each run
/// opening into its transcript in place.
private struct RoutineDetail: View {
    var routine: Routine
    @ObservedObject var browser: Browser
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    @ObservedObject private var routines = Routines.shared
    /// The run whose transcript is open — the live one opens itself.
    @State private var openRunID: UUID?
    /// The header ⋯ menu.
    @State private var menuOpen = false

    /// The run on the seat or in line — the strip and the auto-open both
    /// key off it.
    private var liveRun: RoutineRun? {
        RoutineUI.liveRun(in: runs)
    }

    private var runs: [RoutineRun] { routines.runs(of: routine) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let live = liveRun {
                    RunLiveStrip(run: live)
                }
                promptCard
                runsSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        // The live run's transcript opens itself — arriving at a running
        // routine should land on the work, not a folded row.
        .onChange(of: liveRun?.id) { _, id in
            if let id { openRunID = id }
        }
        .onAppear {
            if let id = liveRun?.id { openRunID = id }
        }
    }

    /// Name, the schedule's sentence, the leash it's on — then the doors:
    /// Run now, Edit, and the ⋯ with pause and delete.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                RoutineNameField(routine: routine)
                if let live = liveRun {
                    if live.state == .waiting {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(RoutineUI.amber)
                    } else {
                        LiveGlyph(size: 9)
                    }
                }
                Spacer(minLength: 0)
                // The schedule's leash — on, the routine fires; off it's
                // paused, and the chips say so beside it.
                FluidSwitch(
                    isOn: Binding(
                        get: { routine.enabled },
                        set: { on in
                            var copy = routine
                            copy.enabled = on
                            routines.save(copy)
                        }),
                    size: .compact)
                    .accessibilityLabel(routine.enabled ? "Pause routine" : "Resume routine")
                FluidButton("Run now", variant: .secondary, size: .compact,
                            leadingIcon: "play") {
                    routines.runNow(routine)
                }
                .accessibilityLabel("Run \(routine.name) now")
                FluidButton(variant: .ghost, size: .iconCompact) {
                    onEdit()
                } label: {
                    FluidIcon("pencil", size: 14)
                }
                .help("Edit routine")
                .accessibilityLabel("Edit routine")
                moreMenu
            }
            HStack(spacing: 6) {
                FluidChip(routine.schedule.sentence, size: .sm)
                if routine.enabled {
                    FluidChip(RoutineUI.nextLine(routine), size: .sm)
                }
                if routine.timezone != TimeZone.current.identifier {
                    FluidChip(routine.timezone, size: .sm)
                }
                FluidChip(routine.mode.label, size: .sm)
                if let model = routine.model, !model.isEmpty {
                    FluidChip(model, size: .sm)
                }
                if !routine.enabled {
                    FluidChip("Paused", color: .amber, size: .sm)
                }
            }
        }
    }

    private var moreMenu: some View {
        FluidButton(variant: .ghost, size: .iconCompact, active: menuOpen) {
            menuOpen = true
        } label: {
            FluidIcon("ellipsis", size: 14)
        }
        .help("Routine actions")
        .accessibilityLabel("Routine actions")
        .fluidMenuPopup(isPresented: $menuOpen, width: 180, maxHeight: nil) {
            FluidMenuItem(index: 0, icon: "pencil", label: "Edit…") { onEdit() }
            FluidMenuItem(index: 1,
                          icon: routine.enabled ? "pause" : "play",
                          label: routine.enabled ? "Pause" : "Resume") {
                var copy = routine
                copy.enabled.toggle()
                routines.save(copy)
            }
            FluidMenuItem(index: 2, icon: "doc.on.doc", label: "Copy prompt") {
                AskUI.copy(routine.prompt)
            }
            FluidMenuItem(index: 3, icon: "trash", label: "Delete…") { onDelete() }
        }
    }

    /// The prompt it runs on — the card is the edit's own preview; the
    /// pencil leads to the form.
    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROMPT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FluidTone.mutedForeground)
            Text(routine.prompt)
                .font(.system(size: 13))
                .foregroundStyle(FluidTone.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(FluidTone.card, in: RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous)
                .strokeBorder(FluidTone.border.opacity(0.6), lineWidth: 1)
        )
    }

    /// The history — newest first, each row opening its transcript in
    /// place. Clicking a finished run also marks it seen (the badge lets
    /// it go once the person has actually looked).
    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RUNS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FluidTone.mutedForeground)
                Spacer(minLength: 0)
                if runs.count > 1 {
                    Text("\(runs.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(FluidTone.mutedForeground)
                }
            }
            if runs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No runs yet")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(FluidTone.foreground)
                    Text(routine.enabled
                         ? "The next one fires \(routine.nextRunAt.map { When.said($0) } ?? "—")."
                         : "Paused — resume it, or try it out now.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(FluidTone.mutedForeground)
                    FluidButton("Run now", variant: .secondary, size: .compact,
                                leadingIcon: "play") {
                        routines.runNow(routine)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                .background(FluidTone.card, in: RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous)
                        .strokeBorder(FluidTone.border.opacity(0.6), lineWidth: 1)
                )
            } else {
                ForEach(runs) { run in
                    RunCard(run: run, browser: browser,
                            open: openRunID == run.id) {
                        // Opening a finished run is the look the badge
                        // was counting — acknowledge it then.
                        if openRunID == run.id {
                            openRunID = nil
                        } else {
                            openRunID = run.id
                            if run.state.isTerminal && !run.acknowledged {
                                routines.acknowledge(run)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - the live strip

/// The run on the seat right now, up top: its doing-word, the elapsed
/// clock, and the parked cards it wants answered — everything the run is
/// asking for in one place rather than scattered through the transcript.
private struct RunLiveStrip: View {
    let run: RoutineRun
    @ObservedObject private var routines = Routines.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if run.state == .waiting {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(RoutineUI.amber)
                } else {
                    LiveGlyph(size: 10)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.state == .waiting ? "Waiting on you"
                         : run.state == .queued ? "Queued — behind another run"
                         : (run.activity.isEmpty ? "Running" : run.activity))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(FluidTone.foreground)
                    if let started = run.startedAt {
                        ElapsedLine(since: started,
                                    label: run.trigger.label)
                    }
                }
                Spacer(minLength: 0)
                if !run.state.isTerminal {
                    FluidButton("Stop", variant: .tertiary, size: .compact,
                                leadingIcon: "stop") {
                        routines.stop(run)
                    }
                    .accessibilityLabel("Stop this run")
                }
            }
            if !run.waitingApprovals.isEmpty || run.waitingQuestion != nil {
                VStack(spacing: 6) {
                    ForEach(run.waitingApprovals) { approval in
                        ApprovalCard(approval: approval)
                    }
                    if let question = run.waitingQuestion {
                        QuestionCard(question: question)
                    }
                }
                .environment(\.askVerdicts, .run(run))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous)
                .fill(run.state == .waiting
                      ? RoutineUI.amber.opacity(0.08) : FluidTone.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous)
                .strokeBorder(run.state == .waiting
                              ? RoutineUI.amber.opacity(0.35) : FluidTone.border.opacity(0.6),
                              lineWidth: 1)
        )
    }
}

/// The ticking "run now · 0:41" under the strip's word — one TimelineView
/// a run, and only while the strip exists (automation-frontend §6).
private struct ElapsedLine: View {
    let since: Date
    var label = ""

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text("\(label.isEmpty ? "" : "\(label) · ")\(AskTurns.worked(context.date.timeIntervalSince(since)))")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(FluidTone.mutedForeground)
        }
    }
}

// MARK: - a run, in the list

/// One run — status, trigger, when, span — opening into its transcript
/// in place, parked cards inside while it still wants an answer.
private struct RunCard: View {
    let run: RoutineRun
    @ObservedObject var browser: Browser
    var open = false
    var onToggle: () -> Void = {}
    @ObservedObject private var routines = Routines.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if open {
                Rule(inset: 0)
                RunTranscript(run: run, browser: browser)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        }
        .background(FluidTone.card, in: RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous)
                .strokeBorder(FluidTone.border.opacity(0.6), lineWidth: 1)
        )
        .animation(FluidSpring.fast, value: open)
        // Watching it settle while open is the same look as expanding a
        // finished run — count it acknowledged either way.
        .onChange(of: run.state) { _, state in
            if open && state.isTerminal && !run.acknowledged {
                routines.acknowledge(run)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            // The toggle owns the label stretch; stop / retry live
            // outside it — buttons nested in a button's label fire both.
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(FluidTone.mutedForeground)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    RunStateChip(state: run.state)
                    Text(run.trigger.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(FluidTone.mutedForeground)
                    Text(When.said(run.queuedAt))
                        .font(.system(size: 11.5))
                        .foregroundStyle(FluidTone.mutedForeground)
                    if let span = RoutineUI.duration(run) {
                        Text(span)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(FluidTone.mutedForeground)
                    }
                    if let error = run.error, run.state == .failed, !open {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(FluidTone.destructive.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(run.state.rawValue) run, \(run.trigger.label), \(When.said(run.queuedAt))")
            .accessibilityHint(open ? "Close transcript" : "Open transcript")
            if run.state.isTerminal && !run.acknowledged {
                Circle()
                    .fill(FluidTone.destructive)
                    .frame(width: 6, height: 6)
                    .help("Not seen yet")
            }
            if run.state == .running || run.state == .queued || run.state == .waiting {
                FluidButton(variant: .ghost, size: .iconCompact) {
                    routines.stop(run)
                } label: {
                    FluidIcon("stop", size: 12)
                }
                .help("Stop this run")
                .accessibilityLabel("Stop run")
            } else if run.state == .failed || run.state == .cancelled {
                FluidButton(variant: .ghost, size: .iconCompact) {
                    routines.retry(run)
                } label: {
                    FluidIcon("arrow.clockwise", size: 12)
                }
                .help("Retry this run")
                .accessibilityLabel("Retry run")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - a run's transcript

/// The run's chat drawn with the same turns a chat's is — orphans, then
/// TurnView for each exchange with the accordion folding rules the stream
/// keeps (live last-turn open, user toggles win). The verdicts env routes
/// every parked card and retry pill at Routines, never Mind.
private struct RunTranscript: View {
    let run: RoutineRun
    @ObservedObject var browser: Browser
    @Environment(\.askDensity) private var density
    @State private var openTurns: Set<UUID> = []
    @State private var foldedTurns: Set<UUID> = []

    private var live: Bool { run.state == .running || run.state == .waiting }

    private var split: (orphans: [AskMessage], turns: [AskTurn]) {
        AskTurns.split(run.chat.messages)
    }

    private var mixed: Bool {
        Set(run.chat.messages.compactMap(\.model)).count > 1
    }

    private func turnOpen(_ turn: AskTurn, isLast: Bool) -> Binding<Bool> {
        Binding(
            get: { openTurns.contains(turn.id)
                || (live && isLast && !foldedTurns.contains(turn.id)) },
            set: { open in
                if open {
                    openTurns.insert(turn.id)
                    foldedTurns.remove(turn.id)
                } else {
                    openTurns.remove(turn.id)
                    foldedTurns.insert(turn.id)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.turnGap) {
            ForEach(split.orphans) { message in
                AskLine(message: message, browser: browser)
            }
            ForEach(Array(split.turns.enumerated()), id: \.element.id) { index, turn in
                let isLast = index == split.turns.count - 1
                TurnView(
                    turn: turn,
                    live: live && isLast,
                    waiting: run.state == .waiting && isLast,
                    startedAt: run.chat.turnStartedAt,
                    activity: run.activity,
                    mixed: mixed,
                    open: turnOpen(turn, isLast: isLast),
                    browser: browser
                )
            }
            if split.orphans.isEmpty && split.turns.isEmpty {
                Text("Nothing to show yet")
                    .font(.system(size: density.note))
                    .foregroundStyle(FluidTone.mutedForeground)
            }
        }
        .environment(\.askVerdicts, .run(run))
    }
}

// MARK: - the form

/// New-routine and edit share one page: name, the prompt, when it runs,
/// what it runs under, and the commit bar. `draft` is the page's — its
/// Esc and Cancel consult `dirty` before shedding it.
private struct RoutineForm: View {
    @Binding var draft: RoutineDraft
    var onDone: () -> Void = {}
    /// The page's "discard changes?" dialog — Esc and Cancel both ask it.
    @Binding var discarding: Bool
    @ObservedObject private var routines = Routines.shared

    /// Field errors, shown only once the person has tried to commit —
    /// typing into an empty form shouldn't read as already wrong.
    @State private var tried = false
    /// The raw ":MM" text for hourly schedules — kept as state so
    /// clearing the field mid-typing doesn't snap back to "00".
    @State private var minuteField = ""

    private var frequencySel: Binding<String?> {
        Binding(
            get: { draft.frequency.rawValue },
            set: { draft.frequency = RoutineSchedule.Frequency(rawValue: $0 ?? "") ?? .daily }
        )
    }

    private var modeSel: Binding<String?> {
        Binding(get: { draft.mode.rawValue },
                set: { draft.mode = AskMode(rawValue: $0 ?? "") ?? .guard })
    }

    private var modelSel: Binding<String?> {
        Binding(get: { draft.model.isEmpty ? nil : draft.model },
                set: { draft.model = $0 ?? "" })
    }

    private var timeoutSel: Binding<String?> {
        Binding(get: { "\(draft.timeoutSeconds)" },
                set: { draft.timeoutSeconds = Int($0 ?? "") ?? 1800 })
    }

    private var tzSel: Binding<String?> {
        Binding(get: { draft.timezone },
                set: { draft.timezone = $0 ?? TimeZone.current.identifier })
    }

    private var intervalSel: Binding<String?> {
        Binding(get: { "\(draft.interval)" },
                set: { draft.interval = Int($0 ?? "1") ?? 1 })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    FluidInputGroup {
                        FluidInput(label: "Name", text: $draft.name,
                                   placeholder: "Morning digest",
                                   error: tried && draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                                       ? "A name is needed" : nil,
                                   index: 0)
                        RoutinePromptField(prompt: $draft.prompt,
                                           error: tried && draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                               ? "What should it do?" : nil,
                                           index: 1)
                    }

                    scheduleSection
                    engineSection
                    optionsSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            Rule(inset: 0)
            commitBar
        }
        .onAppear {
            minuteField = String(format: "%02d", draft.parsedClock?.minute ?? 0)
        }
    }

    /// When it fires — the frequency pick plus the fields that frequency
    /// actually reads, each shown only when it means something.
    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SCHEDULE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FluidTone.mutedForeground)

            FluidSelect(selection: frequencySel, placeholder: "How often",
                        icon: "clock") {
                ForEach(Array(RoutineSchedule.Frequency.allCases.enumerated()),
                        id: \.element.rawValue) { i, frequency in
                    FluidSelectItem(index: i, value: frequency.rawValue,
                                    label: frequency.label)
                }
            }

            switch draft.frequency {
            case .hourly:
                HStack(spacing: 8) {
                    Text("Every")
                        .font(.system(size: 13))
                        .foregroundStyle(FluidTone.mutedForeground)
                    FluidSelect(selection: intervalSel, placeholder: "1") {
                        ForEach(Array([1, 2, 3, 4, 6, 8, 12].enumerated()), id: \.element) { i, n in
                            FluidSelectItem(index: i, value: "\(n)",
                                            label: n == 1 ? "hour" : "\(n) hours")
                        }
                        if ![1, 2, 3, 4, 6, 8, 12].contains(draft.interval) {
                            FluidSelectItem(index: 7, value: "\(draft.interval)",
                                            label: "\(draft.interval) hours")
                        }
                    }
                    .frame(width: 130)
                    Text("at")
                        .font(.system(size: 13))
                        .foregroundStyle(FluidTone.mutedForeground)
                    FluidInput(text: minuteOnly, placeholder: ":00",
                               error: tried && !draft.clockValid ? "MM" : nil)
                        .frame(width: 64)
                }
            case .daily:
                HStack(spacing: 8) {
                    FluidSelect(selection: intervalSel, placeholder: "Every day") {
                        ForEach(Array([(1, "Every day"), (2, "Every 2 days"), (3, "Every 3 days"), (7, "Every week")].enumerated()), id: \.element.0) { i, pair in
                            FluidSelectItem(index: i, value: "\(pair.0)", label: pair.1)
                        }
                        if ![1, 2, 3, 7].contains(draft.interval) {
                            FluidSelectItem(index: 4, value: "\(draft.interval)",
                                            label: "Every \(draft.interval) days")
                        }
                    }
                    .frame(width: 150)
                    atField
                }
            case .weekdays:
                HStack(spacing: 8) {
                    Text("Monday – Friday")
                        .font(.system(size: 13))
                        .foregroundStyle(FluidTone.mutedForeground)
                    atField
                }
            case .weekly:
                VStack(alignment: .leading, spacing: 8) {
                    WeekdayPicker(days: $draft.weekdays)
                    atField
                }
            case .custom:
                FluidInput(text: $draft.cron, placeholder: "0 9 * * *",
                           icon: "number",
                           error: tried && !draft.cronValid
                               ? "Five fields — minute hour day month weekday" : nil)
                if draft.cronValid,
                   let next = draft.schedule.next(after: Date(),
                                                tz: TimeZone(identifier: draft.timezone) ?? .current) {
                    Text("Next \(When.said(next))")
                        .font(.system(size: 11))
                        .foregroundStyle(FluidTone.mutedForeground)
                }
            }

            if draft.frequency != .custom, let clock = draft.parsedClock,
               let next = draft.schedule.next(after: Date(),
                                            tz: TimeZone(identifier: draft.timezone) ?? .current) {
                Text("Next \(When.said(next)) · \(RoutineUI.clock(clock.hour, clock.minute))")
                    .font(.system(size: 11))
                    .foregroundStyle(FluidTone.mutedForeground)
            }

            FluidSelect(selection: tzSel, placeholder: "Time zone",
                        icon: "globe") {
                ForEach(Array(timezones.enumerated()), id: \.element) { i, zone in
                    FluidSelectItem(index: i, value: zone, label: zoneLabel(zone))
                }
            }
        }
    }

    /// The ":MM" half of `clock` for hourly schedules — its hour is
    /// whatever the grid lands on. The raw field leads; the committed
    /// clock follows the digits.
    private var minuteOnly: Binding<String> {
        Binding(
            get: { minuteField },
            set: { text in
                let digits = String(text.filter(\.isNumber).prefix(2))
                minuteField = digits
                draft.clock = digits.isEmpty ? "0:" : "0:\(digits)"
            }
        )
    }

    private var atField: some View {
        HStack(spacing: 8) {
            Text("at")
                .font(.system(size: 13))
                .foregroundStyle(FluidTone.mutedForeground)
            FluidInput(text: $draft.clock, placeholder: "9:00",
                       error: tried && !draft.clockValid ? "H:MM — like 9:00 or 17:30" : nil)
                .frame(width: 110)
        }
    }

    /// A curated zone list — the current one first so the common case is
    /// one row, then the ones people actually pick, plus whatever the
    /// routine already carries when it isn't on the list.
    private var timezones: [String] {
        let current = TimeZone.current.identifier
        let common = [
            "UTC",
            "America/New_York", "America/Chicago", "America/Denver",
            "America/Los_Angeles", "America/Toronto", "America/Mexico_City",
            "America/Sao_Paulo", "Europe/London", "Europe/Berlin",
            "Europe/Paris", "Europe/Madrid", "Europe/Amsterdam",
            "Europe/Stockholm", "Europe/Istanbul", "Africa/Cairo",
            "Asia/Dubai", "Asia/Kolkata", "Asia/Shanghai", "Asia/Tokyo",
            "Asia/Singapore", "Australia/Sydney", "Pacific/Auckland",
        ]
        var seen = Set<String>()
        return ([current, draft.timezone] + common).filter { seen.insert($0).inserted }
    }

    private func zoneLabel(_ id: String) -> String {
        id == TimeZone.current.identifier
            ? "\(id.replacingOccurrences(of: "_", with: " ")) — system"
            : id.replacingOccurrences(of: "_", with: " ")
    }

    /// What it runs under — the model (chat default when unset) and the
    /// leash (guard by default).
    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RUNS WITH")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FluidTone.mutedForeground)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.system(size: 12))
                        .foregroundStyle(FluidTone.mutedForeground)
                    FluidSelect(selection: modelSel, placeholder: "Chat default") {
                        FluidSelectItem(index: 0, value: "", label: "Chat default")
                        ForEach(Array(AskChips.models.enumerated()), id: \.element.model) { i, item in
                            FluidSelectItem(index: i + 1,
                                            value: "\(item.provider)/\(item.model)",
                                            label: item.title)
                        }
                        if !draft.model.isEmpty,
                           !AskChips.models.contains(where: { "\($0.provider)/\($0.model)" == draft.model }) {
                            FluidSelectItem(index: AskChips.models.count + 1,
                                            value: draft.model, label: draft.model)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mode")
                        .font(.system(size: 12))
                        .foregroundStyle(FluidTone.mutedForeground)
                    FluidSelect(selection: modeSel, placeholder: "Guard") {
                        FluidSelectItem(index: 0, value: AskMode.read.rawValue,
                                        icon: AskMode.read.icon, label: "Read — pages only")
                        FluidSelectItem(index: 1, value: AskMode.guard.rawValue,
                                        icon: AskMode.guard.icon, label: "Guard — heavy ops ask")
                        FluidSelectItem(index: 2, value: AskMode.full.rawValue,
                                        icon: AskMode.full.icon, label: "Full — never asks")
                    }
                }
            }
        }
    }

    /// The ceiling, the ping, and whether it's on at all.
    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OPTIONS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FluidTone.mutedForeground)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Timeout")
                        .font(.system(size: 12))
                        .foregroundStyle(FluidTone.mutedForeground)
                    FluidSelect(selection: timeoutSel, placeholder: "30 minutes") {
                        ForEach(Array([(300, "5 minutes"), (900, "15 minutes"),
                                       (1800, "30 minutes"), (3600, "An hour")].enumerated()),
                                id: \.element.0) { i, pair in
                            FluidSelectItem(index: i, value: "\(pair.0)", label: pair.1)
                        }
                        // An off-list persisted value still names itself.
                        if ![300, 900, 1800, 3600].contains(draft.timeoutSeconds) {
                            FluidSelectItem(index: 4, value: "\(draft.timeoutSeconds)",
                                            label: draft.timeoutSeconds % 60 == 0
                                                ? "\(draft.timeoutSeconds / 60) minutes"
                                                : "\(draft.timeoutSeconds) seconds")
                        }
                    }
                }
                .frame(maxWidth: 180, alignment: .leading)
            }
            FluidSwitch(isOn: $draft.notify, label: "Tell me when a run fails or waits")
            FluidSwitch(isOn: $draft.enabled, label: "Run on schedule")
        }
    }

    /// Cancel with its dirty guard, Save when the form reads true. Esc
    /// hits the same `close()` — dirty asks first.
    private var commitBar: some View {
        HStack(spacing: 8) {
            FluidButton("Cancel", variant: .tertiary) { close() }
                .accessibilityHint(draft.dirty ? "You'll be asked before changes go" : "")
            Spacer(minLength: 0)
            FluidButton(draft.editing == nil ? "Create routine" : "Save",
                        variant: .primary) { save() }
                .disabled(!draft.valid)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func close() {
        if draft.dirty {
            discarding = true
        } else {
            onDone()
        }
    }

    private func save() {
        guard draft.valid else { tried = true; return }
        let routine = draft.assemble()
        let id: UUID
        if draft.editing == nil {
            id = routines.add(routine).id
        } else {
            routines.save(routine)
            id = routine.id
        }
        // A commit isn't a shed — clear the draft first so the follow-up
        // selection can't trip the dirty guard into a phantom "Discard?".
        onDone()
        RoutinesUI.select(id)
    }
}

// MARK: - small form pieces

/// The prompt field — a multi-line FluidInput-shaped area: the label over
/// a rounded box the text sits in (the prompt is a paragraph, not a line,
/// so TextEditor does the work).
private struct RoutinePromptField: View {
    @Binding var prompt: String
    var error: String? = nil
    var index: Int? = nil

    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var size
    @Environment(\.fluidHover) private var hover
    @FocusState private var focused: Bool
    @State private var selfHovered = false

    private var isActive: Bool {
        index.map { hover?.activeIndex == $0 } ?? selfHovered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .leading) {
                Text("Prompt").fontWeight(.semibold).opacity(0)
                Text("Prompt")
                    .foregroundStyle(error != nil ? FluidTone.destructive : FluidTone.mutedForeground)
            }
            .font(.system(size: size.text))
            .padding(.leading, size == .compact ? 8 : 10)

            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Summarize today's top stories and save the three that matter…")
                        .font(.system(size: size.text))
                        .foregroundStyle(FluidTone.mutedForeground.opacity(0.7))
                        .padding(.horizontal, size == .compact ? 8 : 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: size.text))
                    .foregroundStyle(FluidTone.foreground)
                    .focused($focused)
                    .frame(minHeight: 84)
                    .padding(.horizontal, size == .compact ? 4 : 6)
                    .padding(.vertical, 4)
            }
            .background(
                RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                    .fill(focused ? FluidTone.card
                          : (isActive ? FluidTone.muted.opacity(0.5) : .clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                            .strokeBorder(
                                error != nil && (focused || isActive)
                                    ? FluidTone.destructive.opacity(0.5)
                                    : (focused || isActive) ? FluidTone.border : .clear,
                                lineWidth: 1)
                    )
            )
            .onTapGesture { focused = true }
            .animation(FluidSpring.fast, value: isActive)
            .animation(FluidSpring.fast, value: focused)

            if let error {
                Text(error)
                    .font(.system(size: size == .compact ? 11 : 12, weight: .medium))
                    .foregroundStyle(FluidTone.destructive)
                    .padding(.leading, size == .compact ? 8 : 10)
            }
        }
        .modifier(FluidInputItemLike(index: index))
        .onHover { if index == nil { selfHovered = $0 } }
    }
}

/// `.fluidItem` can't be applied conditionally — same trick FluidInput's
/// own modifier does.
private struct FluidInputItemLike: ViewModifier {
    var index: Int?
    func body(content: Content) -> some View {
        if let index { content.fluidItem(index) } else { content }
    }
}

/// The seven-day pick — one toggling pill per weekday, Calendar-ordered.
private struct WeekdayPicker: View {
    @Binding var days: Set<Int>
    private let names = Calendar.current.shortWeekdaySymbols

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(String(names[day - 1].prefix(3)))
                        .font(.system(size: 11, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? FluidTone.foreground : FluidTone.mutedForeground)
                        .frame(width: 34, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(on ? FluidTone.active : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(on ? FluidTone.border : FluidTone.border.opacity(0.5),
                                              lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(names[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// The routine's name, inline-editable like the chat's title — click to
/// rename; the window's titleEscape rung reverts on Esc just the same.
private struct RoutineNameField: View {
    var routine: Routine
    @ObservedObject private var routines = Routines.shared
    @State private var editing = false
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Routine", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FluidTone.foreground)
                    .focused($focused)
                    .frame(maxWidth: 380)
                    .onSubmit(commit)
                    .onKeyPress(.escape) {
                        editing = false
                        return .handled
                    }
                    .onChange(of: focused) { _, on in
                        if !on { commit() }
                    }
            } else {
                Button {
                    text = routine.name
                    editing = true
                    focused = true
                } label: {
                    HStack(spacing: 6) {
                        Text(routine.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(FluidTone.foreground)
                        if hovering {
                            Image(systemName: "pencil")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(FluidTone.mutedForeground)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(hovering ? FluidTone.hover : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.08), value: hovering)
            }
        }
        .onChange(of: editing) { _, on in armEscape(on) }
        .onAppear { armEscape(editing) }
        .onDisappear { armEscape(false) }
    }

    private func commit() {
        // The blur fires after Esc has already set editing false — the
        // revert stands down instead of saving the dropped name.
        guard editing else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != routine.name {
            var copy = routine
            copy.name = name
            routines.save(copy)
        }
        editing = false
    }

    /// Same slot the chat's title uses — only one title field shows at a
    /// time, so Esc's revert rung is shared, not stacked.
    private func armEscape(_ on: Bool) {
        if on {
            let editing = $editing
            AskWindow.titleEscape = {
                editing.wrappedValue = false
                return true
            }
        } else if AskWindow.titleEscape != nil {
            AskWindow.titleEscape = nil
        }
    }
}
