import AppKit
import ReeveKit
import SwiftUI

/// Work that starts itself: each schedule's cron, prompt and repo, and every
/// time it ran. A run is a card straight into In Progress with VIBES MODE on,
/// and succeeds once that card ships.
struct SchedulesView: View {
    @EnvironmentObject var board: Board
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Selection?

    enum Selection: Hashable {
        case new
        case schedule(UUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Schedules").font(.geist(16, .semibold)).foregroundStyle(Theme.text)
                Text("\(board.schedules.count)")
                    .font(.mono(11, .medium))
                    .foregroundStyle(Theme.muted.opacity(0.6))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Rectangle().fill(Theme.edge).frame(height: 1)
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(Theme.edge).frame(width: 1)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 860, height: 720)
        .background(Theme.panel)
        .onAppear {
            if selection == nil { selection = board.schedules.first.map { .schedule($0.id) } ?? .new }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(board.schedules) { schedule in
                        ScheduleListRow(schedule: schedule, selected: selection == .schedule(schedule.id))
                            .contentShape(Rectangle())
                            .onTapGesture { selection = .schedule(schedule.id) }
                    }
                    if selection == .new {
                        HStack {
                            Text("New schedule").font(.geist(13, .medium)).foregroundStyle(Theme.text)
                            Spacer()
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sky950))
                    }
                }
                .padding(8)
            }
            Rectangle().fill(Theme.edge).frame(height: 1)
            Button("New Schedule") { selection = .new }
                .buttonStyle(SecondaryButtonStyle())
                .padding(10)
        }
        .frame(width: 240)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .new:
            ScheduleEditor(initial: Schedule(name: "", cron: "0 9 * * 1-5", prompt: "", repoPath: board.pickedRepo?.path ?? ""),
                           isNew: true) { selection = $0.map(Selection.schedule) ?? board.schedules.first.map { .schedule($0.id) } }
                .id("new")
        case .schedule(let id):
            if let schedule = board.schedules.first(where: { $0.id == id }) {
                ScheduleEditor(initial: schedule, isNew: false) { selection = $0.map(Selection.schedule) ?? board.schedules.first.map { .schedule($0.id) } ?? .new }
                    .id(id)
            }
        case nil:
            EmptyView()
        }
    }
}

/// A schedule in the list: its name, when it runs next, and how it last went.
private struct ScheduleListRow: View {
    let schedule: Schedule
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(schedule.runs.first.map { RunLook.of($0.status).color } ?? Theme.edgeStrong)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.name.isEmpty ? "Untitled" : schedule.name)
                    .font(.geist(13, .medium))
                    .foregroundStyle(schedule.enabled ? Theme.text : Theme.muted)
                    .lineLimit(1)
                Text(schedule.cron).font(.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                Text(nextLine).font(.mono(10)).foregroundStyle(Theme.muted.opacity(0.8)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.sky950 : Color.clear))
    }

    private var nextLine: String {
        guard schedule.enabled else { return "Off" }
        guard let next = schedule.nextRun(after: Date()) else { return "Never runs" }
        return "Next " + next.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

/// One schedule, edited as a draft and saved, with its runs below.
private struct ScheduleEditor: View {
    @EnvironmentObject var board: Board
    @Environment(\.dismiss) private var dismiss
    let initial: Schedule
    let isNew: Bool
    /// Where the list goes after a save or delete: the schedule saved, or
    /// nil for whichever comes first.
    let select: (UUID?) -> Void
    @State private var draft: Schedule
    @State private var showingOptions = false
    @State private var confirmingDelete = false

    init(initial: Schedule, isNew: Bool, select: @escaping (UUID?) -> Void) {
        self.initial = initial
        self.isNew = isNew
        self.select = select
        _draft = State(initialValue: initial)
    }

    /// The schedule as saved, with its latest runs.
    private var saved: Schedule? {
        board.schedules.first { $0.id == initial.id }
    }

    private var cron: Result<Cron, Error> {
        Result { try Cron(draft.cron) }
    }

    private var dirty: Bool {
        guard let saved else { return true }
        var compared = draft
        compared.runs = saved.runs
        compared.checkedThrough = saved.checkedThrough
        return compared != saved
    }

    private var problem: String? {
        if case .failure(let error) = cron { return error.localizedDescription }
        if draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write the prompt each run's card starts on." }
        if draft.repoPath.isEmpty { return "Pick the repo each run's card starts in." }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                field("Name") {
                    TextField("", text: $draft.name, prompt: Text("Nightly dependency bump").foregroundStyle(Theme.muted.opacity(0.6)))
                        .textFieldStyle(.plain)
                        .font(.geist(13, .medium))
                        .foregroundStyle(Theme.text)
                        .boxed()
                }
                field("Schedule") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("", text: $draft.cron, prompt: Text("minute hour day month weekday").foregroundStyle(Theme.muted.opacity(0.6)))
                            .textFieldStyle(.plain)
                            .font(.mono(13))
                            .foregroundStyle(Theme.text)
                            .boxed()
                        HStack(spacing: 6) {
                            ForEach(Self.presets, id: \.1) { name, expression in
                                Button(name) { draft.cron = expression }
                                    .buttonStyle(.plain)
                                    .modifier(MenuChip(muted: draft.cron != expression))
                            }
                        }
                        cronLine
                    }
                }
                field("Prompt") {
                    TextEditor(text: $draft.prompt)
                        .font(.geist(13))
                        .foregroundStyle(Theme.text)
                        .scrollContentBackground(.hidden)
                        .frame(height: 72)
                        .boxed()
                }
                HStack(spacing: 6) {
                    repoMenu
                    if board.lanes.count > 1 { laneMenu }
                    optionsMenu
                    Spacer()
                    Toggle("On", isOn: $draft.enabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.geist(11))
                        .foregroundStyle(Theme.muted)
                }
                Text("Each run is a card in In Progress with VIBES MODE on. It succeeds once the card ships.")
                    .font(.geist(11))
                    .foregroundStyle(Theme.muted)
                actions
                if !isNew { history }
            }
            .padding(16)
        }
    }

    private static let presets = [
        ("Hourly", "0 * * * *"),
        ("Weekdays 9am", "0 9 * * 1-5"),
        ("Nightly", "0 2 * * *"),
        ("Mondays", "0 9 * * 1"),
    ]

    @ViewBuilder
    private var cronLine: some View {
        switch cron {
        case .success(let cron):
            let times = cron.upcoming(3, after: Date())
            Text(times.isEmpty ? "Never runs: no such date comes in the next five years."
                 : (draft.enabled ? "Next: " : "Off. When on, next: ") + times.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) }.joined(separator: " · "))
                .font(.mono(10))
                .foregroundStyle(times.isEmpty ? Color(hex: 0xFBBF24) : Theme.muted)
        case .failure(let error):
            Text(error.localizedDescription)
                .font(.mono(10))
                .foregroundStyle(Color(hex: 0xF87171))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(isNew ? "Add Schedule" : "Save") { save() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(problem != nil || !dirty)
                .opacity(problem != nil || !dirty ? 0.5 : 1)
                .keyboardShortcut("s", modifiers: .command)
            if !isNew, dirty {
                Button("Revert") { draft = saved ?? initial }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if let problem, dirty {
                Text(problem).font(.geist(11)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer()
            if !isNew {
                Button("Run Now") { board.runSchedule(initial.id) }
                    .buttonStyle(SecondaryButtonStyle())
                    .help(dirty ? "Runs the schedule as saved" : "Makes a card now, whatever the last run is doing")
                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
                .help("Delete the schedule")
                .confirmationDialog("Delete “\(initial.name.isEmpty ? "Untitled" : initial.name)”?", isPresented: $confirmingDelete) {
                    Button("Delete", role: .destructive) {
                        board.deleteSchedule(initial.id)
                        select(nil)
                    }
                } message: {
                    Text("Its cards stay on the board, and its history goes.")
                }
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Runs")
                .padding(.bottom, 8)
            let runs = saved?.runs ?? []
            if runs.isEmpty {
                Text("No runs yet.")
                    .font(.geist(12))
                    .foregroundStyle(Theme.muted)
            } else {
                Rectangle().fill(Theme.edge).frame(height: 1)
                ForEach(runs) { run in
                    RunRow(run: run, onOpen: dismiss.callAsFunction)
                    Rectangle().fill(Theme.edge).frame(height: 1)
                }
            }
        }
    }

    private func save() {
        guard problem == nil else { return }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.cron = draft.cron.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew {
            select(board.addSchedule(draft).id)
        } else {
            board.saveSchedule(draft)
            if let saved { draft = saved }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title)
            content()
        }
    }

    // MARK: The new card field's chips

    private var repoMenu: some View {
        let repo = board.availableRepos.first { $0.path == draft.repoPath }
        return Menu {
            ForEach(board.availableRepos) { repo in
                Button { draft.repoPath = repo.path } label: {
                    Text(repo.name)
                    Text(repo.path)
                }
            }
            if !board.availableRepos.isEmpty { Divider() }
            Button("Add Repo…") {
                if let path = RepoPicker.choose(from: draft.repoPath.isEmpty ? nil : draft.repoPath) {
                    draft.repoPath = board.addRepo(path: path).path
                }
            }
        } label: {
            Text(repo?.name ?? (draft.repoPath.isEmpty ? "Add a repo…" : URL(fileURLWithPath: draft.repoPath).lastPathComponent))
                .font(.geist(11))
        }
        .modifier(MenuChip(muted: repo == nil))
        .help(draft.repoPath.isEmpty ? "The repo each run's card works in" : draft.repoPath)
    }

    private var laneMenu: some View {
        let lane = board.lanes.first { $0.id == draft.laneId } ?? board.lanes[0]
        return Menu {
            ForEach(board.lanes) { lane in
                Button(lane.name) { draft.laneId = lane.id }
            }
        } label: {
            Text(lane.name).font(.geist(11))
        }
        .modifier(MenuChip(muted: false))
        .help("The swimlane each run's card goes in")
    }

    private var optionsMenu: some View {
        let model = Binding<String>(get: { draft.model ?? "" }, set: { draft.model = $0.isEmpty ? nil : $0 })
        let effort = Binding<String>(get: { draft.effort ?? "" }, set: { draft.effort = $0.isEmpty ? nil : $0 })
        let label = [draft.model, draft.effort].compactMap { $0 }.map(NewCardField.name).joined(separator: " · ")
        return Button { showingOptions.toggle() } label: {
            Text(label.isEmpty ? "Default model" : label)
        }
        .buttonStyle(.plain)
        .modifier(MenuChip(muted: label.isEmpty))
        .help("The model and effort each run's claude runs with")
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                StopSlider(title: "Model", stops: [""] + Launch.models.reversed(), selection: model, label: NewCardField.name, tint: { _ in Theme.sky400 })
                StopSlider(title: "Effort", stops: [""] + Launch.efforts, selection: effort, label: NewCardField.name, tint: NewCardField.effortTint)
            }
            .padding(12)
            .frame(width: 240)
            .background(Theme.ink)
        }
    }
}

/// One time the schedule came due: how it went, when, and its card.
private struct RunRow: View {
    @EnvironmentObject var board: Board
    let run: ScheduleRun
    let onOpen: () -> Void

    var body: some View {
        let look = self.look
        HStack(alignment: .top, spacing: 10) {
            Chip(text: look.label, color: look.color, fill: look.color.opacity(0.16))
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(run.scheduledFor.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                        .font(.mono(11))
                        .foregroundStyle(Theme.textSoft)
                        .help("Ran " + run.startedAt.formatted(date: .abbreviated, time: .standard))
                    if run.late { Chip(text: "late", color: Color(hex: 0xFBBF24), fill: Color(hex: 0xFBBF24).opacity(0.14)) }
                    if run.manual { Chip(text: "run now") }
                }
                if let detail = look.detail {
                    Text(detail).font(.geist(11)).foregroundStyle(Theme.muted).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let id = run.cardId, board.card(id) != nil {
                Button("Open Card") {
                    onOpen()
                    board.select(id)
                }
                .buttonStyle(SecondaryButtonStyle(height: 24))
            } else if let id = run.cardId, let pr = board.archive.first(where: { $0.id == id })?.pullRequest, let url = URL(string: pr.url) {
                Button("Open PR") { NSWorkspace.shared.open(url) }
                    .buttonStyle(SecondaryButtonStyle(height: 24))
            }
        }
        .padding(.vertical, 10)
    }

    /// A running run says more than its status: its card may be waiting on
    /// you, or asleep since a relaunch until someone opens it.
    private var look: (label: String, color: Color, detail: String?) {
        let base = RunLook.of(run.status)
        guard run.status == .running, let id = run.cardId, let card = board.card(id) else {
            return (base.label, base.color, run.detail)
        }
        if card.activity == .needsInput {
            return ("Needs you", Color(hex: 0xFBBF24), card.waitingOn ?? "Claude Code is asking a person")
        }
        if !board.live.contains(id) {
            return ("Paused", Theme.muted, "Its session isn’t running · open the card to carry on")
        }
        return (base.label, base.color, "\(card.stage.label)" + (card.summary.map { " · \($0)" } ?? ""))
    }
}

/// A run's status, as a label and a colour.
private enum RunLook {
    static func of(_ status: ScheduleRun.Status) -> (label: String, color: Color) {
        switch status {
        case .running: ("Running", Theme.sky400)
        case .succeeded: ("Succeeded", Color(hex: 0x34D399))
        case .failed: ("Failed", Color(hex: 0xF87171))
        case .skipped: ("Skipped", Theme.muted)
        }
    }
}

private extension View {
    /// A field's box, as the new card field draws one.
    func boxed() -> some View {
        padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.edge))
    }
}
