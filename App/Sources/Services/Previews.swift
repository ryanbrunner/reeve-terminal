import AppKit
import ReeveKit
import WebKit

/// Every card's preview, kept whether its tab is showing or not, so going back
/// to it finds the page where it was, as `Terminals` keeps the terminals.
@MainActor
final class Previews {
    private var previews: [UUID: Preview] = [:]
    /// The Gloss session each card's page is reviewed in: none for the
    /// Preview tab's, `design` for the Design tab's, so both can run at once.
    let sessionName: String

    init(sessionName: String = "") {
        self.sessionName = sessionName
    }

    func preview(for cardId: UUID) -> Preview {
        if let preview = previews[cardId] { return preview }
        let preview = Preview(sessionName: sessionName)
        previews[cardId] = preview
        return preview
    }

    func existing(_ cardId: UUID) -> Preview? { previews[cardId] }

    func close(_ cardId: UUID) {
        previews[cardId]?.stop()
        previews[cardId] = nil
    }

    func stopAll() {
        previews.values.forEach { $0.stop() }
    }
}

/// A card's Preview tab: the page under review, in a web view of Reeve's own,
/// with Gloss's feedback bar across the top.
///
/// Gloss holds the round. Reeve starts `gloss __session --host` in the card's
/// folder, and that session writes the state file the card's `gloss wait`,
/// `working` and `ready` find, just as one with a Chromium window would. Reeve
/// is the browser half: it runs the bar Gloss hands it in every page, passes
/// the bar's calls to Gloss and Gloss's answers back, and loads, reloads and
/// photographs the page when Gloss asks (see `Gloss` in ReeveKit).
///
/// The page under review is the code Claude is editing, so it must not be able
/// to reach the bar's channel and approve the round itself. The bar and its
/// channel live in a content world of their own, which shares the page's DOM
/// and none of its JavaScript, as Gloss's isolated world does in Chromium.
@MainActor
final class Preview: NSObject, ObservableObject {
    enum Session: Equatable {
        /// No session: nothing shown yet, or Gloss isn't installed.
        case none
        case starting
        case live
        /// The session is over: approved and closed, closed by the agent, or
        /// Gloss stopped. The page stays, without the bar.
        case ended
        case failed(String)
    }

    @Published private(set) var session: Session = .none
    /// The page the view shows now.
    @Published private(set) var url: URL?
    /// The page last asked for, wherever it went from there (a sign-in, say).
    @Published private(set) var requested: URL?
    @Published private(set) var loading = false
    /// Why the last page didn't load, until one does.
    @Published private(set) var loadError: String?

    let webView: WKWebView
    /// The folder the session runs in: the one its `gloss` commands find it from.
    private(set) var cwd: String?
    /// The session's `--name`: its `gloss` commands name it too.
    let sessionName: String

    /// The bar's world: the page's own scripts can't see into it.
    let world = WKContentWorld.world(name: "gloss")
    private static let handlerName = "glossRpc"
    private var process: Process?
    private var input: FileHandle?
    private var deliverName = "__glossDeliver"
    /// Waiting on the session to be up: `gloss open`, through the hook server.
    private var waiters: [(String?) -> Void] = []
    /// The end of Gloss's stderr, for saying why a session failed.
    private var stderrTail = ""
    private var observations: [NSKeyValueObservation] = []

    init(sessionName: String = "") {
        self.sessionName = sessionName
        let config = WKWebViewConfiguration()
        // The default store, so a sign-in to the app under review lasts.
        config.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Only the bar's world has the channel; the page's own scripts can't see it.
        config.userContentController.add(WeakHandler(self), contentWorld: world, name: Self.handlerName)
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.pageChanged(view.url) }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.loading = view.isLoading }
            },
        ]
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Shows `url` under review. With a session already up, that is only a
    /// matter of going there; otherwise one starts in `cwd`. Without Gloss the
    /// page is shown on its own. `done` hears when the session is up, or why not.
    func open(_ url: URL, cwd: String, live: Bool = false, env: ShellEnvironment, done: ((String?) -> Void)? = nil) {
        loadError = nil
        requested = url
        if isRunning {
            guard self.cwd == cwd else {
                done?("the preview is already reviewing \(self.cwd ?? "another folder")")
                return
            }
            webView.load(URLRequest(url: url))
            if session == .live { done?(nil) } else if let done { waiters.append(done) }
            return
        }
        guard let gloss = env.glossPath else {
            session = .none
            webView.load(URLRequest(url: url))
            done?("Gloss isn't installed")
            return
        }
        start(gloss, url: url, cwd: cwd, live: live, env: env)
        if let done { waiters.append(done) }
    }

    /// Goes to `url`, in the session if there is one.
    func navigate(_ url: URL) {
        loadError = nil
        requested = url
        webView.load(URLRequest(url: url))
    }

    func reload() {
        loadError = nil
        if webView.url == nil, let url { webView.load(URLRequest(url: url)) } else { webView.reload() }
    }

    /// Ends the session. Gloss takes its state file away and tells any
    /// `gloss wait` the session ended.
    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    // MARK: The session

    private func start(_ gloss: String, url: URL, cwd: String, live: Bool, env: ShellEnvironment) {
        // A Gloss gone away mid-write must not take Reeve with it.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gloss)
        process.arguments = Gloss.sessionArguments(cwd: cwd, url: url.absoluteString, live: live, name: sessionName)
        process.environment = env.baseEnvironment.filter { $0.key != "GLOSS_HOST" }
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let lines = LineReader()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            for line in lines.feed(data) {
                DispatchQueue.main.async { self?.receive(line) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.stderrTail = String(((self?.stderrTail ?? "") + text).suffix(4_000)) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { self?.ended(process, status: status) }
        }

        do {
            try process.run()
        } catch {
            session = .failed("Couldn't start Gloss: \(error.localizedDescription)")
            return
        }
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.cwd = cwd
        stderrTail = ""
        session = .starting
    }

    private func receive(_ line: Data) {
        guard let message = Gloss.parse(line) else { return }
        switch message {
        case let .hello(script, binding, deliver):
            deliverName = deliver
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            // The binding first: the bar looks for it as it mounts.
            let source = "globalThis.\(binding) = (payload) => window.webkit.messageHandlers.\(Self.handlerName).postMessage(String(payload));\n" + script
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        case let .deliver(json):
            webView.evaluateJavaScript("globalThis.\(deliverName)(\(json)); undefined", in: nil, in: world) { _ in }
        case let .request(id, request):
            answer(id, request)
        case .ready:
            session = .live
            let waiting = waiters
            waiters = []
            waiting.forEach { $0(nil) }
        }
    }

    private func answer(_ id: Int, _ request: Gloss.Request) {
        switch request {
        case let .navigate(url):
            navigate(url)
            send(Gloss.reply(id: id))
        case .reload:
            reload()
            send(Gloss.reply(id: id))
        case .view:
            webView.callAsyncJavaScript(
                "return { scrollX, scrollY, width: innerWidth, height: innerHeight }",
                arguments: [:], in: nil, in: world
            ) { [weak self] result in
                switch result {
                case let .success(view): self?.send(Gloss.reply(id: id, result: view))
                case let .failure(error): self?.send(Gloss.reply(id: id, error: error.localizedDescription))
                }
            }
        case let .snapshot(clip, path):
            let config = WKSnapshotConfiguration()
            config.rect = clip
            webView.takeSnapshot(with: config) { [weak self] image, error in
                guard let image, let png = Self.png(image) else {
                    self?.send(Gloss.reply(id: id, error: error?.localizedDescription ?? "no picture"))
                    return
                }
                do {
                    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try png.write(to: URL(fileURLWithPath: path))
                    self?.send(Gloss.reply(id: id))
                } catch {
                    self?.send(Gloss.reply(id: id, error: error.localizedDescription))
                }
            }
        }
    }

    private func send(_ line: Data) {
        guard isRunning else { return }
        try? input?.write(contentsOf: line)
    }

    private func ended(_ ended: Process, status: Int32) {
        guard ended === process else { return }
        process = nil
        input = nil
        let why = Self.failure(stderrTail, status: status)
        session = status == 0 ? .ended : .failed(why ?? "Gloss stopped (exit \(status))")
        let waiting = waiters
        waiters = []
        waiting.forEach { $0(why ?? "the session ended before it was up") }
        // The page stays, without a bar that has nothing behind it.
        webView.configuration.userContentController.removeAllUserScripts()
        if webView.url != nil { webView.reload() }
    }

    /// What Gloss said went wrong: its own `gloss: …` line, else the first
    /// thing anything said, such as a version manager with no node to run.
    private static func failure(_ stderr: String, status: Int32) -> String? {
        // 2 is a mistake in the command: a Gloss from before `--host`.
        if status == 2 { return "This Gloss can't show pages in Reeve: update it to one with `gloss __session --host`" }
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("[gloss] ") }
        if let own = lines.first(where: { $0.hasPrefix("gloss: ") }) { return String(own.dropFirst("gloss: ".count)) }
        return lines.first
    }

    private func pageChanged(_ url: URL?) {
        guard let url else { return }
        self.url = url
        send(Gloss.page(url.absoluteString))
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Calls from the bar, in its world.
    fileprivate func received(_ message: WKScriptMessage) {
        guard let payload = message.body as? String else { return }
        let frame = message.frameInfo
        // The view's URL follows `pushState`; the frame's request is only what loaded the document.
        let url = (frame.isMainFrame ? webView.url : nil) ?? frame.request.url
        send(Gloss.rpc(payload: payload, url: url?.absoluteString ?? "", topFrame: frame.isMainFrame))
    }
}

extension Preview: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        loadError = nil
    }

    private func failed(_ error: Error) {
        // A navigation that replaced this one isn't a failure.
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loadError = error.localizedDescription
    }

    /// A dev server's own certificate loads, as Gloss's Chromium takes it
    /// (`ignoreHTTPSErrors`), but only on a host that can only be local: this
    /// view keeps its cookies, unlike Gloss's Chromium.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
              Self.isLocal(space.host) else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    private static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
            || [".localhost", ".test", ".local"].contains { host.hasSuffix($0) }
    }

    /// A link to a new window opens here instead: the preview is the one window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

/// The user content controller holds its handlers strongly; this keeps it from holding the preview.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var preview: Preview?

    init(_ preview: Preview) {
        self.preview = preview
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { preview?.received(message) }
    }
}

/// Splits what comes down a pipe into lines, however it is chunked.
private final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ data: Data) -> [Data] {
        lock.withLock {
            buffer.append(data)
            var lines: [Data] = []
            while let end = buffer.firstIndex(of: 0x0A) {
                lines.append(Data(buffer[buffer.startIndex..<end]))
                buffer.removeSubrange(buffer.startIndex...end)
            }
            return lines
        }
    }
}
