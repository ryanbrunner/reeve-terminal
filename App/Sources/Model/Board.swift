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
    /// The folders a new card can start in.
    @Published private(set) var repos: [Repo] = []
    /// The repo picked for the last new card, so a run of cards starts in
    /// the same one.
    @Published var pickedRepoId: UUID? {
        didSet { UserDefaults.standard.set(pickedRepoId?.uuidString, forKey: "newCardRepo") }
    }
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
    /// Cards whose terminal has the plan dialog open: Claude asked for its
    /// plan to be approved, and nothing has happened since.
    @Published private(set) var planDialogs: Set<UUID> = []
    /// Cards whose plan a person approved from the Plan tab, while Reeve picks
    /// the option in the dialog and until Claude Code says it took.
    @Published private(set) var acceptingPlans: Set<UUID> = []
    /// Cards whose plan dialog VIBES MODE has pressed Enter on and not yet
    /// seen go: a key sent before the dialog drew is sent again.
    @Published private(set) var approvingPlans: Set<UUID> = []
    /// Raised when a card showing its changes may have new ones, so the tab
    /// reads them again. Only for that card, so others' tool calls cost nothing.
    @Published private(set) var changeTicks: [UUID: Int] = [:]
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
    let previews = Previews()
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
    /// Cards waiting on a person because of a notification (a permission
    /// prompt, often a subagent's) rather than a question Claude asked.
    private var notifiedInput: Set<UUID> = []
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
    private let dataDir: URL
    private let storeURL: URL
    /// Where each card's review goes to Claude and its replies come back.
    private let reviewsDir: URL

    init() {
        dataDir = DataDirectory.url()
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        storeURL = dataDir.appendingPathComponent("board.json")
        reviewsDir = dataDir.appendingPathComponent("reviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: reviewsDir, withIntermediateDirectories: true)
        pickedRepoId = UserDefaults.standard.string(forKey: "newCardRepo").flatMap(UUID.init)
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
            server.onEvent = { [weak self] id, body, reply in self?.receive(id, body, reply: reply) }
            server.vibesCards.set(Set(cards.filter(inVibes).map(\.id)))
            server.onGloss = { [weak self] id, body, respond in
                guard let self else { return respond("Reeve is closing") }
                self.hostGloss(id, body, respond: respond)
            }
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
    func create(cwd: String, title: String, prompt: String?, mode: StartMode, model: String? = nil, effort: String? = nil, vibes: Bool = false) {
        Task {
            do {
                _ = try await createCard(cwd: cwd, title: title, prompt: prompt, mode: mode, model: model, effort: effort, vibes: vibes, open: true, inFolder: false)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't make a worktree for this card"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Work in the Folder")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                _ = try? await createCard(cwd: cwd, title: title, prompt: prompt, mode: mode, model: model, effort: effort, vibes: vibes, open: true, inFolder: true)
            }
        }
    }

    /// The repos a new card can start in: those whose folder is still there.
    /// Settings shows the rest.
    var availableRepos: [Repo] {
        repos.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The repo a new card starts in: the one picked last while it is still
    /// available, else the first.
    var pickedRepo: Repo? {
        let available = availableRepos
        return available.first { $0.id == pickedRepoId } ?? available.first
    }

    /// The repo for `path`, added to the list if it isn't on it yet.
    @discardableResult
    func addRepo(path: String) -> Repo {
        let repo = Repo(path: path)
        if let existing = repos.first(where: { $0.path == repo.path }) { return existing }
        repos.append(repo)
        save()
        return repo
    }

    /// Takes a repo off the list. Its cards keep working where they are.
    func removeRepo(_ id: UUID) {
        repos.removeAll { $0.id == id }
        save()
    }

    /// A card in a git repo gets its own worktree, on a branch from the
    /// folder's HEAD; anywhere else it works in the folder itself. It starts
    /// in the column its mode begins in. When git can't make the worktree,
    /// the card works in the folder if `inFolder`, else this throws.
    @discardableResult
    func createCard(cwd: String, title: String, prompt: String?, mode: StartMode, model: String?, effort: String?,
                    vibes: Bool = false, open: Bool, inFolder: Bool) async throws -> Card {
        // VIBES MODE flies over Planning unless its options say otherwise.
        let mode: StartMode = (vibes || self.vibes != nil) && vibesOptions.skipPlanning ? .build : mode
        var card = Card(title: title.trimmingCharacters(in: .whitespacesAndNewlines), cwd: cwd, stage: mode.stage)
        card.vibes = vibes ? true : nil
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
        stopped.remove(id)
        settled.remove(id)
        approvingPlans.remove(id)
        planDialogs.remove(id)
        acceptingPlans.remove(id)
        vibesPrompts[id] = nil
        cards.removeAll { $0.id == id }
        live.remove(id)
        dialogOpen.remove(id)
        awaitingPrompt.remove(id)
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
        previews.stopAll()
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
        planDialogs.remove(id)
        acceptingPlans.remove(id)
        dialogOpen.remove(id)
        awaitingPrompt.remove(id)
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
        if Vibes.showsPlanDialog(event) {
            planDialogs.insert(cardId)
        } else if event.closesPlanDialog {
            planDialogs.remove(cardId)
            acceptingPlans.remove(cardId)
        }
        if Vibes.showsPlanDialog(event), inVibes(before) { approvePlan(before) }
        if event.hookEventName == "PostToolUse", event.toolName == "ExitPlanMode" { approvingPlans.remove(cardId) }
        if event.hookEventName == "UserPromptSubmit", inVibes(before) { notePrompt(event.prompt, on: before) }
        if effect.startsConversation {
            turns[cardId, default: 0] += 1
            awaitingPrompt.remove(cardId)
        }
        if effect.activity == .needsInput {
            dialogOpen.insert(cardId)
        } else if effect.activity != nil {
            dialogOpen.remove(cardId)
        }
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
            if event.putsUpNewPlan { card.planApproved = nil }
            if event.approvesPlan { card.planApproved = true }
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
            update(id) { $0.vibesNudges = ($0.vibesNudges ?? VibesNudges(stage: $0.stage)).answering(in: $0.stage) }
            vibes?.questionsSelfAnswered += 1
            vibes?.note("Claude answered its own question on \(name)")
        case .nudge(let prompt, let step):
            push(id, prompt, step: step, name: name)
        case .checkShipped:
            Task { await checkShipped(id, name: name) }
        case .giveUp:
            vibes?.note("Gave up pushing \(name) · left for you")
        }
        save()
    }

    /// Types the next step in, and remembers it was said.
    private func push(_ id: UUID, _ prompt: String, step: VibesStep.Kind, name: String) {
        type(prompt, into: id)
        update(id) { $0.vibesNudges = ($0.vibesNudges ?? VibesNudges(stage: $0.stage)).adding(from: $0.stage, step: step) }
        vibes?.reviewsSkipped += 1
        vibes?.note(step == .ship
            ? "Shipping \(name) · \(vibesOptions.autoMerge ? "merging it" : "yours to merge")"
            : "Claude approved its own work on \(name) · nobody read it")
        save()
    }

    /// Claude was told to ship; whether it did is git's and GitHub's to say,
    /// not Claude's. Landed, the card is done: merged when its branch is on
    /// main, or with merging left to a person, when its pull request is up.
    /// Not landed, it is told again, until the pushes run out.
    private func checkShipped(_ id: UUID, name: String) async {
        guard let card = card(id) else { return }
        var merged = card.pullRequest?.state == .merged
        if !merged, let branch = card.branch, let repo = card.repoPath {
            merged = await Worktrees.isMerged(branch: branch, repo: repo, env: environment)
        }
        guard let card = self.card(id), inVibes(card) else { return }
        guard merged || (!vibesOptions.autoMerge && card.hasLivePullRequest) else {
            push(id, Vibes.ship(vibesOptions), step: .ship, name: name)
            return
        }
        update(id) { card in
            card.shippedAt = Date()
            card.merged = merged
            card.vibesNudges = nil
        }
        if merged {
            vibes?.merged += 1
            vibes?.note("Claude merged \(name) → main · 0 reviews")
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

    /// A person approves the plan from the Plan tab: Reeve picks the dialog's
    /// auto mode option, as they would in the terminal. The dialog is read off
    /// the screen, so the selection moves from wherever it is, and nothing is
    /// typed until the dialog is seen, nor Enter pressed until its selection
    /// is the approval. Otherwise the button comes back.
    func acceptPlan(_ id: UUID) {
        guard planDialogs.contains(id), live.contains(id), !acceptingPlans.contains(id), !approvingPlans.contains(id) else { return }
        acceptingPlans.insert(id)
        choosePlanApproval(id, tries: 3)
    }

    private func choosePlanApproval(_ id: UUID, tries: Int) {
        guard acceptingPlans.contains(id) else { return }
        guard let dialog = PlanDialog.find(onScreen: terminals.screen(id)) else {
            // Not drawn yet, perhaps.
            if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.choosePlanApproval(id, tries: tries - 1) }
            } else {
                acceptingPlans.remove(id)
            }
            return
        }
        let target = dialog.approval
        let view = terminals.view(for: id)
        // One key a write, so Claude Code reads each arrow as its own.
        let moves = dialog.moves(to: target)
        for (i, key) in moves.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * Double(i)) { [weak self] in
                guard self?.acceptingPlans.contains(id) == true else { return }
                view.send(txt: key)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * Double(moves.count) + 0.3) { [weak self] in
            guard let self, self.acceptingPlans.contains(id) else { return }
            guard PlanDialog.find(onScreen: self.terminals.screen(id))?.selected == target else {
                self.acceptingPlans.remove(id)
                return
            }
            view.send(txt: "\r")
            // A dialog that took the key says so with `ExitPlanMode`'s
            // PostToolUse; one that didn't gets its button back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.acceptingPlans.remove(id) }
        }
    }

    /// Types a line into the card's terminal and submits it, as a person would.
    private func type(_ text: String, into id: UUID) {
        vibesPrompts[id] = text
        terminals.send(text, to: id)
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
        if card.stage != before.stage, vibes != nil {
            markHot(card.stage)
            // A card that moved itself; a person's move pins it.
            if !card.stagePinned {
                vibes?.moves += 1
                vibes?.note("“\(displayTitle(card))” → \(card.stage.label)")
            }
        }
        save()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? decoder.decode(SavedBoard.self, from: data) else {
            repos = seededRepos()
            return
        }
        // Nothing is running after a restart; a card left mid-turn says so.
        cards = saved.cards.map { card in
            var card = card
            if card.activity == .running || card.activity == .waiting { card.activity = .idle }
            card.background = nil
            return card
        }
        // Before anything below saves the board.
        repos = saved.repos ?? seededRepos()
        // Launch lands on the board; opening a card is what starts its session.
        updateBadge()
        vibes = saved.vibes
        vibesOptions = saved.vibesOptions ?? VibesOptions()
        pendingRemovals = saved.pendingRemovals ?? []
        pendingRemovals.forEach(removeWorktree)
    }

    /// A board saved before there were repos starts with the folders its
    /// cards were made in, and the ones the new card sheet remembered. Not
    /// a scratch folder in /tmp, which is where smoke tests start cards.
    private func seededRepos() -> [Repo] {
        let recent = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        return Repo.seeded(from: recent + cards.compactMap { $0.repoPath ?? ($0.worktreePath == nil ? $0.cwd : nil) })
            .filter { !$0.path.hasPrefix("/tmp/") && !$0.path.hasPrefix("/private/tmp/") && FileManager.default.fileExists(atPath: $0.path) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(SavedBoard(cards: cards, selectedId: selectedId, pendingRemovals: pendingRemovals, vibes: vibes, vibesOptions: vibesOptions, repos: repos)) else { return }
        try? data.write(to: storeURL, options: .atomic)
        // Every change comes through here, so the hooks never answer off a stale list.
        server?.vibesCards.set(Set(cards.filter(inVibes).map(\.id)))
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
        var repos: [Repo]?
    }

    private struct WorktreeRemoval: Codable, Equatable {
        var path: String
        var repo: String
        var branch: String?
    }
}
