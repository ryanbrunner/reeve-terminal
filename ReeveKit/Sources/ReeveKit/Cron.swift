import Foundation

/// A five-field cron expression — minute, hour, day of month, month, day of
/// week — read as cron reads it, in local time.
///
/// Each field takes `*`, a value, a range `a-b`, a list `a,b`, and a step on
/// any of them (`*/15`, `10-30/5`, `5/10`). Months and weekdays take their
/// three-letter names, and Sunday is `0` or `7`. When both the day of month
/// and the day of week are given, a day matches if either does, as in cron.
/// `@hourly`, `@daily` (`@midnight`), `@weekly`, `@monthly` and `@yearly`
/// (`@annually`) stand for the usual lines.
public struct Cron: Equatable, Sendable {
    public let expression: String
    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>
    /// The day fields left as `*`, which take no part in matching a day.
    let anyDay: Bool
    let anyWeekday: Bool

    public init(_ expression: String) throws {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        self.expression = trimmed
        let line = Self.macros[trimmed.lowercased()] ?? trimmed
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        if trimmed.hasPrefix("@"), Self.macros[trimmed.lowercased()] == nil {
            throw CronError("Unknown shorthand “\(trimmed)”. Try @hourly, @daily, @weekly, @monthly or @yearly.")
        }
        guard fields.count == 5 else {
            throw CronError(fields.isEmpty
                ? "Enter a cron expression, like 0 9 * * 1-5."
                : "A cron expression has five fields (minute hour day month weekday); this has \(fields.count).")
        }
        minutes = try Self.parse(fields[0], name: "minute", range: 0...59)
        hours = try Self.parse(fields[1], name: "hour", range: 0...23)
        days = try Self.parse(fields[2], name: "day of month", range: 1...31)
        months = try Self.parse(fields[3], name: "month", range: 1...12, names: Self.monthNames)
        // 7 is Sunday too.
        weekdays = Set(try Self.parse(fields[4], name: "day of week", range: 0...7, names: Self.weekdayNames).map { $0 % 7 })
        anyDay = fields[2].hasPrefix("*")
        anyWeekday = fields[4].hasPrefix("*")
    }

    /// The first minute after `date` the expression matches, or nil if there
    /// is none in the next five years (`0 0 30 2 *` never comes).
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard let limit = calendar.date(byAdding: .year, value: 5, to: date) else { return nil }
        // The next whole minute.
        var t = calendar.dateInterval(of: .minute, for: date).map { $0.end } ?? date.addingTimeInterval(60)
        while t <= limit {
            let c = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: t)
            guard let month = c.month, let day = c.day, let hour = c.hour, let minute = c.minute, let weekday = c.weekday else { return nil }
            if !months.contains(month) {
                guard let start = calendar.dateInterval(of: .month, for: t)?.end else { return nil }
                t = start
            } else if !matchesDay(day, weekday: weekday - 1) {
                guard let start = calendar.dateInterval(of: .day, for: t)?.end else { return nil }
                t = start
            } else if !hours.contains(hour) {
                guard let start = nextHour(after: t, calendar: calendar) else { return nil }
                t = start
            } else if let m = minutes.filter({ $0 >= minute }).min() {
                if m == minute { return t }
                t = t.addingTimeInterval(TimeInterval((m - minute) * 60))
            } else {
                guard let start = nextHour(after: t, calendar: calendar) else { return nil }
                t = start
            }
        }
        return nil
    }

    /// The next `count` times it runs after `date`.
    public func upcoming(_ count: Int, after date: Date, calendar: Calendar = .current) -> [Date] {
        var times: [Date] = []
        var from = date
        while times.count < count, let t = next(after: from, calendar: calendar) {
            times.append(t)
            from = t
        }
        return times
    }

    /// The start of the clock's next hour, so a day that skips one for
    /// daylight saving still lands on whole hours. An hour the clocks go
    /// back through comes once, as in cron: `0 1 * * *` runs once that night.
    private func nextHour(after t: Date, calendar: Calendar) -> Date? {
        guard let start = calendar.dateInterval(of: .hour, for: t)?.end else { return nil }
        guard calendar.component(.hour, from: start) == calendar.component(.hour, from: t) else { return start }
        return calendar.dateInterval(of: .hour, for: start)?.end
    }

    private func matchesDay(_ day: Int, weekday: Int) -> Bool {
        switch (anyDay, anyWeekday) {
        case (true, true): true
        case (true, false): weekdays.contains(weekday)
        case (false, true): days.contains(day)
        case (false, false): days.contains(day) || weekdays.contains(weekday)
        }
    }

    static let macros = [
        "@hourly": "0 * * * *",
        "@daily": "0 0 * * *",
        "@midnight": "0 0 * * *",
        "@weekly": "0 0 * * 0",
        "@monthly": "0 0 1 * *",
        "@yearly": "0 0 1 1 *",
        "@annually": "0 0 1 1 *",
    ]
    static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        .enumerated().reduce(into: [String: Int]()) { $0[$1.element] = $1.offset + 1 }
    static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        .enumerated().reduce(into: [String: Int]()) { $0[$1.element] = $1.offset }

    private static func parse(_ field: String, name: String, range: ClosedRange<Int>, names: [String: Int] = [:]) throws -> Set<Int> {
        var values = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count <= 2, let base = pieces.first, !base.isEmpty else {
                throw CronError("“\(part)” isn't a valid \(name).")
            }
            var step = 1
            if pieces.count == 2 {
                guard let n = Int(pieces[1]), n > 0 else { throw CronError("“\(pieces[1])” isn't a valid step for the \(name).") }
                step = n
            }
            var low: Int, high: Int
            if base == "*" {
                (low, high) = (range.lowerBound, range.upperBound)
            } else if let dash = base.firstIndex(of: "-") {
                low = try value(String(base[..<dash]), name: name, range: range, names: names)
                high = try value(String(base[base.index(after: dash)...]), name: name, range: range, names: names)
                guard low <= high else { throw CronError("The \(name) range “\(base)” runs backwards.") }
            } else {
                low = try value(base, name: name, range: range, names: names)
                // `5/10` is every tenth from 5.
                high = pieces.count == 2 ? range.upperBound : low
            }
            values.formUnion(stride(from: low, through: high, by: step))
        }
        return values
    }

    private static func value(_ text: String, name: String, range: ClosedRange<Int>, names: [String: Int]) throws -> Int {
        if let n = names[text.lowercased()] { return n }
        guard let n = Int(text) else { throw CronError("“\(text)” isn't a valid \(name).") }
        guard range.contains(n) else {
            throw CronError("The \(name) must be \(range.lowerBound)–\(range.upperBound); “\(text)” isn't.")
        }
        return n
    }
}

/// Why a cron expression didn't read, in words the editor can show.
public struct CronError: Error, LocalizedError, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
