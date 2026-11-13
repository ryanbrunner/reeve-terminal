import AppKit
import Combine
import ReeveKit
import SwiftUI

/// The board: every card, which one is open, and what keeps them up to date.
///
/// Cards learn what their session is doing from Claude Code's hooks, the
/// moment it happens. Where the work is — its column — they learn by asking
/// Claude once each turn ends.
@MainActor
final class Board: ObservableObject {
    @Published private(set) var cards: [Card] = []
    /// The card open over the board, if any.
    @Published var selectedId: UUID?
    /// Cards whose terminal has a live `claude` in it.
    @Published private(set) var live: Set<UUID> = []
    /// Cards Claude is working out the column of right now.
    @Published private(set) var classifying: Set<UUID> = []
    /// Why the last classification of a card failed, until the next one works.
    @Published private(set) var classifyErrors: [UUID: String] = [:]
    /// What `claude` last set as each terminal's title.
    @Published private(set) var terminalTitles: [UUID: String] = [:]
    @Published var showingNewCard = false
    @Published private(set) var environment: ShellEnvironment?

    /// The board-wide VIBES MODE switch, and its tally since it was flipped.
    /// Nil is off.
    @Published private(set) var vibes: VibesLedger?
    /// What VIBES MODE skips and whether it merges.
    @Published var vibesOptions = VibesOptions() {
        didSet { save() }
    }
    /// The two seconds after the switch goes on, spent saying what came off.
    @Published private(set) var vibesArming = false
    /// What happened while you were out, said once when the switch goes off.
    @Published private(set) var vibesToast: String?
    /// Cards that shipped a moment ago: they get the stamp.
    @Published private(set) var justShipped: Set<UUID> = []
    /// Raised on every ship, so the board can shake, flash and pop each time.
    @Published private(set) var shipBeat = 0
    /// Columns something landed in a moment ago.
    @Published private(set) var hotStages: Set<Stage> = []

    let terminals = Terminals()
    private var hooks: HookServer?
    private var hookPort: UInt16?
    /// Raised by every prompt, so a classification that a newer turn has
    /// overtaken leaves the card's activity alone.
    private var turns: [UUID: Int] = [:]
    private var pendingClassify: [UUID: Task<Void, Never>] = [:]
    private var restarting: Set<UUID> = []
    private var pendingRemovals: [WorktreeRemoval] = []
    /// Starts waiting on the shell environment or the hook port.
    private var waitingToStart: [(Card, String?)] = []
    /// Cards whose turn ended with a Stop, and nothing since. Not a card
    /// whose title says it stopped: that is also what a dialog looks like, and
    /// keys typed into one pick options.
    private var stopped: Set<UUID> = []
    /// Stopped cards that have been sorted since: the only ones VIBES MODE may
    /// type into, and it knows which column they are in.
    private var settled: Set<UUID> = []
    /// What VIBES MODE last typed into each card, so its prompt is told apart
    /// from a person's when the hook reports it.
    private var vibesPrompts: [UUID: String] = [:]
    /// Cards whose plan dialog VIBES MODE has pressed Enter on and not yet
    /// seen go: a key sent before the dialog drew is sent again.
    private var approvingPlans: Set<UUID> = []
    private let storeURL: URL

    init() {
        let support = ProcessInfo.processInfo.environment["REEVE_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Reeve Terminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("board.json")
        load()

        terminals.onStateChange = { [weak self] id, running, exitCode in
            self?.processChanged(id, running: running, exitCode: exitCode)
        }
        terminals.onTitle = { [weak self] id, title in
            self?.titleChanged(id, title)
        }

        do {
            let server = try HookServer()
            server.onReady = { [weak self] port in
                self?.hookPort = port
                self?.drainStarts()
            }
            server.onEvent = { [weak self] id, body, reply in self?.receive(id, body, reply: reply) }
            server.vibesCards.set(Set(cards.filter(inVibes).map(\.id)))
            server.start()
            hooks = server
        } catch {
            NSLog("Reeve: hook server failed to start: \(error)")
        }

        Task {
            let env = await ShellEnvironment.load()
            self.environment = env
            self.drainStarts()
        }
    }

    // MARK: Reading the board

    func cards(in stage: Stage) -> [Card] {
        cards.filter { $0.stage == stage }
    }

    /// The board in reading order: column by column, top to bottom.
    var ordered: [Card] {
        Stage.allCases.flatMap { cards(in: $0) }
    }

    var selected: Card? {
        selectedId.flatMap { id in cards.first { $0.id == id } }
    }

    func card(_ id: UUID) -> Card? {
        cards.first { $0.id == id }
    }

    /// A card's name for the board: its title, else what its terminal says, else its folder.
    func displayTitle(_ card: Card) -> String {
        if !card.title.isEmpty { return card.title }
        if let title = terminalTitles[card.id].map(cleanTerminalTitle), !title.isEmpty, title.lowercased() != "claude code" {
            return title
        }
        return "New session"
    }

    /// Claude Code prefixes its title with a spinner glyph.
    private func cleanTerminalTitle(_ title: String) -> String {
        String(title.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Changing the board

    /// A card in a git repo gets its own worktree, on a branch from the
    /// folder's HEAD; anywhere else it works in the folder itself. It starts
    /// in the column its mode begins in.
    func create(cwd: String, title: String, prompt: String?, mode: StartMode, model: String? = nil, effort: String? = nil, vibes: Bool = false) {
        RecentFolders.add(cwd)
        // VIBES MODE flies over Planning unless its options say otherwise.
        let mode: StartMode = (vibes || self.vibes != nil) && vibesOptions.skipPlanning ? .build : mode
        var card = Card(title: title.trimmingCharacters(in: .whitespacesAndNewlines), cwd: cwd, stage: mode.stage)
        card.vibes = vibes ? true : nil
        card.startMode = mode
        card.model = model
        card.effort = effort
        Task {
            do {
                if let made = try await Worktrees.make(for: card.id, in: cwd, env: environment) {
                    card.cwd = made.cwd
                    card.repoPath = made.repo
                    card.worktreePath = made.path
                    card.branch = made.branch
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't make a worktree for this card"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Work in the Folder")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            cards.append(card)
            selectedId = card.id
            save()
            start(card, prompt: prompt)
        }
    }

    func select(_ id: UUID) {
        selectedId = id
        if let card = card(id), !live.contains(id) {
            start(card)
        }
        // The card left behind is nobody's to type into any more.
        vibesSweep()
    }

    /// Back to the board. The card's session keeps running.
    func dismissOpenCard() {
        selectedId = nil
        save()
        // Nobody is typing into it any more, so VIBES MODE can.
        vibesSweep()
    }

    func selectOffset(_ offset: Int) {
        let order = ordered
        guard !order.isEmpty else { return }
        let at = order.firstIndex { $0.id == selectedId } ?? (offset > 0 ? -1 : 0)
        select(order[(at + offset + order.count) % order.count].id)
    }

    func selectIndex(_ index: Int) {
        let order = ordered
        if order.indices.contains(index) { select(order[index].id) }
    }

    /// A person put the card here. It stays until they next speak to Claude.
    func move(_ id: UUID, to stage: Stage) {
        update(id) { card in
            guard card.stage != stage else { return }
            card.stage = stage
            card.stagePinned = true
        }
    }

    func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { card in
            card.title = title
            card.titledByPerson = !title.isEmpty
        }
    }

    /// Ends the card's session and removes its worktree. Every way a card
    /// leaves the board comes through here.
    func close(_ id: UUID) {
        let closing = card(id)
        terminals.close(id)
        // Only ever a worktree Reeve made: a card without one works in the
        // person's own folder.
        if let closing, let path = closing.worktreePath, let repo = closing.repoPath {
            let removal = WorktreeRemoval(path: path, repo: repo, branch: closing.branch)
            // Saved with the card's going, so a quit or crash before git is
            // done still sees it through at the next launch.
            pendingRemovals.append(removal)
            removeWorktree(removal)
        }
        pendingClassify[id]?.cancel()
        stopped.remove(id)
        settled.remove(id)
        approvingPlans.remove(id)
        vibesPrompts[id] = nil
        cards.removeAll { $0.id == id }
        live.remove(id)
        classifying.remove(id)
        terminalTitles[id] = nil
        // Back to the board, rather than opening (and starting) a neighbour.
        if selectedId == id { selectedId = nil }
        save()
    }

    private func removeWorktree(_ removal: WorktreeRemoval) {
        Task { [environment] in
            guard await Worktrees.remove(path: removal.path, branch: removal.branch, repo: removal.repo, env: environment) else { return }
            pendingRemovals.removeAll { $0 == removal }
            save()
        }
    }

    func restart(_ id: UUID) {
        guard let card = card(id) else { return }
        if live.contains(id) {
            // Started again once the exit comes back through processChanged.
            restarting.insert(id)
            terminals.stop(id)
        } else {
            start(card)
        }
    }

    func classifyNow(_ id: UUID) {
        scheduleClassify(id, lastMessage: nil, delay: 0)
    }

    func shutdown() {
        terminals.stopAll()
        hooks?.stop()
        save()
    }

    // MARK: Terminals

    private func start(_ card: Card, prompt: String? = nil) {
        guard let env = environment, let port = hookPort else {
            waitingToStart.append((card, prompt))
            return
        }
        var card = card
        // A session nobody has prompted has nothing to resume, and Claude Code
        // may already have claimed its id; start it under a new one.
        if !card.hasConversation {
            update(card.id) { $0.sessionId = UUID() }
            card = self.card(card.id) ?? card
        }
        terminals.start(card, prompt: prompt, env: env, hookPort: port)
    }

    private func drainStarts() {
        guard environment != nil, hookPort != nil else { return }
        let starts = waitingToStart
        waitingToStart = []
        for (card, prompt) in starts {
            if let current = self.card(card.id) { start(current, prompt: prompt) }
        }
    }

    private func processChanged(_ id: UUID, running: Bool, exitCode: Int32?) {
        if running {
            live.insert(id)
            return
        }
        live.remove(id)
        update(id) { card in
            if card.activity == .running || card.activity == .needsInput {
                card.activity = (exitCode ?? 0) == 0 ? .idle : .error
            }
            if let exitCode, exitCode != 0 { card.waitingOn = nil }
        }
        if restarting.remove(id) != nil, let card = card(id) {
            start(card)
        }
    }

    /// Claude Code spins a glyph at the front of its title while it works and
    /// puts ✳ there when it stops. No hook fires when a person presses Esc
    /// mid-turn, so the title is how a card learns its turn was interrupted.
    private func titleChanged(_ id: UUID, _ title: String) {
        terminalTitles[id] = title
        guard title.hasPrefix("\u{2733}"), card(id)?.activity == .running else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.terminalTitles[id]?.hasPrefix("\u{2733}") == true, self.card(id)?.activity == .running else { return }
            self.update(id) { card in
                card.activity = .idle
                card.waitingOn = nil
            }
            self.scheduleClassify(id, lastMessage: nil, delay: 0)
        }
    }

    // MARK: Hooks

    private func receive(_ cardId: UUID, _ body: Data, reply: VibesReply?) {
        guard let event = try? HookEvent.decode(body), let before = card(cardId) else { return }
        var effect = event.effect
        if reply != nil || (inVibes(before) && event.toolName == "ExitPlanMode") {
            // Answered before anyone could have been asked: the question went
            // back to Claude, and the plan dialog is about to be approved.
            // Nothing waits on a person.
            effect = HookEffect(activity: .running, waitingOn: .some(nil))
        }
        if event.hookEventName == "Stop" {
            stopped.insert(cardId)
        } else if effect.activity != nil {
            stopped.remove(cardId)
            settled.remove(cardId)
        }
        if let reply { noteVibesReply(reply, on: before) }
        if Vibes.showsPlanDialog(event), inVibes(before) { approvePlan(before) }
        if event.hookEventName == "PostToolUse", event.toolName == "ExitPlanMode" { approvingPlans.remove(cardId) }
        if event.hookEventName == "UserPromptSubmit", inVibes(before) { notePrompt(event.prompt, on: before) }
        if effect.startsConversation { turns[cardId, default: 0] += 1 }
        update(cardId) { card in
            // `/clear` starts a new session in the same terminal; follow it, so
            // a restart resumes the conversation that is actually on screen.
            if let session = UUID(uuidString: event.sessionId), session != card.sessionId {
                card.sessionId = session
            }
            if let path = event.transcriptPath { card.transcriptPath = path }
            if let activity = effect.activity { card.activity = activity }
            if let waiting = effect.waitingOn { card.waitingOn = waiting }
            if effect.startsConversation { card.hasConversation = true }
            if effect.unpinsStage { card.stagePinned = false }
        }
        if effect.classify {
            scheduleClassify(cardId, lastMessage: event.lastAssistantMessage, delay: 1.0)
        }
        updateBadge()
    }

    private func scheduleClassify(_ id: UUID, lastMessage: String?, delay: TimeInterval) {
        pendingClassify[id]?.cancel()
        pendingClassify[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.classify(id, lastMessage: lastMessage)
        }
    }

    private func classify(_ id: UUID, lastMessage: String?) async {
        guard let card = card(id), let env = environment else { return }
        guard let transcript = card.transcriptPath else {
            classifyErrors[id] = "No transcript yet"
            return
        }
        let turn = turns[id, default: 0]
        classifying.insert(id)
        defer { classifying.remove(id) }
        do {
            let result = try await StageClassifier.classify(card: card, transcriptPath: transcript, lastMessage: lastMessage, env: env)
            classifyErrors[id] = nil
            let current = turns[id, default: 0] == turn
            if !card.stagePinned, result.stage != card.stage, inVibes(card), vibes != nil {
                vibes?.moves += 1
                vibes?.note("“\(displayTitle(card))” → \(result.stage.label)")
            }
            update(id) { card in
                if !card.titledByPerson, !result.title.isEmpty { card.title = result.title }
                card.summary = result.summary
                if !card.stagePinned { card.stage = result.stage }
                // Only while nothing newer has happened: a prompt sent since
                // means the session has moved on from what was read.
                if current, card.activity == .needsReview || card.activity == .needsInput {
                    if let waiting = result.waitingOn {
                        card.activity = .needsInput
                        card.waitingOn = waiting
                    } else if card.activity == .needsReview {
                        card.waitingOn = nil
                    }
                }
            }
            updateBadge()
            if current, stopped.contains(id) {
                settled.insert(id)
                vibesFollowUp(id)
            }
        } catch {
            classifyErrors[id] = error.localizedDescription
            NSLog("Reeve: classifying \(id) failed: \(error.localizedDescription)")
        }
    }

    // MARK: VIBES MODE

    /// Whether VIBES MODE drives this card: the board's switch, or its own.
    /// Not once it has shipped; after that there is nothing left for it to do.
    func inVibes(_ card: Card) -> Bool {
        (vibes != nil || card.vibes == true) && card.shippedAt == nil
    }

    /// The header's switch. On, the board arms for two seconds and goes;
    /// off, it says what happened while you were out.
    func toggleVibes() {
        if let ledger = vibes {
            vibes = nil
            vibesArming = false
            let toast = "You’re back in the loop · \(count(ledger.moves, "move")) and \(count(ledger.merged, "merge")) while you were out"
            vibesToast = toast
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
                if self?.vibesToast == toast { self?.vibesToast = nil }
            }
        } else {
            vibes = VibesLedger()
            vibesToast = nil
            vibesArming = true
            // The two seconds are the undo: nothing is typed anywhere until
            // they are up, and nothing at all if the switch went off again.
            let since = vibes?.since
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.vibes?.since == since else { return }
                self.vibesArming = false
                self.vibesSweep()
            }
        }
        save()
    }

    /// A card in VIBES MODE on its own, or back out of it.
    func setVibes(_ id: UUID, _ on: Bool) {
        update(id) { card in
            card.vibes = on ? true : nil
            if on {
                card.shippedAt = nil
                card.vibesNudges = nil
            }
        }
        vibesSweep()
    }

    /// Every card whose turn has ended, given its next push. For when a card
    /// becomes VIBES MODE's to drive with nothing else happening to it.
    private func vibesSweep() {
        for id in settled { vibesFollowUp(id) }
    }

    /// What VIBES MODE does with a card whose turn just ended: answer the
    /// question it left, push it to its next column, or call it shipped.
    private func vibesFollowUp(_ id: UUID) {
        guard settled.contains(id), let card = card(id), inVibes(card), live.contains(id) else { return }
        // A person may have something half-typed in the open card; text and an
        // Enter from here would send both.
        guard selectedId != id else { return }
        // After a Stop, amber is only ever the classifier's: a question Claude
        // left in its message.
        guard card.activity == .needsReview || (card.activity == .needsInput && card.waitingOn != nil) else { return }
        settled.remove(id)
        let name = "“\(displayTitle(card))”"
        switch Vibes.next(stage: card.stage, waitingOn: card.activity == .needsInput ? card.waitingOn : nil, nudges: card.vibesNudges, options: vibesOptions) {
        case .answer:
            type(Vibes.noOneHome, into: id)
            update(id) { $0.vibesNudges = ($0.vibesNudges ?? VibesNudges(stage: $0.stage)).adding(from: $0.stage, ships: false) }
            vibes?.questionsSelfAnswered += 1
            vibes?.note("Claude answered its own question on \(name)")
        case .nudge(let prompt, let ships):
            type(prompt, into: id)
            update(id) { $0.vibesNudges = ($0.vibesNudges ?? VibesNudges(stage: $0.stage)).adding(from: $0.stage, ships: ships) }
            vibes?.reviewsSkipped += 1
            vibes?.note(ships
                ? "Shipping \(name) · \(vibesOptions.autoMerge ? "merging it" : "yours to merge")"
                : "Claude approved its own work on \(name) · nobody read it")
        case .shipped:
            update(id) { card in
                card.shippedAt = Date()
                card.vibesNudges = nil
            }
            Task { await landed(id, name: name) }
        case .giveUp:
            vibes?.note("Gave up pushing \(name) · left for you")
        }
        save()
    }

    /// Claude says it shipped; whether it is on main is git's to say. Only a
    /// branch found there is counted and stamped MERGED.
    private func landed(_ id: UUID, name: String) async {
        guard let card = card(id) else { return }
        var merged = false
        if let branch = card.branch, let repo = card.repoPath {
            merged = await Worktrees.isMerged(branch: branch, repo: repo, env: environment)
        }
        update(id) { $0.merged = merged }
        if merged {
            vibes?.merged += 1
            vibes?.note("Claude merged \(name) → main · 0 reviews")
        } else if vibesOptions.autoMerge {
            vibes?.note("Claude called \(name) shipped · not on main")
        } else {
            vibes?.note("Pull request open on \(name) · yours to merge")
        }
        justShipped.insert(id)
        shipBeat += 1
        save()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.justShipped.remove(id) }
    }

    /// The plan dialog, approved unread. Enter takes its first option, a yes,
    /// which is selected when it opens; a moment's wait lets it draw first.
    /// A key that beat the dialog is sent again, twice, and after that the
    /// card says it is waiting rather than claim to be running.
    /// Done even with the card open: a dialog has no half-typed line to spoil.
    private func approvePlan(_ card: Card) {
        let id = card.id
        let view = terminals.view(for: id)
        approvingPlans.insert(id)
        for delay in [0.6, 2.1, 3.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.approvingPlans.contains(id) == true else { return }
                view.send(txt: "\r")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
            guard let self, self.approvingPlans.remove(id) != nil else { return }
            self.update(id) { card in
                card.activity = .needsInput
                card.waitingOn = "Approve the plan?"
            }
            self.updateBadge()
        }
        vibes?.reviewsSkipped += 1
        vibes?.note("Claude approved its own plan on “\(displayTitle(card))” · nobody read it")
        save()
    }

    /// Types a line into the card's terminal and presses Enter, as a person
    /// would: the Enter on its own, a moment later, so Claude Code reads the
    /// line as typed rather than pasted.
    private func type(_ text: String, into id: UUID) {
        vibesPrompts[id] = text
        let view = terminals.view(for: id)
        view.send(txt: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { view.send(txt: "\r") }
    }

    private func noteVibesReply(_ reply: VibesReply, on card: Card) {
        vibes?.questionsSelfAnswered += 1
        vibes?.note("Claude answered its own question on “\(displayTitle(card))”")
    }

    /// A prompt VIBES MODE didn't type is a person stepping in: the HUD says
    /// so, and the card's pushes start again from nothing.
    private func notePrompt(_ prompt: String?, on card: Card) {
        if let typed = vibesPrompts[card.id], prompt?.trimmingCharacters(in: .whitespacesAndNewlines) == typed {
            vibesPrompts[card.id] = nil
            return
        }
        // The first prompt is the card's brief, not someone stepping in.
        guard card.hasConversation else { return }
        update(card.id) { $0.vibesNudges = nil }
        vibes?.humanApprovals += 1
        vibes?.note("You stepped in on “\(displayTitle(card))”")
    }

    private func markHot(_ stage: Stage) {
        hotStages.insert(stage)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.hotStages.remove(stage) }
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    // MARK: Persistence

    private func update(_ id: UUID, _ change: (inout Card) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        var card = cards[index]
        let before = card
        change(&card)
        guard card != before else { return }
        card.updatedAt = Date()
        cards[index] = card
        if card.stage != before.stage, vibes != nil { markHot(card.stage) }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(SavedBoard.self, from: data) else { return }
        // Nothing is running after a restart; a card left mid-turn says so.
        cards = saved.cards.map { card in
            var card = card
            if card.activity == .running { card.activity = .idle }
            return card
        }
        // Launch lands on the board; opening a card is what starts its session.
        updateBadge()
        vibes = saved.vibes
        vibesOptions = saved.vibesOptions ?? VibesOptions()
        pendingRemovals = saved.pendingRemovals ?? []
        pendingRemovals.forEach(removeWorktree)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(SavedBoard(cards: cards, selectedId: selectedId, pendingRemovals: pendingRemovals, vibes: vibes, vibesOptions: vibesOptions)) else { return }
        try? data.write(to: storeURL, options: .atomic)
        // Every change comes through here, so the hooks never answer off a stale list.
        hooks?.vibesCards.set(Set(cards.filter(inVibes).map(\.id)))
    }

    /// The Dock says how many cards are waiting on you.
    private func updateBadge() {
        let waiting = cards.filter { $0.activity == .needsInput }.count
        NSApp?.dockTile.badgeLabel = waiting > 0 ? String(waiting) : nil
    }

    private struct SavedBoard: Codable {
        var cards: [Card]
        var selectedId: UUID?
        /// Worktrees of closed cards that git hasn't finished removing.
        var pendingRemovals: [WorktreeRemoval]?
        var vibes: VibesLedger?
        var vibesOptions: VibesOptions?
    }

    private struct WorktreeRemoval: Codable, Equatable {
        var path: String
        var repo: String
        var branch: String?
    }
}

/// The folders cards were last started in, most recent first.
enum RecentFolders {
    private static let key = "recentFolders"

    static var all: [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func add(_ path: String) {
        var list = all.filter { $0 != path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: key)
    }
}
