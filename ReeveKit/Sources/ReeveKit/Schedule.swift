import Foundation

/// Work that starts itself: on a cron schedule, Reeve makes a card in a repo
/// with the prompt, straight into In Progress with VIBES MODE on, and keeps a
/// record of how each run went.
public struct Schedule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var cron: String
    /// What each run's card is told.
    public var prompt: String
    /// The folder each run's card starts in.
    public var repoPath: String
    /// The swimlane each run's card goes in. Nil, or a lane that has gone, is the first.
    public var laneId: UUID?
    public var model: String?
    public var effort: String?
    public var enabled: Bool
    /// Every time the schedule came due up to here has been dealt with: run,
    /// skipped or folded into a late run.
    public var checkedThrough: Date
    /// Newest first, at most `maxRuns`.
    public var runs: [ScheduleRun]
    public var createdAt: Date

    /// How many runs a schedule remembers. The board is saved whole on every
    /// change, so a schedule running every minute can't grow it for ever.
    public static let maxRuns = 50

    public init(id: UUID = UUID(), name: String, cron: String, prompt: String, repoPath: String, laneId: UUID? = nil,
                model: String? = nil, effort: String? = nil, enabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.cron = cron
        self.prompt = prompt
        self.repoPath = repoPath
        self.laneId = laneId
        self.model = model
        self.effort = effort
        self.enabled = enabled
        self.checkedThrough = createdAt
        self.runs = []
        self.createdAt = createdAt
    }

    /// When it runs next, or nil when it is off, doesn't read, or never comes.
    public func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, let cron = try? Cron(cron) else { return nil }
        return cron.next(after: max(date, checkedThrough), calendar: calendar)
    }

    /// The time it came due that hasn't been dealt with yet, if one has. Only
    /// the latest: missed runs, while Reeve was closed or the Mac asleep, come
    /// to one run, marked late.
    public func due(now: Date, calendar: Calendar = .current) -> (scheduledFor: Date, late: Bool)? {
        guard enabled, let cron = try? Cron(cron),
              var latest = cron.next(after: checkedThrough, calendar: calendar), latest <= now else { return nil }
        var missed = 0
        // Bounded: a week away from a schedule that runs every minute is ten
        // thousand of them, and any one is late enough.
        while missed < 2000, let after = cron.next(after: latest, calendar: calendar), after <= now {
            latest = after
            missed += 1
        }
        return (latest, missed > 0 || now.timeIntervalSince(latest) > 120)
    }

    /// The schedule with a person's edits from `edited`, keeping what only
    /// running it changes: its runs and how far it has been checked, which
    /// may have moved on since the editor opened. A new cron, or a schedule
    /// turned back on, counts from `now`, so an edit never sets off the times
    /// it would have run before.
    public func applying(_ edited: Schedule, now: Date = Date()) -> Schedule {
        var next = edited
        next.id = id
        next.runs = runs
        next.createdAt = createdAt
        next.checkedThrough = edited.cron != cron || (edited.enabled && !enabled) ? now : checkedThrough
        return next
    }

    /// The run still going: its card is on the board and hasn't shipped.
    public var runInFlight: ScheduleRun? {
        runs.first { $0.status == .running }
    }

    public mutating func record(_ run: ScheduleRun) {
        runs.insert(run, at: 0)
        if runs.count > Self.maxRuns { runs.removeLast(runs.count - Self.maxRuns) }
    }

    /// How the run that made `cardId` came out. A run that failed can still
    /// succeed, when a person sees its card through; one that succeeded stays so.
    @discardableResult
    public mutating func settle(cardId: UUID, _ status: ScheduleRun.Status, detail: String?) -> Bool {
        guard let i = runs.firstIndex(where: { $0.cardId == cardId }) else { return false }
        let run = runs[i]
        guard run.status != .succeeded, run.status != .skipped, run.status != status || run.detail != detail else { return false }
        runs[i].status = status
        runs[i].detail = detail
        runs[i].finishedAt = Date()
        return true
    }
}

/// One time a schedule came due, and what came of it.
public struct ScheduleRun: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The time the schedule said; `startedAt` is when it actually ran.
    public var scheduledFor: Date
    public var startedAt: Date
    public var finishedAt: Date?
    /// The card it made, if it made one.
    public var cardId: UUID?
    public var status: Status
    /// Why it failed or was skipped, or how it landed.
    public var detail: String?
    /// It came due while Reeve was closed or the Mac asleep, and ran on return.
    public var late: Bool
    /// A person pressed Run now.
    public var manual: Bool

    public enum Status: String, Codable, Sendable {
        /// Its card is on the board, not yet shipped.
        case running
        /// Its card shipped: merged, or its pull request is up for a person to merge.
        case succeeded
        /// No card could be made, VIBES MODE gave up on it, or it was closed unshipped.
        case failed
        /// The run before was still going, so this one made no card.
        case skipped
    }

    public init(id: UUID = UUID(), scheduledFor: Date, startedAt: Date = Date(), cardId: UUID? = nil, status: Status,
                detail: String? = nil, late: Bool = false, manual: Bool = false) {
        self.id = id
        self.scheduledFor = scheduledFor
        self.startedAt = startedAt
        self.cardId = cardId
        self.status = status
        self.detail = detail
        self.late = late
        self.manual = manual
        if status != .running { finishedAt = startedAt }
    }
}
