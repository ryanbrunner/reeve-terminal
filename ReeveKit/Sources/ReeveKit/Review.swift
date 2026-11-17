import Foundation

/// A comment a person left on a line of the card's diff, and the
/// conversation under it, as on a GitHub review.
public struct ReviewThread: Codable, Identifiable, Equatable, Sendable {
    public enum Side: String, Codable, Sendable {
        /// A line as it was: a removed line.
        case old
        /// A line as it is now: an added or unchanged one.
        case new
    }

    public var id: UUID
    public var path: String
    public var side: Side
    public var line: Int
    /// The line's text when the comment was left. A line whose text has
    /// changed since is no longer the line commented on.
    public var code: String
    public var messages: [ReviewMessage]
    public var resolved: Bool

    public init(id: UUID = UUID(), anchor: ReviewAnchor, messages: [ReviewMessage] = []) {
        self.id = id
        self.path = anchor.path
        self.side = anchor.side
        self.line = anchor.line
        self.code = anchor.code
        self.messages = messages
        self.resolved = false
    }

    public var anchor: ReviewAnchor {
        ReviewAnchor(path: path, side: side, line: line, code: code)
    }

    /// The person spoke last and Claude has been asked: its reply is due.
    public var awaitingReply: Bool {
        guard let last = messages.last else { return false }
        return last.author == .person && !last.pending
    }

    /// A draft of the person's that hasn't gone to Claude yet.
    public var hasPending: Bool {
        messages.contains { $0.pending }
    }
}

public struct ReviewMessage: Codable, Equatable, Sendable {
    public enum Author: String, Codable, Sendable {
        case person, claude
    }

    public var author: Author
    public var body: String
    /// Written but not sent: part of a review not yet submitted.
    public var pending: Bool
    public var createdAt: Date

    public init(author: Author, body: String, pending: Bool = false, createdAt: Date = Date()) {
        self.author = author
        self.body = body
        self.pending = pending
        self.createdAt = createdAt
    }
}

/// Where on the diff a comment sits: a file, a side, a line number and what
/// the line said.
public struct ReviewAnchor: Hashable, Sendable {
    public var path: String
    public var side: ReviewThread.Side
    public var line: Int
    public var code: String

    public init(path: String, side: ReviewThread.Side, line: Int, code: String) {
        self.path = path
        self.side = side
        self.line = line
        self.code = code
    }

    /// The anchor of a line of the file's diff. A removed line is on the old
    /// side; anything else on the new. Notes have no line to comment on.
    public init?(file: FileDiff, line: DiffLine) {
        switch line.kind {
        case .removed:
            guard let n = line.oldNumber else { return nil }
            self.init(path: file.path, side: .old, line: n, code: line.text)
        case .added, .context:
            guard let n = line.newNumber else { return nil }
            self.init(path: file.path, side: .new, line: n, code: line.text)
        case .note:
            return nil
        }
    }

    /// The anchor of a block of a plan: where it starts in the plan's file
    /// and what it said.
    public init(plan path: String, block: MarkdownBlock.Located) {
        self.init(path: path, side: .new, line: block.line, code: block.source)
    }

    /// A key that stays the same across reads of the diff, for the line's
    /// threads and its composer.
    public var key: String {
        "\(path)\u{0}\(side.rawValue)\u{0}\(line)"
    }
}

/// Where each thread shows in the diff as it is now.
public struct ReviewPlacement: Equatable, Sendable {
    /// Threads on a line still in the diff, by the line's anchor key.
    public var byLine: [String: [ReviewThread]] = [:]
    /// Threads whose file is in the diff but whose line has changed or gone,
    /// as it does once Claude acts on the comment. By path.
    public var outdated: [String: [ReviewThread]] = [:]
    /// Threads on files no longer in the diff.
    public var orphaned: [ReviewThread] = []

    public init(_ threads: [ReviewThread], in files: [FileDiff]) {
        var lines: [String: ReviewAnchor] = [:]
        var paths: Set<String> = []
        for file in files {
            paths.insert(file.path)
            for hunk in file.hunks {
                for line in hunk.lines {
                    if let anchor = ReviewAnchor(file: file, line: line) { lines[anchor.key] = anchor }
                }
            }
        }
        for thread in threads {
            let anchor = thread.anchor
            if lines[anchor.key] == anchor {
                byLine[anchor.key, default: []].append(thread)
            } else if paths.contains(thread.path) {
                outdated[thread.path, default: []].append(thread)
            } else {
                orphaned.append(thread)
            }
        }
    }
}

/// Where each comment on a plan shows in the plan as it is now.
public struct PlanReviewPlacement: Equatable, Sendable {
    /// Threads on a block still in the plan, by the block's anchor key.
    public var byBlock: [String: [ReviewThread]] = [:]
    /// Threads on a block Claude has since rewritten, or on an earlier plan.
    public var outdated: [ReviewThread] = []

    public init(_ threads: [ReviewThread], plan path: String, blocks: [MarkdownBlock.Located]) {
        var anchors: [String: ReviewAnchor] = [:]
        for block in blocks {
            let anchor = ReviewAnchor(plan: path, block: block)
            anchors[anchor.key] = anchor
        }
        for thread in threads {
            let anchor = thread.anchor
            if anchors[anchor.key] == anchor {
                byBlock[anchor.key, default: []].append(thread)
            } else {
                outdated.append(thread)
            }
        }
    }
}

/// The file a review goes to Claude in, and Claude's replies come back in.
public enum ReviewFile {
    /// The review of the card's changes.
    public static func encode(_ threads: [ReviewThread]) -> Data {
        let comments: [[String: Any]] = waiting(threads).map { thread in
            [
                "id": thread.id.uuidString,
                "file": thread.path,
                "side": thread.side.rawValue,
                "line": thread.line,
                "code": thread.code,
                "thread": conversation(thread),
                "reply": NSNull(),
            ]
        }
        return json([
            "instructions": "Review comments on your changes. Each is on a line of a file: `side` is `new` for the file as it is now, `old` for a removed line, and `code` is what the line said. `thread` is the conversation so far; you are \"you\". Address each comment: change the code, or explain why not. Then set each comment's `reply` to your answer, as a string, like replying on a GitHub review. Leave everything else as it is.",
            "comments": comments,
        ])
    }

    /// The same, for comments on the plan at `planPath` (nil for a plan that
    /// is only in the conversation). Claude answers them by revising the plan.
    public static func encode(plan threads: [ReviewThread], planPath: String?) -> Data {
        let comments: [[String: Any]] = waiting(threads).map { thread in
            [
                "id": thread.id.uuidString,
                "line": thread.line,
                "text": thread.code,
                "thread": conversation(thread),
                "reply": NSNull(),
            ]
        }
        var doc: [String: Any] = [
            "instructions": "Review comments on your plan. Each is on a part of the plan: `line` is where it starts in the plan, and `text` is what that part said. `thread` is the conversation so far; you are \"you\". Address each comment: revise the plan, or explain why not. Then set each comment's `reply` to your answer, as a string, like replying on a GitHub review. Leave everything else as it is. You may edit this file in plan mode.",
            "comments": comments,
        ]
        if let planPath { doc["plan"] = planPath }
        return json(doc)
    }

    /// Every open thread waiting on Claude, not only the newest: a review
    /// sent before Claude answered the last one mustn't drop it. One the
    /// person resolved without waiting is done with.
    private static func waiting(_ threads: [ReviewThread]) -> [ReviewThread] {
        threads.filter { $0.awaitingReply && !$0.resolved }
    }

    private static func conversation(_ thread: ReviewThread) -> [[String: String]] {
        thread.messages.filter { !$0.pending }.map { ["from": $0.author == .person ? "reviewer" : "you", "text": $0.body] }
    }

    private static func json(_ doc: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Claude's replies, added to the threads still waiting on one. Reading
    /// the same file again changes nothing; a file that doesn't parse
    /// changes nothing either.
    public static func merge(_ data: Data, into threads: [ReviewThread], at date: Date = Date()) -> [ReviewThread] {
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let comments = doc["comments"] as? [[String: Any]] else { return threads }
        var replies: [UUID: String] = [:]
        for comment in comments {
            guard let id = (comment["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let reply = (comment["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !reply.isEmpty else { continue }
            replies[id] = reply
        }
        return threads.map { thread in
            guard thread.awaitingReply, let reply = replies[thread.id] else { return thread }
            var thread = thread
            thread.messages.append(ReviewMessage(author: .claude, body: reply, createdAt: date))
            return thread
        }
    }

    /// What's typed into the session to hand it the review: one line, so it
    /// goes in as a single prompt.
    public static func prompt(path: String) -> String {
        "I left review comments on your changes in \(path). Read it, address each comment (change the code, or explain why not), then write your reply to each into its \"reply\" field in that file, like replying on a GitHub review."
    }

    public static func prompt(plan path: String) -> String {
        "I left review comments on your plan in \(path). Read it, address each comment (revise the plan, or explain why not), then write your reply to each into its \"reply\" field in that file, like replying on a GitHub review."
    }

    /// The hook's answer that lets Claude edit a review file even in plan
    /// mode, which refuses every edit but the plan's whatever the settings
    /// allow, so it can reply to comments on its plan. Nil for anything else.
    public static func permission(for event: HookEvent, reviewsDir: String) -> Data? {
        guard event.hookEventName == "PreToolUse", ["Edit", "Write", "MultiEdit"].contains(event.toolName ?? ""),
              let path = event.toolInput?.filePath else { return nil }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let dir = URL(fileURLWithPath: reviewsDir, isDirectory: true).standardizedFileURL
        guard file.pathExtension == "json", file.deletingLastPathComponent().path == dir.path else { return nil }
        return Data(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Reeve's review file"}}"#.utf8)
    }
}
