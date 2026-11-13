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
    let previews = Previews()
    private var hooks: HookServer?
    private var hookPort: UInt16?
    /// Raised by every prompt, so a classification that a newer turn has
    /// overtaken leaves the card's activity alone.
    private var turns: [UUID: Int] = [:]
    private var pendingClassify: [UUID: Task<Void, Never>] = [:]
    /// Cards whose pull request is being looked up right now.
    private var findingPullRequests: Set<UUID> = []
    private var restarting: Set<UUID> = []
    /// Cards waiting on a person because of a notification (a permission
    /// prompt, often a subagent's) rather than a question Claude asked.
    private var notifiedInput: Set<UUID> = []
    private var pendingRemovals: [WorktreeRemoval] = []
    /// Starts waiting on the shell environment or the hook port.
    private var waitingToStart: [(Card, String?)] = []
    private let storeURL: URL
    /// Where each card's review goes to Claude and its replies come back.
    private let reviewsDir: URL

    init() {
        let support = ProcessInfo.processInfo.environment["REEVE_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Reeve Terminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("board.json")
        reviewsDir = support.appendingPathComponent("reviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: reviewsDir, withIntermediateDirectories: true)
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
            server.onEvent = { [weak self] id, body in self?.receive(id, body) }
            server.onGloss = { [weak self] id, body, respond in
                guard let self else { return respond("Reeve is closing") }
                self.hostGloss(id, body, respond: respond)
            }
            server.start()
            hooks = server
        } catch {
            NSLog("Reeve: hook server failed to start: \(error)")
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

    /// A card in a git repo gets its own worktree, on a branch from the
    /// folder's HEAD; anywhere else it works in the folder itself. It starts
    /// in the column its mode begins in.
    func create(cwd: String, title: String, prompt: String?, mode: StartMode, model: String? = nil, effort: String? = nil) {
        RecentFolders.add(cwd)
        var card = Card(title: title.trimmingCharacters(in: .whitespacesAndNewlines), cwd: cwd, stage: mode.stage)
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
                    card.baseCommit = made.base
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

    /// The card's `GLOSS_HOST`, once the hook server is up.
    func glossHost(for id: UUID) -> String? {
        hookPort.map { Gloss.hostURL(port: $0, cardId: id) }
    }

    /// Shows `url` in the card's Preview tab, under review in Gloss.
    func openPreview(_ id: UUID, url: URL) {
        guard let card = card(id), let env = environment else { return }
        let preview = previews.preview(for: id)
        if preview.isRunning { preview.navigate(url) } else { preview.open(url, cwd: card.cwd, env: env) }
    }

    /// A `gloss open` in the card, asking to show its page here rather than in
    /// a window of Gloss's own. Gloss opens its window instead if this says no.
    private func hostGloss(_ id: UUID, _ body: Data, respond: @escaping (String?) -> Void) {
        guard card(id) != nil else { return respond("no such card") }
        guard let request = try? JSONDecoder().decode(Gloss.OpenRequest.self, from: body),
              let url = URL(string: request.url) else { return respond("Reeve could not read the request") }
        guard request.name.isEmpty else { return respond("a card's preview holds one session, without --name") }
        guard let env = environment else { return respond("Reeve is still starting") }
        previews.preview(for: id).open(url, cwd: request.cwd, live: request.live, env: env) { [weak self] error in
            if error == nil { self?.tabs[id] = .preview }
            respond(error)
        }
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
        previews.close(id)
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
        classifying.remove(id)
        terminalTitles[id] = nil
        tabs[id] = nil
        unseenPlans.remove(id)
        changeTicks[id] = nil
        try? FileManager.default.removeItem(at: reviewURL(id))
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
        previews.stopAll()
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
        terminals.start(card, prompt: prompt, env: env, hookPort: port, reviewsDir: reviewsDir.path)
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
            if card.activity == .running || card.activity == .needsInput || card.activity == .waiting {
                card.activity = (exitCode ?? 0) == 0 ? .idle : .error
            }
            card.background = nil
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

    private func receive(_ cardId: UUID, _ body: Data) {
        guard let event = try? HookEvent.decode(body), card(cardId) != nil else { return }
        let effect = event.effect
        if effect.startsConversation { turns[cardId, default: 0] += 1 }
        let askedByNotification = notifiedInput.contains(cardId)
        if effect.activity != nil {
            if event.hookEventName == "Notification" { notifiedInput.insert(cardId) } else { notifiedInput.remove(cardId) }
        }
        update(cardId) { card in
            // A subagent working again means the prompt that stopped it was answered.
            if effect.bySubagent, let activity = HookEvent.activityAfterSubagentWork(card.activity, askedByNotification: askedByNotification, waitingOnBackground: card.background != nil) {
                card.activity = activity
                card.waitingOn = nil
                notifiedInput.remove(cardId)
            }
            // `/clear` starts a new session in the same terminal; follow it, so
            // a restart resumes the conversation that is actually on screen.
            if let session = UUID(uuidString: event.sessionId), session != card.sessionId {
                card.sessionId = session
            }
            if let path = event.transcriptPath { card.transcriptPath = path }
            if let activity = effect.activity { card.activity = activity }
            if let waiting = effect.waitingOn { card.waitingOn = waiting }
            if let background = effect.background { card.background = background.isEmpty ? nil : background }
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
        if event.hookEventName == "Stop" || (event.hookEventName == "PostToolUse" && event.toolInput?.filePath == reviewURL(cardId).path) {
            readReplies(cardId)
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
        // A prompt sent since means the session is working again; a session
        // waiting on its agents is still in progress.
        guard turns[id, default: 0] == turn, let activity = self.card(id)?.activity, activity != .running, activity != .waiting else { return }
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
                // means the session has moved on from what was read. A card
                // waiting on its agents is never a question, whatever Claude
                // said as it launched them.
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

    // MARK: Review

    func reviewURL(_ id: UUID) -> URL {
        reviewsDir.appendingPathComponent(id.uuidString + ".json")
    }

    /// Why a review can't go to the card's session right now, if it can't.
    /// While Claude works it can: Claude Code queues the prompt.
    func reviewBlocker(_ id: UUID) -> String? {
        guard let card = card(id) else { return nil }
        if card.activity == .needsInput { return "Claude is waiting on you in the terminal. Answer it first." }
        if card.permissionMode == "plan" { return "Claude is in plan mode, where it can't change code. Leave plan mode in the terminal first." }
        return nil
    }

    /// A new comment on a line. Sent now, or kept as part of a review.
    func comment(on anchor: ReviewAnchor, _ body: String, in id: UUID, send: Bool) {
        let thread = ReviewThread(anchor: anchor, messages: [ReviewMessage(author: .person, body: body, pending: true)])
        updateReview(id) { $0.append(thread) }
        if send { submitReview(id, only: thread.id) }
    }

    /// The person answers a thread. Sent now, or kept as part of a review.
    func reply(to threadId: UUID, _ body: String, in id: UUID, send: Bool) {
        updateReview(id) { threads in
            guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return }
            threads[i].messages.append(ReviewMessage(author: .person, body: body, pending: true))
            threads[i].resolved = false
        }
        if send { submitReview(id, only: threadId) }
    }

    /// Drops a thread's unsent drafts, and the thread with them if that was all it had.
    func discardDrafts(_ threadId: UUID, in id: UUID) {
        updateReview(id) { threads in
            guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return }
            threads[i].messages.removeAll { $0.pending }
            if threads[i].messages.isEmpty { threads.remove(at: i) }
        }
    }

    func resolve(_ threadId: UUID, _ resolved: Bool, in id: UUID) {
        updateReview(id) { threads in
            guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return }
            threads[i].resolved = resolved
        }
    }

    /// Sends the card's drafts to Claude (or one thread's): writes every
    /// thread waiting on a reply to the review file and asks the session,
    /// woken if it is asleep, to answer them there.
    func submitReview(_ id: UUID, only threadId: UUID? = nil) {
        guard reviewBlocker(id) == nil else { return }
        // A reply already in the file would go with the rewrite.
        readReplies(id)
        updateReview(id) { threads in
            for i in threads.indices where threadId == nil || threads[i].id == threadId {
                for m in threads[i].messages.indices { threads[i].messages[m].pending = false }
            }
        }
        guard let card = card(id), let threads = card.review, threads.contains(where: { $0.awaitingReply && !$0.resolved }) else { return }
        let url = reviewURL(id)
        do {
            try ReviewFile.encode(threads).write(to: url, options: .atomic)
        } catch {
            NSLog("Reeve: writing the review for \(id) failed: \(error.localizedDescription)")
            return
        }
        let prompt = ReviewFile.prompt(path: url.path)
        if live.contains(id) {
            terminals.send(prompt, to: id)
        } else {
            start(card, prompt: prompt)
        }
    }

    /// Takes in whatever Claude has replied in the card's review file.
    private func readReplies(_ id: UUID) {
        guard card(id)?.review?.contains(where: \.awaitingReply) == true,
              let data = try? Data(contentsOf: reviewURL(id)) else { return }
        updateReview(id) { $0 = ReviewFile.merge(data, into: $0) }
    }

    private func updateReview(_ id: UUID, _ change: (inout [ReviewThread]) -> Void) {
        update(id) { card in
            var threads = card.review ?? []
            change(&threads)
            card.review = threads.isEmpty ? nil : threads
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
    private func findPullRequest(_ id: UUID) async {
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
            if card.activity == .running || card.activity == .waiting { card.activity = .idle }
            card.background = nil
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
