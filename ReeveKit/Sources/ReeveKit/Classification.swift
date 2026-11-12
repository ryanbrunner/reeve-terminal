import Foundation

/// What Claude decided about a card after reading its session.
public struct Classification: Decodable, Equatable, Sendable {
    public var stage: Stage
    public var title: String
    public var summary: String
    /// The question Claude's last message leaves a person to answer, if any.
    public var waitingOn: String?

    enum CodingKeys: String, CodingKey {
        case stage, title, summary
        case waitingOn = "waiting_on"
    }

    public init(stage: Stage, title: String, summary: String, waitingOn: String?) {
        self.stage = stage
        self.title = title
        self.summary = summary
        self.waitingOn = waitingOn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decode(Stage.self, forKey: .stage)
        title = try c.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
        summary = try c.decode(String.self, forKey: .summary).trimmingCharacters(in: .whitespacesAndNewlines)
        let waiting = try c.decodeIfPresent(String.self, forKey: .waitingOn)?.trimmingCharacters(in: .whitespacesAndNewlines)
        waitingOn = (waiting?.isEmpty ?? true) ? nil : waiting
    }
}

/// The `claude -p` call that classifies a card, and reading its answer.
public enum Classifier {
    public static let model = "haiku"

    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["stage","title","summary","waiting_on"],"properties":{\
    "stage":{"type":"string","enum":["backlog","planning","in_progress","testing","release"]},\
    "title":{"type":"string","description":"2 to 6 words naming the piece of work, like a ticket title"},\
    "summary":{"type":"string","description":"One short line, under 90 characters, on where the work stands now"},\
    "waiting_on":{"type":["string","null"],"description":"If Claude's last message asks the person a question or for a decision, that question as a question addressed to them (e.g. 'Go ahead and create hello.txt?'), under 90 characters; otherwise null"}}}
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
        You sort Claude Code sessions onto a kanban board. The transcript of one session is on stdin: what the person asked, what Claude said, and the tools Claude used (in brackets).

        Columns:
        - backlog: nothing substantive has started. Only an idea, a question, or chat.
        - planning: understanding the problem, reading code, researching, designing, or writing a plan. No real code changes yet.
        - in_progress: implementing. Claude is editing files and writing code.
        - testing: verifying the change. Running tests, checking behaviour, reviewing, or fixing what verification found.
        - release: wrapping up. Committing, pushing, opening or merging a pull request, or the work is finished.

        The card is in "\(card.stage.rawValue)" now. Judge from the most recent part of the transcript. Move it only when the transcript clearly shows the work is in another column; if it is unclear, keep "\(card.stage.rawValue)". Work moves backward too, for example from testing back to in_progress when a test fails and Claude goes back to changing code.
        \(card.title.isEmpty ? "The card has no title yet." : "The card's title is \"\(card.title)\". Keep it unless the work has clearly become something else.")
        """
    }

    /// Reads `claude -p --output-format json` output.
    public static func parse(_ data: Data) throws -> Classification {
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
        let json = try JSONSerialization.data(withJSONObject: structured)
        return try JSONDecoder().decode(Classification.self, from: json)
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
