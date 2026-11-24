import Foundation

/// What Claude made of a card after reading its session. The card's column
/// isn't part of it: that comes from the session's state.
public struct Classification: Decodable, Equatable, Sendable {
    public var title: String
    public var summary: String
    /// The question Claude's last message leaves a person to answer, if any.
    /// It doesn't make the card wait on them: only a dialog does that.
    public var waitingOn: String?
    /// Whether everything the person asked for is so, with nothing left for
    /// anyone to do: a question answered, a greeting returned. VIBES MODE
    /// closes a card like that, if nothing in it changed, rather than tell it
    /// to build something.
    public var done: Bool

    enum CodingKeys: String, CodingKey {
        case title, summary, done
        case waitingOn = "waiting_on"
    }

    public init(title: String, summary: String, waitingOn: String?, done: Bool = false) {
        self.title = title
        self.summary = summary
        self.waitingOn = waitingOn
        self.done = done
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
        summary = try c.decode(String.self, forKey: .summary).trimmingCharacters(in: .whitespacesAndNewlines)
        let waiting = try c.decodeIfPresent(String.self, forKey: .waitingOn)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a question is something to answer. Haiku sometimes describes
        // what Claude itself is waiting for ("Both agents to finish") instead.
        waitingOn = waiting?.hasSuffix("?") == true ? waiting : nil
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}

/// The `claude -p` call that classifies a card, and reading its answer.
public enum Classifier {
    public static let model = "haiku"

    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["title","summary","waiting_on","done"],"properties":{\
    "title":{"type":"string","description":"2 to 6 words naming the piece of work, like a ticket title"},\
    "summary":{"type":"string","description":"One short line, under 90 characters, on where the work stands now"},\
    "waiting_on":{"type":["string","null"],"description":"If Claude's last message asks the person a question or for a decision, that question as a question addressed to them (e.g. 'Go ahead and create hello.txt?'), under 90 characters; otherwise null. Also null when Claude is only waiting on agents, workflows or background tasks it launched itself"},\
    "done":{"type":"boolean","description":"True only when everything the person asked for has been achieved and nothing is left for anyone to do: a question answered, a greeting given, something run and reported, or a change found to be already in place. False when what they wanted isn't so yet: a feature not built, a bug not fixed (including one Claude couldn't reproduce or find), files still to change, a plan or description in place of the work, anything left to decide, or agents still running"}}}
    """

    /// Arguments after the `claude` executable. The transcript digest goes on stdin.
    public static func arguments(prompt: String) -> [String] {
        [
            "-p", prompt,
            "--model", model,
            "--output-format", "json",
            "--json-schema", schema,
            // A side call, not a session: keep it out of the session list, give
            // it nothing to run, and keep the person's own hooks from firing
            // on it.
            "--no-session-persistence",
            "--tools", "",
            "--setting-sources", "",
        ]
    }

    public static func prompt(for card: Card) -> String {
        """
        You describe Claude Code sessions for the cards of a kanban board. The transcript of one session is on stdin: what the person asked, what Claude said, and the tools Claude used (in brackets). Judge from the most recent part of the transcript.
        \(card.title.isEmpty ? "The card has no title yet." : "The card's title is \"\(card.title)\". Keep it unless the work has clearly become something else.")
        """
    }

    /// Reads `claude -p --output-format json` output.
    public static func parse(_ data: Data) throws -> Classification {
        try JSONDecoder().decode(Classification.self, from: structuredOutput(data))
    }

    /// The answer in a `claude -p --output-format json --json-schema` reply,
    /// as JSON: its structured output, else its result read as JSON.
    static func structuredOutput(_ data: Data) throws -> Data {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClassifierError.unreadable
        }
        if envelope["is_error"] as? Bool == true {
            throw ClassifierError.failed(envelope["result"] as? String ?? "claude -p failed")
        }
        let structured: Any
        if let output = envelope["structured_output"], !(output is NSNull) {
            structured = output
        } else if let result = envelope["result"] as? String, let resultData = result.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: resultData) {
            structured = decoded
        } else {
            throw ClassifierError.unreadable
        }
        return try JSONSerialization.data(withJSONObject: structured)
    }
}

public enum ClassifierError: Error, LocalizedError {
    case unreadable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The classifier's answer could not be read"
        case .failed(let message): message
        }
    }
}
