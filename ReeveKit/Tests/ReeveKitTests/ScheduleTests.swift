import Foundation
import Testing
@testable import ReeveKit

private let toronto: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Toronto")!
    return calendar
}()

private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    toronto.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func next(_ expression: String, after date: Date) throws -> Date? {
    try Cron(expression).next(after: date, calendar: toronto)
}

@Suite struct CronTests {
    @Test func everyMinuteIsTheNextWholeMinute() throws {
        let start = at(2026, 11, 23, 9, 15).addingTimeInterval(20)
        #expect(try next("* * * * *", after: start) == at(2026, 11, 23, 9, 16))
        // Strictly after, even on the minute.
        #expect(try next("* * * * *", after: at(2026, 11, 23, 9, 15)) == at(2026, 11, 23, 9, 16))
    }

    @Test func weekdaysAtNine() throws {
        // 2026-11-27 is a Friday.
        #expect(try next("0 9 * * 1-5", after: at(2026, 11, 27, 9, 0)) == at(2026, 11, 30, 9, 0))
        #expect(try next("0 9 * * mon-fri", after: at(2026, 11, 27, 8, 0)) == at(2026, 11, 27, 9, 0))
    }

    @Test func stepsOnRangesAndFromAValue() throws {
        let cron = try Cron("10-30/5 * * * *")
        #expect(cron.minutes == [10, 15, 20, 25, 30])
        #expect(try Cron("5/20 * * * *").minutes == [5, 25, 45])
        #expect(try Cron("*/15 * * * *").minutes == [0, 15, 30, 45])
        #expect(try next("10-30/5 * * * *", after: at(2026, 1, 1, 3, 31)) == at(2026, 1, 1, 4, 10))
    }

    @Test func listsAndNames() throws {
        let cron = try Cron("0,30 8,17 * jan,JUL sun")
        #expect(cron.minutes == [0, 30])
        #expect(cron.hours == [8, 17])
        #expect(cron.months == [1, 7])
        #expect(cron.weekdays == [0])
    }

    @Test func sevenIsSunday() throws {
        #expect(try Cron("0 0 * * 7").weekdays == [0])
        // 2026-11-29 is a Sunday.
        #expect(try next("0 0 * * 7", after: at(2026, 11, 23)) == at(2026, 11, 29))
    }

    @Test func dayOfMonthOrDayOfWeek() throws {
        // The 1st, or any Monday: Monday 2026-11-23 comes before December 1st.
        #expect(try next("0 0 1 * mon", after: at(2026, 11, 22, 12)) == at(2026, 11, 23))
        #expect(try next("0 0 1 * mon", after: at(2026, 11, 30, 12)) == at(2026, 12, 1))
        // A starred weekday leaves the day of month alone.
        #expect(try next("0 0 1 * *", after: at(2026, 11, 22)) == at(2026, 12, 1))
        // And a stepped one counts as starred, as in cron.
        #expect(try next("0 0 15 * */1", after: at(2026, 11, 22)) == at(2026, 12, 15))
    }

    @Test func leapDay() throws {
        #expect(try next("0 0 29 2 *", after: at(2026, 3, 1)) == at(2028, 2, 29))
    }

    @Test func impossibleNeverComes() throws {
        #expect(try next("0 0 30 2 *", after: at(2026, 1, 1)) == nil)
    }

    @Test func springForwardSkipsTheMissingHour() throws {
        // Clocks in Toronto go from 2:00 to 3:00 on 2027-03-14.
        #expect(try next("0 * * * *", after: at(2027, 3, 14, 1, 30)) == at(2027, 3, 14, 3, 0))
        #expect(try next("30 3 * * *", after: at(2027, 3, 14, 1, 0)) == at(2027, 3, 14, 3, 30))
    }

    @Test func fallBackRunsTheRepeatedHourOnce() throws {
        // Clocks in Toronto go from 2:00 back to 1:00 on 2026-11-01.
        let firstOne = at(2026, 11, 1, 0, 30).addingTimeInterval(30 * 60)
        #expect(toronto.component(.hour, from: firstOne) == 1)
        #expect(try next("0 1 * * *", after: firstOne) == at(2026, 11, 2, 1, 0))
        #expect(try next("30 1 * * *", after: firstOne.addingTimeInterval(30 * 60)) == at(2026, 11, 2, 1, 30))
        // An hourly one skips the repeated hour too, and goes on at 2:00.
        #expect(try next("0 * * * *", after: firstOne) == at(2026, 11, 1, 2, 0))
    }

    @Test func macros() throws {
        #expect(try Cron("@daily").minutes == [0])
        #expect(try Cron("@hourly") == Cron("@hourly"))
        #expect(try next("@weekly", after: at(2026, 11, 23)) == at(2026, 11, 29))
        #expect(try next("@monthly", after: at(2026, 11, 23)) == at(2026, 12, 1))
        #expect(try next("@yearly", after: at(2026, 11, 23)) == at(2027, 1, 1))
    }

    @Test func upcoming() throws {
        #expect(try Cron("0 */6 * * *").upcoming(3, after: at(2026, 11, 23, 1), calendar: toronto)
            == [at(2026, 11, 23, 6), at(2026, 11, 23, 12), at(2026, 11, 23, 18)])
    }

    @Test func errorsSayWhatIsWrong() {
        #expect(throws: CronError.self) { try Cron("") }
        #expect(throws: CronError("A cron expression has five fields (minute hour day month weekday); this has 4.")) { try Cron("0 9 * *") }
        #expect(throws: CronError("The minute must be 0–59; “60” isn't.")) { try Cron("60 * * * *") }
        #expect(throws: CronError("The hour range “9-5” runs backwards.")) { try Cron("0 9-5 * * *") }
        #expect(throws: CronError.self) { try Cron("*/0 * * * *") }
        #expect(throws: CronError.self) { try Cron("0 0 * foo *") }
        #expect(throws: CronError.self) { try Cron("1,,2 * * * *") }
        #expect(throws: CronError.self) { try Cron("@fortnightly") }
    }
}

@Suite struct ScheduleTests {
    private func schedule(_ cron: String, checkedThrough: Date) -> Schedule {
        var schedule = Schedule(name: "Nightly", cron: cron, prompt: "Tidy up", repoPath: "/repo", createdAt: checkedThrough)
        schedule.checkedThrough = checkedThrough
        return schedule
    }

    @Test func notDueBeforeItsTime() {
        let s = schedule("0 9 * * *", checkedThrough: at(2026, 11, 23, 8))
        #expect(s.due(now: at(2026, 11, 23, 8, 59), calendar: toronto) == nil)
    }

    @Test func dueOnTime() throws {
        let s = schedule("0 9 * * *", checkedThrough: at(2026, 11, 23, 8))
        let due = try #require(s.due(now: at(2026, 11, 23, 9).addingTimeInterval(20), calendar: toronto))
        #expect(due.scheduledFor == at(2026, 11, 23, 9))
        #expect(!due.late)
    }

    @Test func oneMissedRunIsLate() throws {
        let s = schedule("0 9 * * *", checkedThrough: at(2026, 11, 23, 8))
        let due = try #require(s.due(now: at(2026, 11, 23, 14), calendar: toronto))
        #expect(due.scheduledFor == at(2026, 11, 23, 9))
        #expect(due.late)
    }

    @Test func manyMissedRunsAreOne() throws {
        let s = schedule("0 9 * * *", checkedThrough: at(2026, 11, 20, 8))
        let due = try #require(s.due(now: at(2026, 11, 23, 10), calendar: toronto))
        #expect(due.scheduledFor == at(2026, 11, 23, 9))
        #expect(due.late)
    }

    @Test func offOrUnreadableIsNeverDue() {
        var s = schedule("0 9 * * *", checkedThrough: at(2026, 11, 23, 8))
        s.enabled = false
        #expect(s.due(now: at(2026, 11, 24), calendar: toronto) == nil)
        #expect(s.nextRun(after: at(2026, 11, 23), calendar: toronto) == nil)
        #expect(schedule("nope", checkedThrough: at(2026, 11, 23)).due(now: at(2026, 11, 24), calendar: toronto) == nil)
    }

    @Test func historyIsCapped() {
        var s = schedule("* * * * *", checkedThrough: at(2026, 11, 23))
        for i in 0..<(Schedule.maxRuns + 5) {
            s.record(ScheduleRun(scheduledFor: at(2026, 11, 23, 0, i), status: .skipped))
        }
        #expect(s.runs.count == Schedule.maxRuns)
        // Newest first.
        #expect(s.runs.first?.scheduledFor == at(2026, 11, 23, 0, Schedule.maxRuns + 4))
    }

    @Test func settlingARun() {
        var s = schedule("* * * * *", checkedThrough: at(2026, 11, 23))
        let card = UUID()
        s.record(ScheduleRun(scheduledFor: at(2026, 11, 23), cardId: card, status: .running))
        #expect(s.runInFlight?.cardId == card)
        var changed = s.settle(cardId: card, .failed, detail: "Gave up")
        #expect(changed)
        #expect(s.runInFlight == nil)
        // A person saw it through after all.
        changed = s.settle(cardId: card, .succeeded, detail: "Merged")
        #expect(changed)
        #expect(s.runs[0].status == .succeeded)
        // Nothing undoes a success.
        changed = s.settle(cardId: card, .failed, detail: "Closed")
        #expect(!changed)
        #expect(s.runs[0].status == .succeeded)
        changed = s.settle(cardId: UUID(), .failed, detail: nil)
        #expect(!changed)
    }

    @Test func anEditKeepsWhatRunningItChanged() {
        // The editor opened at 8:30; the 9:00 run happened while it was open.
        let opened = schedule("0 * * * *", checkedThrough: at(2026, 11, 23, 8, 30))
        var stored = opened
        stored.checkedThrough = at(2026, 11, 23, 9, 0)
        stored.record(ScheduleRun(scheduledFor: at(2026, 11, 23, 9), cardId: UUID(), status: .running))
        var edited = opened
        edited.prompt = "Tidy up more"
        let saved = stored.applying(edited, now: at(2026, 11, 23, 9, 10))
        #expect(saved.prompt == "Tidy up more")
        #expect(saved.runs == stored.runs)
        #expect(saved.due(now: at(2026, 11, 23, 9, 10), calendar: toronto) == nil)
    }

    @Test func aNewCronOrTurningItOnCountsFromNow() {
        let stored = schedule("0 9 * * *", checkedThrough: at(2026, 11, 20))
        var edited = stored
        edited.cron = "0 8 * * *"
        #expect(stored.applying(edited, now: at(2026, 11, 23, 10)).checkedThrough == at(2026, 11, 23, 10))
        var off = stored
        off.enabled = false
        var on = off
        on.enabled = true
        #expect(off.applying(on, now: at(2026, 11, 23, 10)).checkedThrough == at(2026, 11, 23, 10))
        #expect(on.applying(off, now: at(2026, 11, 23, 10)).checkedThrough == at(2026, 11, 20))
    }

    @Test func oldBoardsDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","sessionId":"6F9619FF-8B86-D011-B42D-00C04FC964FE","title":"x","titledByPerson":true,"cwd":"/r","stage":"backlog","activity":"idle","stagePinned":false,"hasConversation":false,"createdAt":0,"updatedAt":0}"#
        let card = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        #expect(card.scheduleId == nil)
    }
}
