import AppKit
import Foundation
import UserNotifications

// Routines — Ask runs that happen without anyone asking. A routine is a
// prompt, a schedule and a leash; a run is one execution of it, carrying
// an AskChat so the turn's transcript renders with the same views a
// chat's does. The whole design is Runtime/ask/design/automation-backend.md.
//
// The one structural decision that shapes the file: runs get their own
// engine seat — a second Harness with its own hidden webview — rather
// than a queue on the interactive one. A user send mid-run calls
// harness.js kill(current) inside its page; sharing the seat would let a
// typed message murder a scheduled job. One routine run at a time: a
// second due routine queues FIFO behind the seat. Nothing here touches
// Mind — events fold through AskFold into the run's own chat, parked
// cards land on the run's waitingApprovals, and the interactive chat
// never hears a routine turn happen.

// MARK: - the models

/// How a run came to be — shown in history and on the card.
enum RoutineTrigger: String, Codable {
    case scheduled, manual, retry
    var label: String {
        switch self {
        case .scheduled: "scheduled"
        case .manual: "run now"
        case .retry: "retry"
        }
    }
}

/// A run's place in its lifecycle: queued → running ⇄ waiting → terminal.
/// `waiting` is the parked state — a card or a question is out, the turn
/// itself is still alive behind it. `scheduled` is deliberately absent:
/// it's a routine-level display derived from nextRunAt, not a run's.
enum RunState: String, Codable {
    case queued, running, waiting, succeeded, failed, cancelled
    var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

/// When a routine fires. The structured frequencies cover the shapes a
/// person actually picks; `custom` is a 5-field cron for the rest
/// (minute hour day-of-month month day-of-week — * , - / and lists).
struct RoutineSchedule: Codable, Equatable {
    enum Frequency: String, Codable, CaseIterable {
        case hourly, daily, weekdays, weekly, custom
        var label: String {
            switch self {
            case .hourly: "Hourly"
            case .daily: "Daily"
            case .weekdays: "Weekdays"
            case .weekly: "Weekly"
            case .custom: "Custom"
            }
        }
    }
    var frequency: Frequency = .daily
    /// Every N hours/days — 1 is the usual.
    var interval = 1
    /// Weekly's days — Calendar.weekday (1 is Sunday).
    var weekdays: Set<Int> = []
    /// The wall-clock it fires at, in the routine's timezone.
    var hour = 9, minute = 0
    /// The 5-field cron a custom frequency carries.
    var cron: String?

    /// The next fire strictly after `date` — pure, so a test can feed it
    /// clocks it likes. A wall time that doesn't exist (a 2:30 AM that DST
    /// skipped) falls forward to the next valid one — the day isn't lost.
    func next(after date: Date, tz: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let every = max(1, interval)
        let tick = { (day: Date) -> Date? in
            cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }
        switch frequency {
        case .hourly:
            // :mm past each Nth hour of the day — 0, N, 2N… on the clock
            // grid, so "every 3 hours" fires at honest clock times.
            var day = cal.startOfDay(for: date)
            for _ in 0..<370 {
                for h in stride(from: 0, to: 24, by: every) {
                    if let t = cal.date(bySettingHour: h, minute: minute, second: 0, of: day),
                       t > date { return t }
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
                day = next
            }
            return nil
        case .daily:
            // Stepping from `after`'s day by N anchors the cadence to the
            // last fire: next(after: firedAt) lands exactly N days out.
            var day = cal.startOfDay(for: date)
            for _ in 0..<(every * 400) {
                if let t = tick(day), t > date { return t }
                guard let next = cal.date(byAdding: .day, value: every, to: day) else { return nil }
                day = next
            }
            return nil
        case .weekdays:
            return nextDay(in: [2, 3, 4, 5, 6], after: date, cal: cal)
        case .weekly:
            guard !weekdays.isEmpty else { return nil }
            return nextDay(in: weekdays, after: date, cal: cal)
        case .custom:
            guard let cron, let spec = RoutineCron(cron) else { return nil }
            return spec.next(after: date, cal: cal)
        }
    }

    private func nextDay(in days: Set<Int>, after date: Date, cal: Calendar) -> Date? {
        var day = cal.startOfDay(for: date)
        for _ in 0..<370 {
            if days.contains(cal.component(.weekday, from: day)),
               let t = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day),
               t > date { return t }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }
}

/// A 5-field cron, parsed once — each field a Set over its range. The
/// day-of-month/day-of-week pair keeps cron's OR: when both are
/// restricted, either matching is enough (Vixie's rule, kept).
struct RoutineCron {
    var minutes: Set<Int>
    var hours: Set<Int>
    var dom: Set<Int>
    var months: Set<Int>
    var dow: Set<Int>
    /// Whether dom/dow carried a real restriction — `*` is "always" and
    /// drops out of the OR rather than weakening it.
    var domFree = true
    var dowFree = true

    init?(_ text: String) {
        let fields = text.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 5,
              let minutes = RoutineCron.field(fields[0], range: 0...59),
              let hours = RoutineCron.field(fields[1], range: 0...23),
              let dom = RoutineCron.field(fields[2], range: 1...31),
              let months = RoutineCron.field(fields[3], range: 1...12),
              let dow = RoutineCron.field(fields[4], range: 0...7)
        else { return nil }
        self.minutes = minutes
        self.hours = hours
        self.dom = dom
        self.months = months
        // Cron's dow is 0-6 (or 7) with Sunday at both ends; Calendar's
        // weekday is 1-7 with Sunday at 1 — fold 0/7 into it.
        self.dow = Set(dow.map { $0 == 0 || $0 == 7 ? 1 : $0 + 1 })
        domFree = !fields[2].contains(where: { $0.isNumber || $0 == "-" }) && fields[2] == "*"
        dowFree = fields[4] == "*"
    }

    /// One field — `*`, `*/n`, `a`, `a-b`, `a-b/n`, comma lists of any.
    private static func field(_ field: Substring, range: ClosedRange<Int>) -> Set<Int>? {
        var out: Set<Int> = []
        for part in field.split(separator: ",") {
            let step: Int
            let span: Substring
            if let slash = part.firstIndex(of: "/") {
                guard let n = Int(part[part.index(after: slash)...]), n > 0 else { return nil }
                step = n
                span = part[..<slash]
            } else {
                step = 1
                span = part
            }
            if span == "*" {
                out.formUnion(stride(from: range.lowerBound, through: range.upperBound, by: step))
            } else if let dash = span.firstIndex(of: "-") {
                guard let lo = Int(span[..<dash]),
                      let hi = Int(span[span.index(after: dash)...]),
                      range.contains(lo), range.contains(hi), lo <= hi else { return nil }
                out.formUnion(stride(from: lo, through: hi, by: step))
            } else if let n = Int(span), range.contains(n) {
                out.insert(n)
            } else {
                return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    /// The next minute-boundary the spec matches, strictly after `date`.
    /// Day-first iteration: a non-matching day skips 1440 candidates.
    func next(after date: Date, cal: Calendar) -> Date? {
        var day = cal.startOfDay(for: date)
        for _ in 0..<370 {
            let comps = cal.dateComponents([.month, .day, .weekday], from: day)
            guard let month = comps.month, let dom = comps.day, let weekday = comps.weekday else { return nil }
            let dayHit = domFree && dowFree
                || (domFree ? self.dow.contains(weekday)
                   : dowFree ? self.dom.contains(dom)
                   : self.dom.contains(dom) || self.dow.contains(weekday))
            if months.contains(month), dayHit {
                for h in 0..<24 where hours.contains(h) {
                    for m in 0..<60 where minutes.contains(m) {
                        if let t = cal.date(bySettingHour: h, minute: m, second: 0, of: day),
                           t > date { return t }
                    }
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }
}

/// A routine: the prompt, the schedule, the leash. `model` nil means the
/// chat's saved pick at dispatch; `mode` is the session's guard level —
/// `.guard` by default, `.read` for digest-shaped jobs, `.full` only by
/// the user's own pick. `nextRunAt`/`lastRunID` are the schedule's state.
struct Routine: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var prompt: String
    var enabled = true
    var schedule = RoutineSchedule()
    /// IANA id — "America/New_York" — so a routine made in one zone fires
    /// at the wall-clock the person meant when they're elsewhere.
    var timezone: String = TimeZone.current.identifier
    var model: String?
    var mode: AskMode = .guard
    /// The run's wall-clock ceiling while it's working — waiting on a
    /// parked card suspends it; a question asked isn't laziness.
    var timeoutSeconds: Int = 1800
    /// nil follows the global ask.routines.notify.
    var notify: Bool?
    var createdAt = Date()
    var updatedAt = Date()
    var nextRunAt: Date?
    var lastRunID: UUID?

    var timeZone: TimeZone { TimeZone(identifier: timezone) ?? .current }

    /// Old files decode with the fields they have; everything newer than
    /// them reads its default, and nothing missing is fatal.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Routine"
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        schedule = try c.decodeIfPresent(RoutineSchedule.self, forKey: .schedule) ?? RoutineSchedule()
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? TimeZone.current.identifier
        model = try c.decodeIfPresent(String.self, forKey: .model)
        mode = try c.decodeIfPresent(AskMode.self, forKey: .mode) ?? .guard
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 1800
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        nextRunAt = try c.decodeIfPresent(Date.self, forKey: .nextRunAt)
        lastRunID = try c.decodeIfPresent(UUID.self, forKey: .lastRunID)
    }

    init(id: UUID = UUID(), name: String, prompt: String,
         schedule: RoutineSchedule = RoutineSchedule()) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
    }
}

/// One execution. `chat` is the transcript — embedded whole so AskTurns,
/// TurnView and the worked-for accordion read it exactly as a chat's.
/// `waitingApprovals`/`waitingQuestion` are the run's own parked asks —
/// Mind's rail never sees them. `acknowledged` is whether a finished run
/// has been looked at, feeding the badge.
struct RoutineRun: Codable, Identifiable, Equatable {
    var id = UUID()
    var routine: UUID
    var trigger: RoutineTrigger = .scheduled
    var state: RunState = .queued
    var chat: AskChat
    var queuedAt = Date()
    var startedAt: Date?
    var finishedAt: Date?
    var error: String?
    var acknowledged = false
    var waitingApprovals: [AskApproval] = []
    var waitingQuestion: AskQuestion?
    var retryOf: UUID?
    /// The live turn's status line — "reading the page" — transient.
    var activity = ""

    /// What the run is parked on — several cards can stack, and either
    /// kind holds the `.waiting` state.
    var waiting: Bool { !waitingApprovals.isEmpty || waitingQuestion != nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        routine = try c.decode(UUID.self, forKey: .routine)
        trigger = try c.decodeIfPresent(RoutineTrigger.self, forKey: .trigger) ?? .scheduled
        state = try c.decodeIfPresent(RunState.self, forKey: .state) ?? .queued
        chat = try c.decode(AskChat.self, forKey: .chat)
        queuedAt = try c.decodeIfPresent(Date.self, forKey: .queuedAt) ?? Date()
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        acknowledged = try c.decodeIfPresent(Bool.self, forKey: .acknowledged) ?? false
        waitingApprovals = try c.decodeIfPresent([AskApproval].self, forKey: .waitingApprovals) ?? []
        waitingQuestion = try c.decodeIfPresent(AskQuestion.self, forKey: .waitingQuestion)
        retryOf = try c.decodeIfPresent(UUID.self, forKey: .retryOf)
        activity = try c.decodeIfPresent(String.self, forKey: .activity) ?? ""
    }

    init(routine: UUID, trigger: RoutineTrigger, chat: AskChat, retryOf: UUID? = nil) {
        self.routine = routine
        self.trigger = trigger
        self.chat = chat
        self.retryOf = retryOf
    }
}

// MARK: - where routines live

/// One JSON per routine under routines/, one per run under runs/ — the
/// AskStore conventions verbatim: atomic writes, quarantined undecodables,
/// and run chats can never surface in the chat list because they never
/// share its folder.
enum RoutineStore {
    private static var folder: URL { Store.file("routines") }
    private static var runsFolder: URL { Store.file("runs") }

    static func list() -> [Routine] {
        readAll(folder) as [Routine]
    }

    static func runs() -> [RoutineRun] {
        readAll(runsFolder) as [RoutineRun]
    }

    private static func readAll<T: Decodable>(_ url: URL) -> [T] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return names.compactMap { name -> T? in
            guard name.hasSuffix(".json") else { return nil }
            let file = url.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file),
                  let item = try? JSONDecoder().decode(T.self, from: data)
            else {
                Store.quarantine(file)
                return nil
            }
            return item
        }
    }

    static func save(_ routine: Routine) {
        save(routine, to: folder, name: routine.id.uuidString)
    }

    static func save(_ run: RoutineRun) {
        save(run, to: runsFolder, name: run.id.uuidString)
    }

    private static func save<T: Encodable>(_ item: T, to folder: URL, name: String) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("\(name).json"),
                                                 options: .atomic)
        } catch {}
    }

    static func drop(_ routine: UUID) {
        try? FileManager.default.removeItem(
            at: folder.appendingPathComponent("\(routine.uuidString).json"))
    }

    static func dropRun(_ run: UUID) {
        try? FileManager.default.removeItem(
            at: runsFolder.appendingPathComponent("\(run.uuidString).json"))
    }
}

// MARK: - the controller

/// The automation engine: the schedule clock, the one-run seat, the FIFO
/// queue, and every run's books. Created with the browser (Browser.init
/// starts it); the seat's webview boots lazily on the first dispatch.
@MainActor
final class Routines: ObservableObject {
    static let shared = Routines()

    /// Every routine, oldest first — the list order the page draws.
    @Published private(set) var routines: [Routine] = []
    /// Runs by routine id, newest first — the history the page draws.
    @Published private(set) var runs: [UUID: [RoutineRun]] = [:]

    /// The dedicated engine seat (automation-backend §3): one routine run
    /// at a time, never the interactive harness — a user send can't kill
    /// what it can't reach.
    private let seat = Harness(registering: false)
    /// Run ids waiting on the seat, in order — scheduled runs append,
    /// manual/retry jump ahead of them.
    private var queue: [UUID] = []
    /// The run on the seat right now, if any — and which routine's it is,
    /// kept separately so endRun still fires if the run's record was
    /// deleted mid-flight.
    private var liveID: UUID?
    private var liveRoutineID: UUID?
    /// Each live run's fold set, by run id — AskFold's committed-suffix
    /// bookkeeping, Mind's runFolds counterpart.
    private var folds: [UUID: Set<UUID>] = [:]
    /// Runs the seat is flushing out (stop/timeout asked, .done pending) —
    /// what their terminal state should be when it lands.
    private var endings: [UUID: (state: RunState, error: String?)] = [:]
    /// The 30-second scheduler — a repeating scan, immune to missed
    /// one-shot timers and relaunches by construction.
    private var timer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?
    /// The run's timeout clock — a Task sleeping to the deadline, paused
    /// while the run is .waiting: parked asks are first-class, and a
    /// deny-on-timer would be a lie.
    private var clockTask: Task<Void, Never>?
    private var clockRemaining: TimeInterval?
    private var started = false

    /// How many runs each routine keeps — ask.routines.keep, default 20.
    private var keep: Int {
        let n = Store.settings.integer(forKey: "ask.routines.keep")
        return n > 0 ? n : 20
    }

    /// The run on the seat, for the approval sink.
    private var liveRun: RoutineRun? {
        liveID.flatMap { fetch($0) }
    }

    /// Unfinished business for the badge: live and parked runs, plus
    /// failures nobody looked at — successes and stops stay quiet, an
    /// overnight green run is not the thing the badge exists to say.
    var badge: Int {
        runs.values.joined().reduce(0) {
            $0 + ($1.state == .running || $1.state == .waiting
                  || ($1.state == .failed && !$1.acknowledged) ? 1 : 0)
        }
    }

    func runs(of routine: Routine) -> [RoutineRun] { runs[routine.id] ?? [] }
    func fetch(_ id: UUID) -> RoutineRun? {
        runs.values.joined().first { $0.id == id }
    }
    func routine(_ id: UUID) -> Routine? { routines.first { $0.id == id } }
    /// The routine's latest run — the row's status line.
    func lastRun(of routine: Routine) -> RoutineRun? {
        if let id = routine.lastRunID, let hit = runs[routine.id]?.first(where: { $0.id == id }) {
            return hit
        }
        return runs[routine.id]?.first
    }

    // MARK: - lifetime

    /// Called once from Browser.init after AskRuntime.drive exists:
    /// loads state, sweeps runs the last launch abandoned, wires the
    /// Drive sinks, and arms the clock. Test worlds get the same path.
    func start() {
        guard !started else { return }
        started = true
        routines = RoutineStore.list().sorted { $0.createdAt < $1.createdAt }
        var all = RoutineStore.runs()
        // Recovery sweep: a run persisted mid-flight can't pick up — its
        // engine is gone and its seat cold. It ends failed, honestly,
        // rather than wearing "running" forever.
        for i in all.indices where all[i].state == .running || all[i].state == .waiting
                                   || all[i].state == .queued {
            all[i].state = .failed
            all[i].error = "the app stopped mid-run"
            all[i].finishedAt = Date()
            RoutineStore.save(all[i])
        }
        regroup(all)
        let now = Date()
        for i in routines.indices {
            routines[i].nextRunAt = routines[i].enabled
                ? routines[i].schedule.next(after: now, tz: routines[i].timeZone) : nil
            RoutineStore.save(routines[i])
        }
        if let drive = AskRuntime.drive as? Drive {
            drive.approvalSink = { [weak self] card, origin in self?.park(card, from: origin) }
            drive.routineName = { [weak self] id in self?.routine(id)?.name }
        }
        let tick = DispatchSource.makeTimerSource(queue: .main)
        tick.schedule(deadline: .now() + 30, repeating: 30)
        tick.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        tick.resume()
        timer = tick
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        #if DEBUG
        if Store.testing && Store.settings.bool(forKey: "ask.demoroutine") {
            Store.settings.set(false, forKey: "ask.demoroutine")
            demoRoutine()
        }
        #endif
        scan()
    }

    private func regroup(_ all: [RoutineRun]) {
        var grouped: [UUID: [RoutineRun]] = [:]
        for run in all { grouped[run.routine, default: []].append(run) }
        for key in grouped.keys {
            grouped[key]?.sort { ($0.queuedAt, $0.id.uuidString) > ($1.queuedAt, $1.id.uuidString) }
        }
        runs = grouped
    }

    /// The scheduler's scan — anything whose time passed fires once, and
    /// nextRunAt recomputes strictly after now so a week closed is one
    /// catch-up run, not N (automation-backend §2).
    private func scan() {
        guard started else { return }
        let now = Date()
        var fired = false
        for i in routines.indices where routines[i].enabled {
            guard let due = routines[i].nextRunAt, due <= now else { continue }
            enqueue(routines[i], trigger: .scheduled)
            routines[i].nextRunAt = routines[i].schedule.next(after: now, tz: routines[i].timeZone)
            RoutineStore.save(routines[i])
            fired = true
        }
        if fired { objectWillChange.send() }
        pump()
    }

    // MARK: - the queue

    /// A run enters the world with its transcript started — the prompt is
    /// already its `.you` message — so the queue's own rows have content.
    @discardableResult
    private func enqueue(_ routine: Routine, trigger: RoutineTrigger,
                         front: Bool = false, retryOf: UUID? = nil) -> RoutineRun {
        var chat = AskChat(id: UUID(), title: routine.name)
        chat.model = routine.model ?? Mind.savedModel().id
        chat.mode = routine.mode
        chat.messages.append(AskMessage(role: .you, text: routine.prompt))
        var run = RoutineRun(routine: routine.id, trigger: trigger, chat: chat, retryOf: retryOf)
        if trigger == .retry { run.acknowledged = true }
        runs[routine.id, default: []].insert(run, at: 0)
        if front {
            // Manual and retry jump ahead of anything scheduled — the
            // person asked for this one by name.
            let at = queue.firstIndex(where: { id in
                fetch(id).map { $0.trigger == .scheduled } ?? false
            }) ?? queue.count
            queue.insert(run.id, at: at)
        } else {
            queue.append(run.id)
        }
        RoutineStore.save(run)
        pump()
        return run
    }

    /// Hand the seat its next run if it's idle.
    private func pump() {
        guard liveID == nil else { return }
        while let id = queue.first {
            queue.removeFirst()
            guard let run = fetch(id), run.state == .queued,
                  let routine = routine(run.routine) else { continue }
            dispatch(run, routine: routine)
            return
        }
    }

    private func dispatch(_ run: RoutineRun, routine: Routine) {
        liveID = run.id
        liveRoutineID = routine.id
        guard let (rID, i) = locate(run.id) else { liveID = nil; liveRoutineID = nil; return }
        var live = runs[rID, default: []][i]
        live.state = .running
        live.startedAt = Date()
        live.chat.turn = UUID()
        live.chat.turnStartedAt = Date()
        runs[rID, default: []][i] = live
        RoutineStore.save(live)
        seat.origin = .routine(routine.id)
        seat.sink = { [weak self] event in self?.hear(event, into: run.id) }
        seat.onAsk = { [weak self] question, options in
            self?.pose(question, options: options, into: run.id)
        }
        (AskRuntime.drive as? Drive)?.setMode(routine.mode, for: .routine(routine.id))
        armClock(seconds: TimeInterval(routine.timeoutSeconds), for: run.id)
        seat.run(AskJob(chat: live.chat, tabs: [], attachments: [], text: routine.prompt))
    }

    // MARK: - run events

    private func locate(_ runID: UUID) -> (UUID, Int)? {
        for (rID, list) in runs {
            if let i = list.firstIndex(where: { $0.id == runID }) { return (rID, i) }
        }
        return nil
    }

    /// An event the seat heard, folded into its run's chat. Only the live
    /// run's stream lands — a stale turn's tail is already dropped by the
    /// seat's stamp, and anything else is nobody's business.
    private func hear(_ event: AskEvent, into runID: UUID) {
        guard liveID == runID, let (rID, i) = locate(runID) else { return }
        var run = runs[rID, default: []][i]
        if case .activity(_, let doing) = event {
            run.activity = doing
            runs[rID, default: []][i] = run
            return
        }
        AskFold.apply(event, to: &run.chat, folds: &folds[runID, default: []])
        runs[rID, default: []][i] = run
        switch event {
        case .message:
            // The canonical record lands — worth persisting; deltas and
            // tool ticks are in-memory until the message/done makes them
            // part of it (Mind's own cadence).
            RoutineStore.save(run)
        case .done(_, let error):
            settle(runID, error: error)
        default:
            break
        }
    }

    /// A parked approval lands on the run, not the rail. The card's chat
    /// is the run's own transcript, so the detail view resolves it without
    /// Mind.chats ever being asked.
    private func park(_ card: AskApproval, from origin: DriveOrigin) {
        guard case .routine(let routineID) = origin,
              let live = liveRun, live.routine == routineID, let runID = liveID
        else {
            // A card with no live run to hold it can't be settled later —
            // deny it now rather than park a promise nobody answers.
            (AskRuntime.drive as? Drive)?.settleApproval(card.id, .deny)
            return
        }
        var stamped = card
        stamped.chat = live.chat.id
        mutate(runID) { run in
            run.waitingApprovals.append(stamped)
            run.state = .waiting
        }
        suspendClock()
        nudge(runID)
    }

    /// A parked ask.user — the model asking a person from inside a run.
    /// No 300-second clock: a scheduled job asking at 3 AM gets its answer
    /// whenever the person comes to it. The seat's one-question rule is
    /// the harness's own (a second ask gets "busy").
    private func pose(_ text: String, options: [String], into runID: UUID) {
        mutate(runID) { run in
            run.waitingQuestion = AskQuestion(chat: run.chat.id, text: text, options: options)
            run.state = .waiting
        }
        suspendClock()
        nudge(runID)
    }

    /// A parked ask answered — the shared tail: the waiting seat clears,
    /// and what the run becomes next depends on whether it's still the
    /// seat's live run. A live one goes back to running (and the clock
    /// resumes); one that isn't live — a demo's planted card — closes
    /// cancelled, since there is no turn left to hand the answer to.
    private func unpark(_ runID: UUID, _ edit: (inout RoutineRun) -> Void) {
        mutate(runID) { live in
            edit(&live)
            if live.state == .waiting, !live.waiting {
                if self.liveID == runID {
                    live.state = .running
                } else {
                    live.state = .cancelled
                    live.finishedAt = Date()
                }
            }
        }
        if let fresh = fetch(runID) { RoutineStore.save(fresh) }
        if liveID == runID, !(fetch(runID)?.waiting ?? false) {
            resumeClock(for: runID)
        }
    }

    func removeApproval(_ id: UUID) {
        guard let runID = liveID else { return }
        unpark(runID) { $0.waitingApprovals.removeAll { $0.id == id } }
    }

    /// The verdict on a parked card — settles the op in Drive and leaves
    /// the audit line in the run's transcript, the same note Mind.resolve
    /// writes for a chat.
    func resolve(_ run: RoutineRun, _ approval: AskApproval, _ verdict: ApprovalVerdict) {
        seat.settleApproval(approval.id, verdict)
        unpark(run.id) { live in
            live.waitingApprovals.removeAll { $0.id == approval.id }
            let what = approval.host.map { "\(approval.op) on \($0)" } ?? approval.op
            let text = switch verdict {
            case .allow: "✓ allowed \(what)"
            case .deny: "✗ denied \(what)"
            case .always: "✓ allowed \(what)"
            }
            live.chat.messages.append(AskMessage(role: .note, text: text, approval: approval))
        }
    }

    /// The parked question answered — the held tool promise resolves.
    func answer(_ run: RoutineRun, _ text: String) {
        seat.resolveAsk(["answer": text])
        unpark(run.id) { $0.waitingQuestion = nil }
    }

    /// The question let go — the model makes its own call and says what
    /// it assumed.
    func pass(_ run: RoutineRun) {
        seat.resolveAsk(["declined": "dismissed"])
        unpark(run.id) { $0.waitingQuestion = nil }
    }

    // MARK: - control

    /// "Run now" — a manual trigger that jumps the scheduled queue.
    @discardableResult
    func runNow(_ routine: Routine) -> RoutineRun {
        enqueue(routine, trigger: .manual, front: true)
    }

    /// A finished run again — the front of the queue, marked a retry so
    /// history reads it honestly.
    func retry(_ run: RoutineRun) {
        guard let routine = routine(run.routine) else { return }
        enqueue(routine, trigger: .retry, front: true, retryOf: run.id)
    }

    /// Stop a run wherever it is: queued ones come out of line cancelled;
    /// the live one is killed at the seat and its trailing .done seals it
    /// — with a hard ceiling in case the page never answers. The record,
    /// not the caller's snapshot, decides which branch — a queued-looking
    /// run tapped right after dispatch is already live.
    func stop(_ run: RoutineRun) {
        if fetch(run.id)?.state == .queued || queue.contains(run.id) {
            queue.removeAll { $0 == run.id }
            mutate(run.id) {
                $0.state = .cancelled
                $0.finishedAt = Date()
            }
            RoutineStore.save(fetch(run.id) ?? run)
            return
        }
        guard liveID == run.id else { return }
        endings[run.id] = (.cancelled, nil)
        seat.stop()
        armFailSafe(for: run.id)
    }

    /// A finished run the person has seen — the badge lets it go.
    func acknowledge(_ run: RoutineRun) {
        mutate(run.id) { $0.acknowledged = true }
        if let fresh = fetch(run.id) { RoutineStore.save(fresh) }
    }

    /// A run out of the history — the chat file goes with it.
    func removeRun(_ run: RoutineRun) {
        if run.state == .queued { queue.removeAll { $0 == run.id } }
        if liveID == run.id { stop(run) }
        mutate(run.id) { $0.state = $0.state.isTerminal ? $0.state : .cancelled }
        if let (rID, i) = locate(run.id) {
            var list = runs[rID] ?? []
            list.remove(at: i)
            runs[rID] = list
        }
        RoutineStore.dropRun(run.id)
    }

    // MARK: - routines CRUD

    /// Save a routine — the schedule's own recompute point: enabled means
    /// a fresh nextRunAt strictly after now, disabled clears it.
    func save(_ routine: Routine) {
        guard let at = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        var copy = routine
        // Run-derived facts belong to the record, not the editor — a form
        // left open while a run landed must not write its stale
        // lastRunID back over the truth.
        copy.lastRunID = routines[at].lastRunID
        copy.updatedAt = Date()
        copy.nextRunAt = copy.enabled
            ? copy.schedule.next(after: Date(), tz: copy.timeZone) : nil
        routines[at] = copy
        RoutineStore.save(copy)
        scan()
    }

    /// A new routine — the same save path, plus its first schedule.
    @discardableResult
    func add(_ routine: Routine) -> Routine {
        var copy = routine
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.nextRunAt = copy.enabled
            ? copy.schedule.next(after: Date(), tz: copy.timeZone) : nil
        routines.append(copy)
        RoutineStore.save(copy)
        return copy
    }

    /// Delete a routine and its history — its queued runs cancel, a live
    /// one is stopped the honest way and settles cancelled.
    func remove(_ routine: Routine) {
        for run in runs[routine.id] ?? [] {
            if run.state == .queued { queue.removeAll { $0 == run.id } }
            if liveID == run.id { stop(run) }
            RoutineStore.dropRun(run.id)
        }
        runs[routine.id] = nil
        routines.removeAll { $0.id == routine.id }
        RoutineStore.drop(routine.id)
        pump()
    }

    // MARK: - settling

    /// The trailing .done — or the failsafe for a page that died — closes
    /// the run's books. Seat cleanup comes first so a run deleted
    /// mid-flight still frees the seat, ends the session and pumps the
    /// queue; the record's own bookkeeping follows when it's still there.
    private func settle(_ runID: UUID, error: String?) {
        guard liveID == runID else { return }
        liveID = nil
        let seatRoutine = liveRoutineID
        liveRoutineID = nil
        clockTask?.cancel()
        clockTask = nil
        clockRemaining = nil
        clockDeadline = nil
        let ending = endings.removeValue(forKey: runID)
        folds[runID] = nil
        if let (rID, i) = locate(runID) {
            var live = runs[rID, default: []][i]
            if !live.state.isTerminal {
                if let ending {
                    live.state = ending.state
                    live.error = ending.error ?? error
                } else {
                    live.state = error == nil ? .succeeded : .failed
                    live.error = error
                }
            }
            live.finishedAt = Date()
            live.waitingApprovals = []
            live.waitingQuestion = nil
            live.activity = ""
            runs[rID, default: []][i] = live
            RoutineStore.save(live)
            if let at = routines.firstIndex(where: { $0.id == rID }) {
                routines[at].lastRunID = live.id
                if routines[at].enabled {
                    routines[at].nextRunAt = routines[at].schedule.next(
                        after: Date(), tz: routines[at].timeZone)
                }
                RoutineStore.save(routines[at])
            }
            prune(rID)
            notify(live, routine: routine(rID))
        }
        // The session's run-scoped state ends; the routine's remembered
        // always-rules and leash are the routine's own, kept for next time.
        if let seatRoutine {
            (AskRuntime.drive as? Drive)?.endRun(.routine(seatRoutine))
        }
        pump()
    }

    /// The page never answered a stop — close the run anyway rather than
    /// wear "running" on a dead turn.
    private func armFailSafe(for runID: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.liveID == runID else { return }
            let ending = self.endings[runID] ?? (.failed, "the run never settled")
            self.endings[runID] = ending
            self.settle(runID, error: ending.error)
        }
    }

    /// The timeout clock — arms at dispatch, sleeps to the deadline,
    /// suspends on .waiting and resumes on the answer. A run that only
    /// waits is never punished for patience.
    private func armClock(seconds: TimeInterval, for runID: UUID) {
        clockTask?.cancel()
        clockDeadline = Date().addingTimeInterval(seconds)
        clockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            guard self.liveID == runID else { return }
            self.endings[runID] = (.failed, "timed out")
            self.seat.stop()
            self.armFailSafe(for: runID)
        }
    }

    private func suspendClock() {
        guard clockTask != nil else { return }
        // The remaining span is what a resume re-arms — parking freezes
        // the clock rather than forfeiting or resetting it.
        clockRemaining = remainingOfClock()
        clockTask?.cancel()
        clockTask = nil
    }

    private func resumeClock(for runID: UUID) {
        guard clockTask == nil, let remaining = clockRemaining, remaining > 0 else { return }
        clockRemaining = nil
        armClock(seconds: remaining, for: runID)
    }

    private var clockDeadline: Date?
    private func remainingOfClock() -> TimeInterval {
        max(1, (clockDeadline ?? Date()).timeIntervalSinceNow)
    }

    private func mutate(_ runID: UUID, _ edit: (inout RoutineRun) -> Void) {
        guard let (rID, i) = locate(runID) else { return }
        var run = runs[rID, default: []][i]
        edit(&run)
        runs[rID, default: []][i] = run
    }

    /// Oldest-first prune to the keep limit, on each terminal save.
    private func prune(_ routineID: UUID) {
        var list = runs[routineID] ?? []
        let overflow = list.count - keep
        guard overflow > 0 else { return }
        // Live runs are never pruned — drop the oldest finished ones.
        let dead = list.enumerated().filter { $0.element.state.isTerminal }
        for (index, run) in dead.reversed().prefix(overflow) {
            list.remove(at: index)
            RoutineStore.dropRun(run.id)
        }
        runs[routineID] = list
    }

    /// A notification when a run wants attention or ends badly — the
    /// routine's own notify pick, else the global ask.routines.notify.
    private func notify(_ run: RoutineRun, routine: Routine?) {
        let on = routine?.notify ?? Store.settings.bool(forKey: "ask.routines.notify")
        guard on else { return }
        let title = routine?.name ?? "Routine"
        let body: String
        switch run.state {
        case .failed: body = run.error.map { "Failed — \($0)" } ?? "Failed"
        case .waiting: body = "Waiting for your answer"
        default: return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: run.id.uuidString,
                                         content: content, trigger: nil)) { _ in }
    }

    /// A waiting run also notifies — parked asks are attention.
    private func nudge(_ runID: UUID) {
        guard let run = fetch(runID), let routine = routine(run.routine) else { return }
        notify(run, routine: routine)
    }

    // MARK: - probe levers

    #if DEBUG
    /// `bench routine demo` (or ask.demoroutine at launch, both on the
    /// probe suite) — seeds one echo-model routine (a real end-to-end run
    /// takes no keys) plus fabricated history: a succeeded run and a
    /// waiting one with a question parked on it, so the page's whole
    /// state ladder renders on command.
    func demoRoutine() {
        guard Store.testing else { return }

        var routine = Routine(name: "Demo digest", prompt: "Summarize today's news",
                              schedule: RoutineSchedule(frequency: .daily))
        routine.model = "echo/echo"
        routine.mode = .guard
        let added = add(routine)

        // A finished run with a real transcript shape — you, worked-for
        // accordion, answer — so history rows render truthfully.
        var doneChat = AskChat(title: added.name)
        doneChat.model = "echo/echo"
        doneChat.messages = [
            AskMessage(role: .you, text: added.prompt),
            AskMessage(role: .agent,
                       text: "Echo: Summarize today's news\n\n(done run — the transcript is the demo)",
                       blocks: [
                           .text("Echo: Summarize today's news"),
                           .tool(AskMessage.Tool(id: "demo-t", name: "page.text",
                                                 args: #"{"tab":"abc123"}"#, result: #"{"chars":412}"#)),
                           .text("(done run — the transcript is the demo)"),
                       ],
                       workedFor: 41, model: "echo/echo"),
        ]
        var doneRun = RoutineRun(routine: added.id, trigger: .scheduled, chat: doneChat)
        doneRun.state = .succeeded
        doneRun.queuedAt = Date().addingTimeInterval(-86400)
        doneRun.startedAt = doneRun.queuedAt
        doneRun.finishedAt = doneRun.queuedAt.addingTimeInterval(41)
        runs[added.id, default: []].append(doneRun)
        RoutineStore.save(doneRun)

        var waitingChat = AskChat(title: added.name)
        waitingChat.model = "echo/echo"
        waitingChat.messages = [
            AskMessage(role: .you, text: added.prompt),
            AskMessage(role: .agent,
                       text: "I need to know which edition you want.",
                       blocks: [
                           .text("I need to know which edition you want."),
                           .tool(AskMessage.Tool(id: "demo-q", name: "ask_user",
                                                 args: #"{"question":"Morning or evening edition?"}"#)),
                       ],
                       model: "echo/echo"),
        ]
        var waitingRun = RoutineRun(routine: added.id, trigger: .scheduled, chat: waitingChat)
        waitingRun.state = .waiting
        waitingRun.queuedAt = Date().addingTimeInterval(-3600)
        waitingRun.startedAt = waitingRun.queuedAt
        waitingRun.waitingQuestion = AskQuestion(
            chat: waitingChat.id, text: "Morning or evening edition?",
            options: ["Morning", "Evening"])
        // A parked approval beside the question — the run detail page
        // draws both kinds of waiting card off this.
        waitingRun.waitingApprovals = [AskApproval(
            chat: waitingChat.id, op: "act.submit",
            summary: "submit the subscription form on news.example.com",
            why: "the digest needs the edition confirmed before checkout",
            tabID: "abc123", host: "news.example.com")]
        runs[added.id, default: []].insert(waitingRun, at: 0)
        RoutineStore.save(waitingRun)

        if let at = routines.firstIndex(where: { $0.id == added.id }) {
            routines[at].lastRunID = waitingRun.id
            routines[at].nextRunAt = added.schedule.next(after: Date(), tz: added.timeZone)
            RoutineStore.save(routines[at])
        }
    }
    #endif
}
