import AppKit
import Combine
import ReeveKit
import SwiftUI

/// The board: every card, which one is open, and what keeps them up to date.
///
/// Cards learn what their session is doing from Claude Code's hooks, the
/// moment it happens. Their column follows from the same hooks — plan mode,
/// working, a turn that ended with changed code — and from whether the
/// branch has a pull request. A title and summary come from asking Claude
/// once each turn ends.
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
    /// Which tab each open card shows. Every card starts on its terminal.
    @Published private(set) var tabs: [UUID: CardTab] = [:]
    /// Cards with a plan nobody has looked at in the Plan tab yet.
    @Published private(set) var unseenPlans: Set<UUID> = []
    /// Raised when a card showing its changes may have new ones, so the tab
    /// reads them again. Only for that card, so others' tool calls cost nothing.
    @Published private(set) var changeTicks: [UUID: Int] = [:]
    @Published var showingNewCard = false
    @Published private(set) var environment: ShellEnvironment?

    let terminals = Terminals()
    /// Claude Code is showing a dialog on these cards — a permission prompt,
    /// a question, a plan to approve — so typing into them would answer it.
    private(set) var dialogOpen: Set<UUID> = []
    /// Cards sent a prompt that hasn't reached Claude yet. Their title can't
    /// say the turn was interrupted, because it hasn't started.
    private var awaitingPrompt: Set<UUID> = []
    /// Raised with each prompt sent, so only the latest one's timer acts.
    private var promptsSent: [UUID: Int] = [:]
    private var server: LocalServer?
    private var hookPort: UInt16?
    /// Raised by every prompt, so a classification that a newer turn has
    /// overtaken leaves the card's activity alone.
    private var turns: [UUID: Int] = [:]
    private var pendingClassify: [UUID: Task<Void, Never>] = [:]
    /// Cards whose pull request is being looked up right now.
    private var findingPullRequests: Set<UUID> = []
    private var restarting: Set<UUID> = []
    private var pendingRemovals: [WorktreeRemoval] = []
    /// Starts waiting on the shell environment or the hook port.
    private var waitingToStart: [(Card, String?)] = []
    private let dataDir: URL
    private let storeURL: URL

    init() {
        dataDir = DataDirectory.url()
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        storeURL = dataDir.appendingPathComponent("board.json")
        load()

        terminals.onStateChange = { [weak self] id, running, exitCode in
            self?.processChanged(id, running: running, exitCode: exitCode)
        }
        terminals.onTitle = { [weak self] id, title in
            self?.titleChanged(id, title)
        }

        do {
            let server = try LocalServer()
            server.onReady = { [weak self, weak server] port in
                guard let self, let server else { return }
                self.hookPort = port
                // How `reeve` finds this app.
                do {
                    try ServerInfo(port: port, pid: ProcessInfo.processInfo.processIdentifier, token: server.token).write(dataDir: self.dataDir)
                } catch {
                    NSLog("Reeve: couldn't write server.json: \(error)")
                }
                self.drainStarts()
            }
            server.onEvent = { [weak self] id, body in self?.receive(id, body) }
            server.onRequest = { [weak self] request in
                guard let self else { return .error(503, APIError("shutting down")) }
                return await APIRouter.handle(request, board: self)
            }
            server.start()
            self.server = server
        } catch {
            NSLog("Reeve: local server failed to start: \(error)")
        }

        Task {
            let env = await ShellEnvironment.load()
            self.environment = env
            self.drainStarts()
            for card in self.cards { self.refreshPullRequest(card.id) }
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

    /// Starts a card from the new card sheet, and opens it. When git can't
    /// make a worktree, asks whether to work in the folder instead.
    func create(cwd: String, title: String, prompt: String?, mode: StartMode, model: String? = nil, effort: String? = nil) {
        Task {
            do {
                _ = try await createCard(cwd: cwd, title: title, prompt: prompt, mode: mode, model: model, effort: effort, open: true, inFolder: false)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't make a worktree for this card"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Work in the Folder")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                _ = try? await createCard(cwd: cwd, title: title, prompt: prompt, mode: mode, model: model, effort: effort, open: true, inFolder: true)
            }
        }
    }

    /// A card in a git repo gets its own worktree, on a branch from the
    /// folder's HEAD; anywhere else it works in the folder itself. It starts
    /// in the column its mode begins in. When git can't make the worktree,
    /// the card works in the folder if `inFolder`, else this throws.
    @discardableResult
    func createCard(cwd: String, title: String, prompt: String?, mode: StartMode, model: String?, effort: String?,
                    open: Bool, inFolder: Bool) async throws -> Card {
        var card = Card(title: title.trimmingCharacters(in: .whitespacesAndNewlines), cwd: cwd, stage: mode.stage)
        card.startMode = mode
        card.model = model
        card.effort = effort
        do {
            if let made = try await Worktrees.make(for: card.id, in: cwd, env: environment) {
                card.cwd = made.cwd
                card.repoPath = made.repo
                card.worktreePath = made.path
                card.branch = made.branch
                card.baseCommit = made.base
            }
        } catch {
            guard inFolder else { throw error }
        }
        RecentFolders.add(cwd)
        let prompted = prompt.map { !$0.isEmpty } ?? false
        // Working from the moment it's asked, so a `reeve card wait` straight
        // after doesn't find it idle before Claude has read the prompt.
        if prompted { card.activity = .running }
        cards.append(card)
        if open { selectedId = card.id }
        save()
        if prompted { expectPrompt(card.id) }
        start(card, prompt: prompt)
        return card
    }

    func select(_ id: UUID) {
        selectedId = id
        refreshPullRequest(id)
        // Whatever Claude is asking is in the terminal.
        if card(id)?.activity == .needsInput { tabs[id] = .terminal }
        if let card = card(id), !live.contains(id) {
            start(card)
        }
    }

    /// Back to the board. The card's session keeps running.
    func dismissOpenCard() {
        selectedId = nil
        save()
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

    func tab(_ id: UUID) -> CardTab {
        tabs[id] ?? .terminal
    }

    func show(_ tab: CardTab, for id: UUID) {
        tabs[id] = tab
        if tab == .plan { unseenPlans.remove(id) }
    }

    /// The text of the card's plan: its file, which may have been edited since
    /// Claude asked for approval, else what the approval carried. A card that
    /// missed the hook finds its plan in the transcript.
    func loadPlan(_ id: UUID) async -> String? {
        guard var card = card(id) else { return nil }
        if card.plan == nil, card.planPath == nil, let transcript = card.transcriptPath {
            let found = await Task.detached { PlanSighting.latest(inTranscriptAt: transcript) }.value
            if let found {
                update(id) { card in
                    card.plan = found.text
                    card.planPath = found.path
                }
                card = self.card(id) ?? card
            }
        }
        if let path = card.planPath {
            let text = await Task.detached { try? String(contentsOfFile: path, encoding: .utf8) }.value
            if let text, !text.isEmpty { return text }
        }
        return card.plan
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
        cards.removeAll { $0.id == id }
        live.remove(id)
        dialogOpen.remove(id)
        awaitingPrompt.remove(id)
        classifying.remove(id)
        terminalTitles[id] = nil
        tabs[id] = nil
        unseenPlans.remove(id)
        changeTicks[id] = nil
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

    /// What closing the card would lose that a person might want: its live
    /// session, and work in its worktree not yet committed. Nil when nothing.
    func closeWouldLose(_ id: UUID) async -> String? {
        guard let card = card(id) else { return nil }
        var reasons: [String] = []
        if live.contains(id) { reasons.append("its session is live") }
        if let path = card.worktreePath {
            let changes = await Worktrees.uncommittedChanges(at: path, env: environment)
            if changes > 0 { reasons.append("its worktree has \(changes) uncommitted change\(changes == 1 ? "" : "s")") }
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: " and ")
    }

    /// Starts the card's session if it isn't running, without opening the card.
    func startIfNeeded(_ id: UUID, prompt: String? = nil) {
        guard let card = card(id), !live.contains(id), !starting.contains(id) else { return }
        if let prompt, !prompt.isEmpty { sendingPrompt(id) }
        start(self.card(id) ?? card, prompt: prompt)
    }

    /// Cards waiting for the shell environment or the server before they start.
    var starting: Set<UUID> {
        Set(waitingToStart.map(\.0.id))
    }

    /// Sends the card's Claude a message: typed into its terminal when the
    /// session is live, else as the prompt the session starts with. Not while
    /// a dialog is up unless `force`, since the text would answer it.
    func reply(_ id: UUID, text: String, force: Bool) throws -> ReplyResponse.Delivery {
        guard card(id) != nil else { throw APIError("no such card") }
        if starting.contains(id) {
            throw APIError("the session is still starting", detail: "try again in a moment")
        }
        guard live.contains(id) else {
            startIfNeeded(id, prompt: text)
            return .started
        }
        if dialogOpen.contains(id), !force {
            let showing = card(id)?.waitingOn.map { ": \($0)" } ?? ""
            throw APIError("Claude is showing a dialog\(showing)", detail: "answer it in the app, or pass --force to type into it anyway")
        }
        sendingPrompt(id)
        terminals.send(text, to: id)
        return .typed
    }

    /// The card is busy from the moment a prompt goes out, until its hooks say otherwise.
    private func sendingPrompt(_ id: UUID) {
        // Typed into a turn in progress, the message waits in Claude Code's
        // queue, which a long tool call can hold for minutes: not a stall.
        let midTurn = live.contains(id) && card(id)?.activity == .running
        update(id) { card in
            card.activity = .running
            card.waitingOn = nil
        }
        if !midTurn { expectPrompt(id) }
    }

    /// The title check for interrupted turns waits for the prompt to arrive.
    /// A prompt that hasn't arrived in half a minute is held up by something
    /// in the terminal that fires no hook (trusting a new folder, logging in),
    /// so the card says it needs you rather than look busy forever.
    private func expectPrompt(_ id: UUID) {
        awaitingPrompt.insert(id)
        promptsSent[id, default: 0] += 1
        let sent = promptsSent[id]
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.promptsSent[id] == sent, self.awaitingPrompt.remove(id) != nil,
                  self.live.contains(id), self.card(id)?.activity == .running else { return }
            self.dialogOpen.insert(id)
            self.update(id) { card in
                card.activity = .needsInput
                card.waitingOn = "Something in the terminal needs you before Claude gets the message"
            }
            self.updateBadge()
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
        server?.stop()
        ServerInfo.remove(dataDir: dataDir, pid: ProcessInfo.processInfo.processIdentifier)
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
        dialogOpen.remove(id)
        awaitingPrompt.remove(id)
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
        guard title.hasPrefix("\u{2733}"), card(id)?.activity == .running, !awaitingPrompt.contains(id) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.terminalTitles[id]?.hasPrefix("\u{2733}") == true, self.card(id)?.activity == .running,
                  !self.awaitingPrompt.contains(id) else { return }
            self.update(id) { card in
                card.activity = .idle
                card.waitingOn = nil
            }
            self.scheduleClassify(id, lastMessage: nil, delay: 0)
        }
    }

    // MARK: Hooks

    private func receive(_ cardId: UUID, _ body: Data) {
        guard let event = try? HookEvent.decode(body), card(cardId) != nil else { return }
        let effect = event.effect
        if effect.startsConversation {
            turns[cardId, default: 0] += 1
            awaitingPrompt.remove(cardId)
        }
        if effect.activity == .needsInput {
            dialogOpen.insert(cardId)
        } else if effect.activity != nil {
            dialogOpen.remove(cardId)
        }
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
            if let mode = event.permissionMode { card.permissionMode = mode }
            if effect.editsFiles { card.lastEditAt = Date() }
            if effect.working { card.stage = card.stage(running: true, hasChanges: false) }
            if let plan = effect.plan {
                let merged = plan.merged(over: PlanSighting(text: card.plan, path: card.planPath))
                card.plan = merged.text
                card.planPath = merged.path
            }
        }
        let showing = selectedId == cardId ? tab(cardId) : nil
        if effect.plan != nil, showing != .plan { unseenPlans.insert(cardId) }
        if showing == .changes, event.hookEventName == "PostToolUse" || event.hookEventName == "Stop" {
            changeTicks[cardId, default: 0] += 1
        }
        if effect.classify {
            // Looks up the pull request too: a turn is where Claude opens one.
            scheduleClassify(cardId, lastMessage: event.lastAssistantMessage, delay: 1.0)
        }
        updateBadge()
    }

    private func scheduleClassify(_ id: UUID, lastMessage: String?, delay: TimeInterval) {
        pendingClassify[id]?.cancel()
        pendingClassify[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.settleStage(id)
            guard !Task.isCancelled else { return }
            await self?.classify(id, lastMessage: lastMessage)
        }
    }

    /// Puts a card whose turn is over in its column: testing if the code has
    /// changed, release once its branch has a pull request.
    private func settleStage(_ id: UUID) async {
        guard let card = card(id) else { return }
        let turn = turns[id, default: 0]
        var changed = card.lastEditAt != nil
        if !changed { changed = await Worktrees.uncommittedChanges(at: card.cwd, env: environment) > 0 }
        if !changed, let base = card.baseCommit {
            changed = await Worktrees.commits(at: card.cwd, since: base, env: environment) > 0
        }
        await findPullRequest(id)
        // A prompt sent since means the session is working again.
        guard turns[id, default: 0] == turn, self.card(id)?.activity != .running else { return }
        update(id) { card in
            card.stage = card.stage(running: false, hasChanges: changed)
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
            update(id) { card in
                if !card.titledByPerson, !result.title.isEmpty { card.title = result.title }
                card.summary = result.summary
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
        } catch {
            classifyErrors[id] = error.localizedDescription
            NSLog("Reeve: classifying \(id) failed: \(error.localizedDescription)")
        }
    }

    // MARK: Pull requests

    /// Looks up the pull request from the branch the card's worktree is on,
    /// which Claude may have switched from the one Reeve made. When gh can't
    /// say, the card keeps the one it had.
    private func refreshPullRequest(_ id: UUID) {
        Task { await findPullRequest(id) }
    }

    /// A pull request found open or merged moves the card to Release.
    func findPullRequest(_ id: UUID) async {
        guard let card = card(id), let worktree = card.worktreePath, let env = environment,
              !findingPullRequests.contains(id), FileManager.default.fileExists(atPath: worktree) else { return }
        findingPullRequests.insert(id)
        defer { findingPullRequests.remove(id) }
        // Never written back: closing the card deletes `card.branch`.
        guard let branch = await Worktrees.currentBranch(at: worktree, env: env) ?? card.branch,
              let found = await PullRequests.find(branch: branch, in: worktree, env: env) else { return }
        update(id) { card in
            card.pullRequest = found
            if card.hasLivePullRequest, !card.stagePinned { card.stage = .release }
        }
    }

    /// The card as `reeve` sees it.
    func apiCard(_ card: Card) -> APICard {
        APICard(card: card, live: live.contains(card.id), starting: starting.contains(card.id),
                dialogOpen: dialogOpen.contains(card.id), displayTitle: displayTitle(card))
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
        pendingRemovals = saved.pendingRemovals ?? []
        pendingRemovals.forEach(removeWorktree)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(SavedBoard(cards: cards, selectedId: selectedId, pendingRemovals: pendingRemovals)) else { return }
        try? data.write(to: storeURL, options: .atomic)
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
