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
    /// Cards cleaned up once their pull requests merged, newest first. They
    /// have no session or worktree any more; this is only a record.
    @Published private(set) var archive: [Card] = []
    @Published var showingArchive = false
    /// The swimlanes, top to bottom. Never empty.
    @Published private(set) var lanes: [Lane] = [Lane.starter()]
    /// The folders a new card can start in.
    @Published private(set) var repos: [Repo] = []
    /// The repo picked for the last new card, so a run of cards starts in
    /// the same one.
    @Published var pickedRepoId: UUID? {
        didSet { Preferences.store.set(pickedRepoId?.uuidString, forKey: "newCardRepo") }
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
    /// Cards whose plan dialog is being answered with the person's comments
    /// on the plan, while Reeve picks the option that takes them.
    @Published private(set) var answeringPlans: Set<UUID> = []
    /// Raised when a card showing its changes may have new ones, so the tab
    /// reads them again. Only for that card, so others' tool calls cost nothing.
    @Published private(set) var changeTicks: [UUID: Int] = [:]
    /// Where a new card is being named, inline on the board. Nil when none is.
    @Published var composing: NewCardSpot?
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
    /// The field above the board that runs a request through `reeve`.
    let commandBar = CommandBarRunner()
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
    /// Cards whose pull requests are being looked up right now.
    @Published private(set) var findingPullRequests: Set<UUID> = []
    private var restarting: Set<UUID> = []
    /// Backlog cards whose worktree is being made on the way to their first start.
    @Published private(set) var launching: Set<UUID> = []
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
    /// The question a stopped card's last message left, as the classifier
    /// read it. Not the card's: only a dialog makes a card wait on a person.
    /// VIBES MODE answers it, as it would have been answered in the terminal.
    private var leftQuestions: [UUID: String] = [:]
    /// What VIBES MODE last typed into each card, so its prompt is told apart
    /// from a person's when the hook reports it.
    private var vibesPrompts: [UUID: String] = [:]
    /// Cards VIBES MODE has left alone because what they wait on hasn't
    /// merged, so the ledger says so once rather than at every sweep.
    private var vibesHeld: Set<UUID> = []
    private let dataDir: URL
    /// Where the board lives, which the command bar's `reeve` is pointed at.
    var dataDirectory: URL { dataDir }
    private let storeURL: URL
    /// Where each card's review goes to Claude and its replies come back.
    private let reviewsDir: URL

    init() {
        dataDir = DataDirectory.url()
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        storeURL = dataDir.appendingPathComponent("board.json")
        reviewsDir = dataDir.appendingPathComponent("reviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: reviewsDir, withIntermediateDirectories: true)
        pickedRepoId = Preferences.store.string(forKey: "newCardRepo").flatMap(UUID.init)
        load()

        terminals.onStateChange = { [weak self] id, running, exitCode in
            self?.processChanged(id, running: running, exitCode: exitCode)
        }
        terminals.onTitle = { [weak self] id, title in
            self?.titleChanged(id, title)
        }

        do {
            let server = try LocalServer(reviewsDir: reviewsDir.path)
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

    func cards(in stage: Stage, lane: UUID) -> [Card] {
        cards.filter { $0.stage == stage && self.lane(of: $0).id == lane }
    }

    func cards(inLane lane: UUID) -> [Card] {
        cards.filter { self.lane(of: $0).id == lane }
    }

    /// The board in reading order: lane by lane, and in each, column by
    /// column, top to bottom.
    var ordered: [Card] {
        lanes.flatMap { lane in Stage.allCases.flatMap { cards(in: $0, lane: lane.id) } }
    }

    /// The card's swimlane: its own, else the first.
    func lane(of card: Card) -> Lane {
        card.lane(in: lanes) ?? lanes[0]
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

    /// Makes a card named on the board, where it was named: in Backlog it
    /// waits, in Planning it plans and in In Progress it builds, with its
    /// name as its first prompt. The board stays in front. When git can't
    /// make a worktree, asks whether to work in the folder instead.
    func create(name: String, in spot: NewCardSpot, cwd: String, model: String? = nil, effort: String? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let mode = Card.launch(movingTo: spot.stage)
        Task {
            await withWorktreeFallback { inFolder in
                _ = try await self.createCard(cwd: cwd, title: name, prompt: name, mode: mode, model: model, effort: effort,
                                              lane: spot.lane, open: false, inFolder: inFolder)
            }
        }
    }

    /// Runs `make`, and when git couldn't make the card a worktree, asks
    /// whether to work in the folder itself and runs it again if so.
    private func withWorktreeFallback(_ make: (_ inFolder: Bool) async throws -> Void) async {
        do {
            try await make(false)
        } catch let refusal as APIError {
            refuse(refusal)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't make a worktree for this card"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Work in the Folder")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try? await make(true)
        }
    }

    /// Opens the new card field in `spot`, over whatever the board shows.
    func compose(in stage: Stage = .backlog, lane: UUID? = nil) {
        if selectedId != nil { dismissOpenCard() }
        composing = NewCardSpot(lane: lane ?? lanes[0].id, stage: stage)
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
    ///
    /// With no mode it goes in Backlog and nothing happens: no worktree and
    /// no session until it is moved on (see `launch`). The worktree waits
    /// too, so it starts from HEAD as it is then.
    @discardableResult
    func createCard(cwd: String, title: String, prompt: String?, mode: StartMode?, model: String?, effort: String?,
                    vibes: Bool = false, lane: UUID? = nil, open: Bool, inFolder: Bool) async throws -> Card {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var card = Card(title: title, cwd: cwd, stage: .backlog)
        card.vibes = vibes ? true : nil
        card.laneId = lanes.contains { $0.id == lane } ? lane : nil
        card.model = model
        card.effort = effort
        guard let mode else {
            card.queued = true
            let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            card.brief = prompt.isEmpty || prompt == title ? nil : prompt
            cards.append(card)
            if open { selectedId = card.id }
            save()
            return card
        }
        let start = startingMode(mode, vibes: vibes)
        card.stage = start.stage
        card.startMode = start
        if let made = try await makeWorktree(for: card.id, in: cwd, inFolder: inFolder) {
            card.cwd = made.cwd
            card.repoPath = made.repo
            card.worktreePath = made.path
            card.branch = made.branch
            card.baseCommit = made.base
        }
        cards.append(card)
        if open { selectedId = card.id }
        save()
        begin(card.id, prompt: prompt)
        return card
    }

    /// VIBES MODE flies over Planning unless its options say otherwise.
    private func startingMode(_ mode: StartMode, vibes: Bool) -> StartMode {
        (vibes || self.vibes != nil) && vibesOptions.skipPlanning ? .build : mode
    }

    /// The card's worktree, or nil for a folder outside git, or when git
    /// can't make one and the card may work in the folder.
    private func makeWorktree(for id: UUID, in folder: String, inFolder: Bool) async throws -> Worktrees.Made? {
        do {
            return try await Worktrees.make(for: id, in: folder, env: environment)
        } catch {
            guard inFolder else { throw error }
            return nil
        }
    }

    /// A new session's first start, on `prompt` if there is one.
    private func begin(_ id: UUID, prompt: String?) {
        guard let card = card(id) else { return }
        let prompted = prompt.map { !$0.isEmpty } ?? false
        // Working from the moment it's asked, so a `reeve card wait` straight
        // after doesn't find it idle before Claude has read the prompt.
        if prompted {
            update(id) { $0.activity = .running }
            expectPrompt(id)
        }
        start(self.card(id) ?? card, prompt: prompt)
    }

    /// Starts a backlog card: its worktree from HEAD as it is now, then its
    /// session in `mode`, on its brief, else its name. A card moved to its
    /// column stays there; one started where it is goes to the mode's column.
    func launch(_ id: UUID, mode: StartMode, inFolder: Bool) async throws {
        guard let card = card(id), card.queued == true, !launching.contains(id) else { return }
        if let refusal = startRefusal(id) { throw refusal }
        launching.insert(id)
        defer { launching.remove(id) }
        let start = startingMode(mode, vibes: card.vibes == true)
        let made = try await makeWorktree(for: id, in: card.cwd, inFolder: inFolder)
        // Closed while git was busy: the worktree has nobody to go to.
        guard let card = self.card(id), card.queued == true else {
            if let made { removeWorktree(WorktreeRemoval(path: made.path, repo: made.repo, branch: made.branch)) }
            return
        }
        update(id) { card in
            if let made {
                card.cwd = made.cwd
                card.repoPath = made.repo
                card.worktreePath = made.path
                card.branch = made.branch
                card.baseCommit = made.base
            }
            card.queued = nil
            card.startMode = start
            if card.stage == .backlog { card.stage = start.stage }
        }
        let prompt = card.brief ?? (card.title.isEmpty ? nil : card.title)
        update(id) { $0.brief = nil }
        begin(id, prompt: prompt)
    }

    /// `launch`, from the board, asking about the folder if git says no.
    func startQueued(_ id: UUID, mode: StartMode) {
        if let refusal = startRefusal(id) { return refuseStart(id, refusal) }
        Task {
            await withWorktreeFallback { inFolder in try await self.launch(id, mode: mode, inFolder: inFolder) }
        }
    }

    func select(_ id: UUID) {
        selectedId = id
        refreshPullRequest(id)
        // What it waits on may have merged since the board last asked.
        if let blocker = blocker(of: id) { refreshPullRequest(blocker.id) }
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
        // Checks and reviews move on their own, so the tab is never stale.
        if tab == .prs { refreshPullRequest(id) }
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
    /// A backlog card moved to Planning or In Progress starts, unless
    /// `launching` is off, for a caller that starts it itself. One waiting on
    /// a card that hasn't merged can't start, so it stays where it is.
    func move(_ id: UUID, to stage: Stage? = nil, lane: UUID? = nil, launching: Bool = true) {
        if let stage, card(id)?.queued == true, Card.launch(movingTo: stage) != nil, let refusal = startRefusal(id) {
            // A caller that starts it itself says why in its own words.
            if launching { refuseStart(id, refusal) }
            return
        }
        update(id) { card in
            if let lane, lanes.contains(where: { $0.id == lane }) { card.laneId = lane }
            guard let stage, card.stage != stage else { return }
            card.stage = stage
            card.stagePinned = true
        }
        if launching, let stage, card(id)?.queued == true, let mode = Card.launch(movingTo: stage) {
            startQueued(id, mode: mode)
        }
    }

    // MARK: Waiting on another card

    /// The card `id` waits on, while it hasn't merged.
    func blocker(of id: UUID) -> Card? {
        card(id).flatMap { Dependency.blocker(of: $0, in: cards) }
    }

    /// Why the backlog card `id` can't start yet, else nil.
    func startRefusal(_ id: UUID) -> APIError? {
        card(id).flatMap { Dependency.refusal($0, in: cards, name: { self.displayTitle($0) }) }
    }

    /// The card `id` waits on `target`, or on nothing. Refused for itself, a
    /// card that isn't on the board, or a loop.
    func waitOn(_ id: UUID, _ target: UUID?) throws {
        guard let card = card(id) else { throw APIError("no such card") }
        if let target {
            guard let waited = self.card(target) else { throw APIError("no such card on the board", detail: target.uuidString) }
            if let refusal = Dependency.linkRefusal(card, waitingOn: waited, in: cards + archive, name: { self.displayTitle($0) }) { throw refusal }
        }
        update(id) { $0.dependsOnId = target }
        // Let go, it may be VIBES MODE's to push on.
        if target == nil { vibesSweep() }
    }

    /// The card `card` waits on, as `reeve` sees it.
    func dependencyLink(_ card: Card) -> DependencyLink? {
        guard let id = card.dependsOnId else { return nil }
        guard let waited = self.card(id) ?? archive.first(where: { $0.id == id }) else {
            return DependencyLink(id: id, title: "", done: true, status: "closed")
        }
        return DependencyLink(id: id, title: displayTitle(waited), done: !Dependency.stillBlocking(waited), status: Dependency.status(of: waited))
    }

    /// Says why `id` can't start. Merged is only what its badge last said, so
    /// the card it waits on is asked again, and a try once it has merged goes
    /// through.
    private func refuseStart(_ id: UUID, _ refusal: APIError) {
        if let blocker = blocker(of: id) { refreshPullRequest(blocker.id) }
        refuse(refusal)
    }

    /// Says why the board didn't do what was asked. After the gesture that
    /// asked, since a drop calls in from inside an animation.
    func refuse(_ refusal: APIError) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = refusal.error.prefix(1).uppercased() + refusal.error.dropFirst()
            alert.informativeText = refusal.detail ?? ""
            alert.runModal()
        }
    }

    // MARK: Swimlanes

    @discardableResult
    func addLane(named name: String) -> Lane {
        let lane = Lane(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        lanes.append(lane)
        save()
        return lane
    }

    func renameLane(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = lanes.firstIndex(where: { $0.id == id }) else { return }
        lanes[i].name = name
        save()
    }

    /// Takes a lane off the board. Its cards go to the lane above it, or the
    /// one below for the top lane. The last lane stays.
    func deleteLane(_ id: UUID) {
        guard lanes.count > 1, let i = lanes.firstIndex(where: { $0.id == id }) else { return }
        let heir = lanes[i == 0 ? 1 : i - 1].id
        for card in cards where lane(of: card).id == id {
            update(card.id) { $0.laneId = heir }
        }
        lanes.remove(at: i)
        if composing?.lane == id { composing = nil }
        save()
    }

    /// Moves a lane up (negative) or down the board.
    func moveLane(_ id: UUID, by offset: Int) {
        guard let i = lanes.firstIndex(where: { $0.id == id }), lanes.indices.contains(i + offset) else { return }
        lanes.swapAt(i, i + offset)
        save()
    }

    /// The lane `ref` names, by id or name.
    func lane(named ref: String) -> Lane? {
        Lane.find(ref, in: lanes)
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
    func close(_ id: UUID, archiving: Bool = false) {
        let closing = card(id)
        if archiving, var kept = closing {
            kept.archivedAt = Date()
            kept.activity = .idle
            kept.waitingOn = nil
            kept.background = nil
            archive.insert(kept, at: 0)
        }
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
        answeringPlans.remove(id)
        vibesPrompts[id] = nil
        vibesHeld.remove(id)
        launching.remove(id)
        cards.removeAll { $0.id == id }
        // Gone without merging, it has nothing left to wait for. An archived
        // one stays linked, and says it merged.
        if !archiving {
            for card in cards where card.dependsOnId == id { update(card.id) { $0.dependsOnId = nil } }
        }
        live.remove(id)
        dialogOpen.remove(id)
        awaitingPrompt.remove(id)
        classifying.remove(id)
        terminalTitles[id] = nil
        tabs[id] = nil
        unseenPlans.remove(id)
        changeTicks[id] = nil
        try? FileManager.default.removeItem(at: reviewURL(id))
        try? FileManager.default.removeItem(at: reviewURL(id, .plan))
        // Back to the board, rather than opening (and starting) a neighbour.
        if selectedId == id { selectedId = nil }
        save()
    }

    /// The cards on the board whose pull requests have all merged.
    var archivable: [Card] {
        cards.filter(\.isFullyMerged)
    }

    /// Archives every card whose pull requests have merged: ends its session,
    /// deletes its worktree and moves it to the archive. A card whose worktree
    /// has uncommitted changes stays on the board, since deleting the worktree
    /// would lose them. Returns how many were archived and how many were kept.
    @discardableResult
    func archiveMerged() async -> (archived: Int, kept: Int) {
        var archived = 0
        var kept = 0
        for candidate in archivable {
            var changes = 0
            if let path = candidate.worktreePath, FileManager.default.fileExists(atPath: path) {
                changes = await Worktrees.uncommittedChanges(at: path, env: environment)
            }
            // The board moved on while git was answering.
            guard let current = card(candidate.id), current.isFullyMerged else { continue }
            if changes > 0 {
                kept += 1
            } else {
                close(current.id, archiving: true)
                archived += 1
            }
        }
        return (archived, kept)
    }

    /// Forgets an archived card for good.
    func deleteArchived(_ id: UUID) {
        archive.removeAll { $0.id == id }
        save()
    }

    private func removeWorktree(_ removal: WorktreeRemoval) {
        Task { [environment] in
            guard await Worktrees.remove(path: removal.path, branch: removal.branch, repo: removal.repo, env: environment) else { return }
            pendingRemovals.removeAll { $0 == removal }
            save()
        }
    }

    /// Code of the card's that hasn't landed, which closing would throw away
    /// or leave behind.
    struct Unmerged {
        var uncommitted = 0
        var commits = 0
        var openPullRequests: [PullRequest] = []

        var isEmpty: Bool { uncommitted == 0 && commits == 0 && openPullRequests.isEmpty }

        /// In a line: "its worktree has 2 uncommitted changes and PR #42 is still open".
        var summary: String {
            var reasons: [String] = []
            if uncommitted > 0 { reasons.append("its worktree has \(uncommitted) uncommitted change\(uncommitted == 1 ? "" : "s")") }
            if commits > 0 { reasons.append("its branch has \(commits) unmerged commit\(commits == 1 ? "" : "s")") }
            if !openPullRequests.isEmpty {
                let numbers = openPullRequests.map { "#\($0.number)" }.joined(separator: ", ")
                reasons.append("PR\(openPullRequests.count == 1 ? "" : "s") \(numbers) \(openPullRequests.count == 1 ? "is" : "are") still open")
            }
            return reasons.joined(separator: " and ")
        }
    }

    /// What closing the card would lose that a person might want: work in its
    /// worktree not yet committed, commits not yet merged, and pull requests
    /// still open. A live session alone isn't worth asking about. Nil when nothing.
    func closeWouldLose(_ id: UUID) async -> Unmerged? {
        guard let card = card(id) else { return nil }
        var unmerged = Unmerged()
        unmerged.openPullRequests = (card.pullRequests ?? []).filter { $0.state == .open || $0.state == .draft }
        if let path = card.worktreePath, FileManager.default.fileExists(atPath: path) {
            unmerged.uncommitted = await Worktrees.uncommittedChanges(at: path, env: environment)
            if let repo = card.repoPath, card.pullRequest?.state != .merged {
                unmerged.commits = await Worktrees.unmergedCommits(at: path, repo: repo, env: environment)
            }
        }
        return unmerged.isEmpty ? nil : unmerged
    }

    /// Starts the card's session if it isn't running, without opening the card.
    func startIfNeeded(_ id: UUID, prompt: String? = nil) {
        guard let card = card(id), card.queued != true, !live.contains(id), !starting.contains(id) else { return }
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
        guard let card = card(id) else { throw APIError("no such card") }
        if card.queued == true { throw Board.queuedError }
        if starting.contains(id) {
            throw APIError("the session is still starting", detail: "try again in a moment")
        }
        guard live.contains(id) else {
            startIfNeeded(id, prompt: text)
            return .started
        }
        if dialogOpen.contains(id), !force {
            let showing = card.waitingOn.map { ": \($0)" } ?? ""
            throw APIError("Claude is showing a dialog\(showing)", detail: "answer it in the app, or pass --force to type into it anyway")
        }
        sendingPrompt(id)
        terminals.send(text, to: id)
        return .typed
    }

    /// What `reeve` hears for a backlog card that hasn't started.
    static let queuedError = APIError("the card is in the backlog and hasn't started",
                                      detail: "move it to planning or in-progress to start it")

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
        // A backlog card has no worktree yet: its `cwd` is the person's own
        // folder. Only `launch` starts it, once it has one.
        guard card.queued != true else { return }
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
        answeringPlans.remove(id)
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
            leftQuestions[cardId] = nil
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
        for target in [ReviewTarget.changes, .plan] where event.hookEventName == "Stop"
            || (event.hookEventName == "PostToolUse" && event.toolInput?.filePath == reviewURL(cardId, target).path) {
            readReplies(cardId, target)
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
                // means the session has moved on from what was read. A
                // question asked in text leaves the card ready for review;
                // only a dialog waits on a person. A card waiting on its
                // agents has no question, whatever Claude said as it
                // launched them.
                if current, card.activity == .needsReview {
                    card.waitingOn = nil
                    leftQuestions[id] = result.waitingOn
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
        guard card.activity == .needsReview else { return }
        let name = "“\(displayTitle(card))”"
        // Its work builds on a card that hasn't merged: left settled, so the
        // sweep once that one merges picks it up.
        if let blocker = blocker(of: id) {
            if vibesHeld.insert(id).inserted { vibes?.note("Holding \(name) · it waits on “\(displayTitle(blocker))”") }
            return
        }
        vibesHeld.remove(id)
        settled.remove(id)
        switch Vibes.next(stage: card.stage, waitingOn: leftQuestions.removeValue(forKey: id), nudges: card.vibesNudges, options: vibesOptions) {
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
        // Whatever waited on it can go on.
        vibesSweep()
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

    /// What a review is of: the card's changes, or its plan.
    enum ReviewTarget {
        case changes, plan
    }

    func reviewURL(_ id: UUID, _ target: ReviewTarget = .changes) -> URL {
        reviewsDir.appendingPathComponent(id.uuidString + (target == .plan ? "-plan" : "") + ".json")
    }

    /// The card's threads on the target.
    private func threads(_ card: Card, _ target: ReviewTarget) -> [ReviewThread]? {
        target == .plan ? card.planReview : card.review
    }

    /// Why a review can't go to the card's session right now, if it can't.
    /// While Claude works it can: Claude Code queues the prompt. A plan's
    /// review can go in plan mode, and answer the plan dialog.
    func reviewBlocker(_ id: UUID, _ target: ReviewTarget = .changes) -> String? {
        guard let card = card(id) else { return nil }
        switch target {
        case .changes:
            if card.activity == .needsInput { return "Claude is waiting on you in the terminal. Answer it first." }
            if card.permissionMode == "plan" { return "Claude is in plan mode, where it can't change code. Leave plan mode in the terminal first." }
        case .plan:
            if acceptingPlans.contains(id) || approvingPlans.contains(id) || answeringPlans.contains(id) { return "The plan dialog is being answered." }
            if card.activity == .needsInput, !planDialogs.contains(id) { return "Claude is waiting on you in the terminal. Answer it first." }
        }
        return nil
    }

    /// A new comment on a line. Sent now, or kept as part of a review.
    func comment(on anchor: ReviewAnchor, _ body: String, in id: UUID, _ target: ReviewTarget = .changes, send: Bool) {
        let thread = ReviewThread(anchor: anchor, messages: [ReviewMessage(author: .person, body: body, pending: true)])
        updateReview(id, target) { $0.append(thread) }
        if send { submitReview(id, target, only: thread.id) }
    }

    /// The person answers a thread. Sent now, or kept as part of a review.
    func reply(to threadId: UUID, _ body: String, in id: UUID, _ target: ReviewTarget = .changes, send: Bool) {
        updateReview(id, target) { threads in
            guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return }
            threads[i].messages.append(ReviewMessage(author: .person, body: body, pending: true))
            threads[i].resolved = false
        }
        if send { submitReview(id, target, only: threadId) }
    }

    /// Drops a thread's unsent drafts, and the thread with them if that was all it had.
    func discardDrafts(_ threadId: UUID, in id: UUID, _ target: ReviewTarget = .changes) {
        updateReview(id, target) { threads in
            guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return }
            threads[i].messages.removeAll { $0.pending }
            if threads[i].messages.isEmpty { threads.remove(at: i) }
        }
    }

    func resolve(_ threadId: UUID, _ resolved: Bool, in id: UUID, _ target: ReviewTarget = .changes) {
        updateReview(id, target) { threads in
            guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return }
            threads[i].resolved = resolved
        }
    }

    /// Sends the card's drafts to Claude (or one thread's): writes every
    /// thread waiting on a reply to the review file and asks the session,
    /// woken if it is asleep, to answer them there. A plan's review, while
    /// the plan dialog is open, goes in as the dialog's feedback.
    func submitReview(_ id: UUID, _ target: ReviewTarget = .changes, only threadId: UUID? = nil) {
        guard reviewBlocker(id, target) == nil else { return }
        // A reply already in the file would go with the rewrite.
        readReplies(id, target)
        updateReview(id, target) { threads in
            for i in threads.indices where threadId == nil || threads[i].id == threadId {
                for m in threads[i].messages.indices { threads[i].messages[m].pending = false }
            }
        }
        guard let card = card(id), let threads = threads(card, target), threads.contains(where: { $0.awaitingReply && !$0.resolved }) else { return }
        let url = reviewURL(id, target)
        let data = target == .plan ? ReviewFile.encode(plan: threads, planPath: card.planPath) : ReviewFile.encode(threads)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Reeve: writing the review for \(id) failed: \(error.localizedDescription)")
            return
        }
        let prompt = target == .plan ? ReviewFile.prompt(plan: url.path) : ReviewFile.prompt(path: url.path)
        if target == .plan, planDialogs.contains(id), live.contains(id) {
            answeringPlans.insert(id)
            answerPlanDialog(id, with: prompt, tries: 3)
        } else if live.contains(id) {
            terminals.send(prompt, to: id)
        } else {
            start(card, prompt: prompt)
        }
    }

    /// Puts `prompt` to Claude through the plan dialog: its last option, the
    /// one that doesn't approve, as the person would. "Tell Claude what to
    /// change" takes the text in place; an older "No, keep planning" goes
    /// back to the prompt, where the text is typed. As with approving, the
    /// selection is read off the screen before anything is typed, and Enter
    /// is pressed only once it is on that option: Enter anywhere else would
    /// approve the plan.
    private func answerPlanDialog(_ id: UUID, with prompt: String, tries: Int) {
        guard answeringPlans.contains(id) else { return }
        guard let dialog = PlanDialog.find(onScreen: terminals.screen(id)), let target = dialog.feedback else {
            if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.answerPlanDialog(id, with: prompt, tries: tries - 1) }
            } else {
                answeringPlans.remove(id)
            }
            return
        }
        let inPlace = !dialog.options[target].hasPrefix("No")
        let view = terminals.view(for: id)
        let moves = dialog.moves(to: target)
        for (i, key) in moves.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * Double(i)) { [weak self] in
                guard self?.answeringPlans.contains(id) == true else { return }
                view.send(txt: key)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * Double(moves.count) + 0.3) { [weak self] in
            guard let self, self.answeringPlans.contains(id) else { return }
            guard PlanDialog.find(onScreen: self.terminals.screen(id))?.selected == target else {
                self.answeringPlans.remove(id)
                return
            }
            if inPlace {
                // Typed into the option, then submitted from it.
                self.terminals.send(prompt, to: id)
            } else {
                view.send(txt: "\r")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.terminals.send(prompt, to: id) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.answeringPlans.remove(id) }
        }
    }

    /// Takes in whatever Claude has replied in the card's review file.
    private func readReplies(_ id: UUID, _ target: ReviewTarget) {
        guard let card = card(id), threads(card, target)?.contains(where: \.awaitingReply) == true,
              let data = try? Data(contentsOf: reviewURL(id, target)) else { return }
        updateReview(id, target) { $0 = ReviewFile.merge(data, into: $0) }
    }

    private func updateReview(_ id: UUID, _ target: ReviewTarget, _ change: (inout [ReviewThread]) -> Void) {
        update(id) { card in
            var threads = (target == .plan ? card.planReview : card.review) ?? []
            change(&threads)
            if target == .plan {
                card.planReview = threads.isEmpty ? nil : threads
            } else {
                card.review = threads.isEmpty ? nil : threads
            }
        }
    }

    // MARK: Pull requests

    /// Looks up the pull requests from every branch the card's worktree has
    /// been on: the one it is on now, which Claude may have switched to from
    /// the one Reeve made, and the ones it left. A branch gh can't say about
    /// keeps the pull requests it had.
    func refreshPullRequest(_ id: UUID) {
        Task { await findPullRequest(id) }
    }

    /// A pull request found open or merged on the card's branch moves the
    /// card to Release.
    func findPullRequest(_ id: UUID) async {
        guard let card = card(id), let worktree = card.worktreePath, let env = environment,
              !findingPullRequests.contains(id), FileManager.default.fileExists(atPath: worktree) else { return }
        findingPullRequests.insert(id)
        defer { findingPullRequests.remove(id) }
        let head = await Worktrees.currentBranch(at: worktree, env: env)
        let owns = Set([head, card.branch].compactMap { $0 })
        let tracked = card.pullRequests ?? []
        // A branch whose pull requests have all merged has nothing left to say.
        let settled = Set(tracked.map(\.branch)).filter { branch in
            !owns.contains(branch) && tracked.allSatisfy { $0.branch != branch || $0.state == .merged }
        }
        var branches: [String] = []
        for branch in [head, card.branch].compactMap({ $0 }) + tracked.map(\.branch)
            + (await Worktrees.reflogBranches(at: worktree, env: env))
        where !branch.isEmpty && !settled.contains(branch) && !branches.contains(branch) {
            branches.append(branch)
        }
        // A few at a time, so the end of a turn isn't waiting on one gh after
        // another, and a launch that refreshes every card doesn't start dozens.
        let answers = await withTaskGroup(of: [PullRequest]?.self) { group in
            var pending = branches[...]
            var answers: [[PullRequest]?] = []
            func next() {
                guard let branch = pending.popFirst() else { return }
                group.addTask { await PullRequests.find(branch: branch, in: worktree, env: env) }
            }
            for _ in 0..<4 { next() }
            for await answer in group {
                answers.append(answer)
                next()
            }
            return answers
        }
        guard answers.contains(where: { $0 != nil }) else { return }
        let found = PullRequest.belonging(answers.compactMap { $0 }.flatMap { $0 }, owns: owns, tracked: tracked, since: card.createdAt)
        update(id) { card in
            let all = PullRequest.merge(card.pullRequests ?? [], found)
            card.pullRequests = all.isEmpty ? nil : all
            // Never written to `card.branch`: closing the card deletes that one.
            if let head { card.headBranch = head }
            if card.hasLivePullRequest, !card.stagePinned { card.stage = .release }
        }
        // Merged, whatever waited on it can go on.
        if self.card(id)?.pullRequest?.state == .merged, cards.contains(where: { $0.dependsOnId == id }) { vibesSweep() }
    }

    /// The card as `reeve` sees it.
    func apiCard(_ card: Card) -> APICard {
        APICard(card: card, live: live.contains(card.id), starting: starting.contains(card.id),
                dialogOpen: dialogOpen.contains(card.id), displayTitle: displayTitle(card), dependsOn: dependencyLink(card))
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
        if let saved = saved.lanes, !saved.isEmpty { lanes = saved }
        // Launch lands on the board; opening a card is what starts its session.
        updateBadge()
        vibes = saved.vibes
        vibesOptions = saved.vibesOptions ?? VibesOptions()
        archive = saved.archive ?? []
        pendingRemovals = saved.pendingRemovals ?? []
        pendingRemovals.forEach(removeWorktree)
    }

    /// A board saved before there were repos starts with the folders its
    /// cards were made in, and the ones the new card sheet remembered. Not
    /// a scratch folder in /tmp, which is where smoke tests start cards.
    private func seededRepos() -> [Repo] {
        let recent = Preferences.store.stringArray(forKey: "recentFolders") ?? []
        return Repo.seeded(from: recent + cards.compactMap { $0.repoPath ?? ($0.worktreePath == nil ? $0.cwd : nil) })
            .filter { !$0.path.hasPrefix("/tmp/") && !$0.path.hasPrefix("/private/tmp/") && FileManager.default.fileExists(atPath: $0.path) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(SavedBoard(cards: cards, archive: archive, selectedId: selectedId, pendingRemovals: pendingRemovals, vibes: vibes, vibesOptions: vibesOptions, repos: repos, lanes: lanes)) else { return }
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
        var archive: [Card]?
        var selectedId: UUID?
        /// Worktrees of closed cards that git hasn't finished removing.
        var pendingRemovals: [WorktreeRemoval]?
        var vibes: VibesLedger?
        var vibesOptions: VibesOptions?
        var repos: [Repo]?
        var lanes: [Lane]?
    }

    private struct WorktreeRemoval: Codable, Equatable {
        var path: String
        var repo: String
        var branch: String?
    }
}
