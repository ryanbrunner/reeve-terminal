import Foundation
import Testing
@testable import ReeveKit

@Suite struct HookEffectTests {
    private func event(_ json: String) throws -> HookEvent {
        try HookEvent.decode(Data(json.utf8))
    }

    @Test func promptStartsARun() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":"hi","transcript_path":"/t.jsonl"}"#)
        #expect(e.transcriptPath == "/t.jsonl")
        #expect(e.effect == HookEffect(activity: .running, waitingOn: .some(nil), startsConversation: true, unpinsStage: true))
    }

    @Test func askingAQuestionNeedsInput() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?","options":[]}]}}"#)
        #expect(e.effect.activity == .needsInput)
        #expect(e.effect.waitingOn == .some("Which database?"))
    }

    @Test func otherToolsAreRunning() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        #expect(e.effect.activity == .running)
    }

    @Test func permissionPromptNeedsInput() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#)
        #expect(e.effect.activity == .needsInput)
        #expect(e.effect.waitingOn == .some("Claude needs your permission to use Bash"))
    }

    @Test func idleReminderChangesNothing() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#)
        #expect(e.effect == HookEffect())
    }

    @Test func stopAsksForReviewAndClassifies() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done."}"#)
        #expect(e.effect.activity == .needsReview)
        #expect(e.effect.classify)
    }
}

@Suite struct TranscriptDigestTests {
    @Test func keepsTextAndToolNamesOnly() {
        let jsonl = """
        {"type":"queue-operation","operation":"enqueue"}
        {"type":"user","message":{"role":"user","content":"add a login page"}}
        {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"secret"},{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","content":"lots of output"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Tests pass."}]}}
        {"type":"user","isSidechain":true,"message":{"content":"subagent chatter"}}
        {"type":"user","message":{"content":"<command-name>/login</command-name>"}}
        """
        let digest = TranscriptDigest.digest(jsonl: jsonl)
        #expect(digest == "USER: add a login page\n  [Bash npm test]\nCLAUDE: Tests pass.")
    }

    @Test func keepsTheMostRecentEnd() {
        let line = #"{"type":"user","message":{"content":"0123456789"}}"#
        let digest = TranscriptDigest.digest(jsonl: Array(repeating: line, count: 50).joined(separator: "\n"), limit: 40)
        #expect(digest.hasPrefix("…\n"))
        #expect(digest.count == 42)
    }
}

@Suite struct ClassifierTests {
    @Test func readsStructuredOutput() throws {
        let out = #"{"type":"result","is_error":false,"result":"","structured_output":{"stage":"planning","title":"Login page","summary":"Plan written","waiting_on":"Should I proceed?"}}"#
        let c = try Classifier.parse(Data(out.utf8))
        #expect(c == Classification(stage: .planning, title: "Login page", summary: "Plan written", waitingOn: "Should I proceed?"))
    }

    @Test func fallsBackToTheResultText() throws {
        let out = #"{"type":"result","is_error":false,"result":"{\"stage\":\"in_progress\",\"title\":\"X\",\"summary\":\"Y\",\"waiting_on\":\"\"}"}"#
        let c = try Classifier.parse(Data(out.utf8))
        #expect(c.stage == .inProgress)
        #expect(c.waitingOn == nil)
    }

    @Test func reportsErrors() {
        let out = #"{"type":"result","is_error":true,"result":"Not logged in"}"#
        #expect(throws: ClassifierError.self) { try Classifier.parse(Data(out.utf8)) }
    }

    @Test func schemaIsValidJSON() throws {
        _ = try JSONSerialization.jsonObject(with: Data(Classifier.schema.utf8))
    }
}

@Suite struct LaunchTests {
    @Test func newCardsGetTheirSessionIdAndResumedOnesResume() {
        var card = Card(cwd: "/tmp")
        #expect(Launch.claudeArguments(for: card, prompt: "go").prefix(2) == ["--session-id", card.sessionId.uuidString.lowercased()])
        #expect(Launch.claudeArguments(for: card, prompt: "go").last == "go")
        card.hasConversation = true
        let resumed = Launch.claudeArguments(for: card, prompt: "go")
        #expect(resumed.prefix(2) == ["--resume", card.sessionId.uuidString.lowercased()])
        #expect(resumed.last != "go")
    }

    @Test func newSessionsStartInTheCardsModeAndResumedOnesDont() {
        var card = Card(cwd: "/tmp")
        #expect(!Launch.claudeArguments(for: card).contains("--permission-mode"))
        card.startMode = .plan
        let planned = Launch.claudeArguments(for: card, prompt: "go")
        #expect(planned.suffix(3) == ["--permission-mode", "plan", "go"])
        card.startMode = .build
        #expect(Launch.claudeArguments(for: card).suffix(2) == ["--permission-mode", "auto"])
        card.hasConversation = true
        #expect(!Launch.claudeArguments(for: card).contains("--permission-mode"))
    }

    @Test func modelAndEffortRideAlongWhenSet() {
        var card = Card(cwd: "/tmp")
        let plain = Launch.claudeArguments(for: card, prompt: "go")
        #expect(!plain.contains("--model"))
        #expect(!plain.contains("--effort"))
        card.model = "opus"
        card.effort = "high"
        card.startMode = .plan
        let args = Launch.claudeArguments(for: card, prompt: "go")
        #expect(args.firstIndex(of: "--model").map { args[$0 + 1] } == "opus")
        #expect(args.firstIndex(of: "--effort").map { args[$0 + 1] } == "high")
        #expect(args.last == "go")
        card.hasConversation = true
        let resumed = Launch.claudeArguments(for: card)
        #expect(resumed.firstIndex(of: "--model").map { resumed[$0 + 1] } == "opus")
        #expect(resumed.firstIndex(of: "--effort").map { resumed[$0 + 1] } == "high")
    }

    @Test func cardsSavedBeforeModelsStillLoad() throws {
        let card = Card(cwd: "/tmp")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as! [String: Any]
        json["model"] = nil
        json["effort"] = nil
        let decoded = try JSONDecoder().decode(Card.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.model == nil)
        #expect(decoded.effort == nil)
    }

    @Test func hookSettingsCoverEveryEvent() throws {
        let settings = try JSONSerialization.jsonObject(with: Data(Launch.hookSettings().utf8)) as! [String: Any]
        let hooks = settings["hooks"] as! [String: Any]
        #expect(Set(hooks.keys) == Set(Launch.hookedEvents))
    }

    @Test func quoting() {
        #expect(Launch.shellQuote("plain-arg") == "plain-arg")
        #expect(Launch.shellQuote("it's") == #"'it'\''s'"#)
        #expect(Launch.shellQuote("") == "''")
    }

    @Test func environmentDropsNestedClaudeVars() {
        let env = Launch.environment(base: ["CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "PATH": "/bin", "HOME": "/h"], hookPort: 4000, cardId: UUID())
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["CLAUDE_CODE_ENTRYPOINT"] == nil)
        #expect(env["PATH"] == "/bin")
        #expect(env["REEVE_HOOK_PORT"] == "4000")
    }
}

@Suite struct WorktreeTests {
    @Test func namesComeFromTheCard() {
        let id = UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000000")!
        #expect(Worktree.branch(for: id) == "reeve/1a2b3c4d")
        #expect(Worktree.path(repo: "/code/app", cardId: id) == "/code/app/.claude/worktrees/reeve-1a2b3c4d")
    }

    @Test func mainCheckoutHoldsTheGitDir() {
        #expect(Worktree.mainCheckout(commonDir: "/code/app/.git", topLevel: "/code/app/.claude/worktrees/x") == "/code/app")
        #expect(Worktree.mainCheckout(commonDir: "/code/app.git", topLevel: "/code/app") == "/code/app")
    }

    @Test func keepsTheChosenSubfolder() {
        #expect(Worktree.workingDirectory(worktree: "/w", prefix: "") == "/w")
        #expect(Worktree.workingDirectory(worktree: "/w", prefix: "pkg/api/\n") == "/w/pkg/api")
    }

    @Test func excludesOnce() {
        #expect(Worktree.excluding("") == "/.claude/worktrees/\n")
        #expect(Worktree.excluding("# git ls-files\n*.log") == "# git ls-files\n*.log\n/.claude/worktrees/\n")
        #expect(Worktree.excluding("*.log\n.claude/worktrees/\n") == nil)
    }

    @Test func cardsSavedBeforeWorktreesStillLoad() throws {
        let json = #"{"id":"1A2B3C4D-0000-0000-0000-000000000000","sessionId":"1A2B3C4D-0000-0000-0000-000000000001","title":"","titledByPerson":false,"cwd":"/code/app","stage":"backlog","activity":"idle","stagePinned":false,"hasConversation":false,"createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let card = try decoder.decode(Card.self, from: Data(json.utf8))
        #expect(card.worktreePath == nil)
        #expect(card.startMode == nil)
        #expect(card.folderName == "app")
    }
}

@Suite struct VibesTests {
    private func event(_ json: String) throws -> HookEvent {
        try HookEvent.decode(Data(json.utf8))
    }

    @Test func knowsWhenThePlanDialogIsUp() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":"x"}}"#)
        #expect(Vibes.showsPlanDialog(e))
        // No hook answer gets past the dialog, so none is given.
        #expect(Vibes.reply(to: e) == nil)
        let pre = try event(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode"}"#)
        #expect(!Vibes.showsPlanDialog(pre))
    }

    @Test func answersQuestionsByRefusingThem() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?"}]}}"#)
        #expect(Vibes.reply(to: e) == VibesReply(question: "Which database?"))
        let out = try JSONSerialization.jsonObject(with: VibesReply(question: nil).json) as! [String: Any]
        let specific = out["hookSpecificOutput"] as! [String: Any]
        #expect(specific["permissionDecision"] as? String == "deny")
        #expect(specific["permissionDecisionReason"] as? String == Vibes.noOneHome)
    }

    @Test func leavesToolPermissionsToAPerson() throws {
        let bash = try event(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf x"}}"#)
        #expect(Vibes.reply(to: bash) == nil)
        let plan = try event(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode"}"#)
        #expect(Vibes.reply(to: plan) == nil)
    }

    @Test func walksACardToRelease() {
        let options = VibesOptions()
        guard case .nudge(let test, false) = Vibes.next(stage: .inProgress, waitingOn: nil, nudges: nil, options: options) else {
            Issue.record("expected a nudge to test"); return
        }
        #expect(test.contains("test"))
        guard case .nudge(let ship, true) = Vibes.next(stage: .testing, waitingOn: nil, nudges: nil, options: options) else {
            Issue.record("expected a nudge to ship"); return
        }
        #expect(ship.contains("merge it into main"))
        #expect(!ship.contains("\n"))
        let asked = VibesNudges(stage: .testing).adding(from: .testing, ships: true)
        #expect(Vibes.next(stage: .release, waitingOn: nil, nudges: asked, options: options) == .shipped)
    }

    @Test func skippingTestingShipsStraightFromInProgress() {
        let options = VibesOptions(skipPlanning: false, skipTesting: true, autoMerge: false)
        guard case .nudge(let ship, true) = Vibes.next(stage: .inProgress, waitingOn: nil, nudges: nil, options: options) else {
            Issue.record("expected a nudge to ship"); return
        }
        #expect(ship.contains("Leave it open"))
        #expect(options.skips(.testing))
        #expect(!options.skips(.planning))
    }

    @Test func answersAQuestionLeftInTheMessage() {
        #expect(Vibes.next(stage: .planning, waitingOn: "Go ahead?", nudges: nil, options: VibesOptions()) == .answer("Go ahead?"))
    }

    @Test func givesUpGoingRoundInCircles() {
        var nudges = VibesNudges(stage: .inProgress)
        for _ in 0..<Vibes.maxNudges { nudges = nudges.adding(from: .inProgress, ships: false) }
        #expect(Vibes.next(stage: .inProgress, waitingOn: nil, nudges: nudges, options: VibesOptions()) == .giveUp)
        // A new column starts the count again.
        #expect(nudges.adding(from: .testing, ships: true).count == 1)
        if case .nudge = Vibes.next(stage: .testing, waitingOn: nil, nudges: nudges, options: VibesOptions()) {} else {
            Issue.record("a new column should be pushed again")
        }
    }

    @Test func ledgerKeepsFourLines() {
        var ledger = VibesLedger()
        for n in 1...6 { ledger.note("line \(n)") }
        #expect(ledger.log == ["line 6", "line 5", "line 4", "line 3"])
    }

    @Test func cardsSavedBeforeVibesStillLoad() throws {
        let json = #"{"id":"1A2B3C4D-0000-0000-0000-000000000000","sessionId":"1A2B3C4D-0000-0000-0000-000000000001","title":"","titledByPerson":false,"cwd":"/code/app","stage":"backlog","activity":"idle","stagePinned":false,"hasConversation":false,"createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let card = try decoder.decode(Card.self, from: Data(json.utf8))
        #expect(card.vibes == nil)
        #expect(card.shippedAt == nil)
    }
}
