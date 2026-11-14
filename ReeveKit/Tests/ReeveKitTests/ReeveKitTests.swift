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
        #expect(e.effect == HookEffect(activity: .running, waitingOn: .some(nil), startsConversation: true, unpinsStage: true, working: true, background: []))
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

    @Test func readsThePermissionMode() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"Stop","permission_mode":"plan"}"#)
        #expect(e.permissionMode == "plan")
        #expect(!e.effect.working)
    }

    @Test func editingToolsChangeFiles() throws {
        let edit = try event(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/a"}}"#)
        #expect(edit.effect.editsFiles)
        #expect(edit.effect.working)
        let read = try event(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/a"}}"#)
        #expect(!read.effect.editsFiles)
    }

    @Test func exitPlanModeCarriesThePlan() throws {
        let e = try event(##"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":"# Login\n\n- Add a form","planFilePath":"/Users/r/.claude/plans/calm-otter.md"}}"##)
        #expect(e.effect.activity == .needsInput)
        #expect(e.effect.waitingOn == .some("Approve the plan?"))
        #expect(e.effect.plan == PlanSighting(text: "# Login\n\n- Add a form", path: "/Users/r/.claude/plans/calm-otter.md"))
    }

    @Test func writingAPlanFileIsADraft() throws {
        let e = try event(##"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/Users/r/.claude/plans/calm-otter.md","content":"# Login"}}"##)
        #expect(e.effect.activity == .running)
        #expect(e.effect.plan == PlanSighting(text: nil, path: "/Users/r/.claude/plans/calm-otter.md"))
    }

    @Test func writingOtherFilesIsNotAPlan() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/code/app/README.md"}}"#)
        #expect(e.effect.plan == nil)
        let docs = try event(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/code/app/docs/plans/q3.md"}}"#)
        #expect(docs.effect.plan == nil)
    }

    @Test func stopAsksForReviewAndClassifies() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done."}"#)
        #expect(e.effect.activity == .needsReview)
        #expect(e.effect.classify)
        #expect(e.effect.background == [])
    }

    @Test func stopWithBackgroundAgentsIsWaiting() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"Stop","last_assistant_message":"I'll report back.","background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"Explore hooks","agent_type":"Explore"},{"id":"b1","type":"shell","status":"running","description":"npm run dev","command":"npm run dev"}]}"#)
        #expect(e.effect.activity == .waiting)
        #expect(e.effect.classify)
        #expect(e.effect.waitingOn == .some(nil))
        #expect(e.effect.background == [BackgroundWork(id: "a1", type: "subagent", description: "Explore hooks", agentType: "Explore")])
    }

    @Test func stopWithOnlyShellsAndMonitorsIsReview() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"Stop","background_tasks":[{"id":"b1","type":"shell","status":"running","description":"npm run dev"},{"id":"m1","type":"monitor","status":"running","description":"watch logs"}]}"#)
        #expect(e.effect.activity == .needsReview)
    }

    @Test func subagentToolsLeaveTheActivityAlone() throws {
        let pre = try event(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","agent_id":"a1","agent_type":"Explore"}"#)
        #expect(pre.effect.activity == nil)
        #expect(pre.effect.waitingOn == nil)
        #expect(pre.effect.background == nil)
        let post = try event(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Edit","agent_id":"a1","tool_input":{"file_path":"/a"}}"#)
        #expect(post.effect.activity == nil)
        #expect(post.effect.editsFiles)
    }

    @Test func subagentWorkClearsAnAnsweredPrompt() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Bash","agent_id":"a1"}"#)
        #expect(e.effect.bySubagent)
        #expect(HookEvent.activityAfterSubagentWork(.needsInput, askedByNotification: true, waitingOnBackground: true) == .waiting)
        #expect(HookEvent.activityAfterSubagentWork(.needsInput, askedByNotification: true, waitingOnBackground: false) == .running)
        // Claude's own question stands until Claude moves on.
        #expect(HookEvent.activityAfterSubagentWork(.needsInput, askedByNotification: false, waitingOnBackground: true) == nil)
        #expect(HookEvent.activityAfterSubagentWork(.waiting, askedByNotification: true, waitingOnBackground: true) == nil)
    }

    @Test func aSubagentAskingStillNeedsInput() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","agent_id":"a1","tool_input":{"questions":[{"question":"Which one?"}]}}"#)
        #expect(e.effect.activity == .needsInput)
    }

    @Test func onlyBlockingNotificationsNeedInput() throws {
        for type in ["agent_needs_input", "elicitation_dialog", "worker_permission_prompt"] {
            let e = try event(#"{"session_id":"s","hook_event_name":"Notification","message":"m","notification_type":"\#(type)"}"#)
            #expect(e.effect.activity == .needsInput, "\(type)")
        }
        for type in ["agent_completed", "auth_success", "quota_auto_resume_fired"] {
            let e = try event(#"{"session_id":"s","hook_event_name":"Notification","message":"Explore finished","notification_type":"\#(type)"}"#)
            #expect(e.effect == HookEffect(), "\(type)")
        }
    }

    @Test func untypedNotificationsAreToldByTheirWords() throws {
        let idle = try event(#"{"session_id":"s","hook_event_name":"Notification","message":"Claude is waiting for your input"}"#)
        #expect(idle.effect == HookEffect())
        let permission = try event(#"{"session_id":"s","hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}"#)
        #expect(permission.effect.activity == .needsInput)
    }

    @Test func aWaitingCardSaysWhatItWaitsOn() {
        var card = Card(cwd: "/tmp", activity: .waiting)
        card.background = [BackgroundWork(id: "a", type: "subagent"), BackgroundWork(id: "b", type: "subagent")]
        #expect(card.backgroundLine == "Waiting on 2 subagents")
        card.background = [BackgroundWork(id: "w", type: "workflow")]
        #expect(card.backgroundLine == "Waiting on 1 workflow")
        card.background = [BackgroundWork(id: "a", type: "subagent"), BackgroundWork(id: "w", type: "workflow")]
        #expect(card.backgroundLine == "Waiting on 2 tasks")
        card.activity = .running
        #expect(card.backgroundLine == nil)
    }

    @Test func aCardSavedBeforeBackgroundDecodes() throws {
        var card = Card(cwd: "/tmp")
        card.background = [BackgroundWork(id: "a1", type: "subagent")]
        let encoder = JSONEncoder()
        var json = try JSONSerialization.jsonObject(with: encoder.encode(card)) as! [String: Any]
        json["background"] = nil
        let decoded = try JSONDecoder().decode(Card.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.background == nil)
    }
}

@Suite struct StageRuleTests {
    private func card(_ stage: Stage, mode: String?, pr: PullRequest.State? = nil, pinned: Bool = false) -> Card {
        var card = Card(cwd: "/tmp", stage: stage)
        card.permissionMode = mode
        card.pullRequest = pr.map { PullRequest(number: 1, state: $0, url: "https://github.com/o/r/pull/1") }
        card.stagePinned = pinned
        return card
    }

    @Test func planModeIsPlanning() {
        #expect(card(.inProgress, mode: "plan").stage(running: true, hasChanges: true) == .planning)
        #expect(card(.backlog, mode: "plan").stage(running: false, hasChanges: false) == .planning)
    }

    @Test func workingOutsidePlanModeIsInProgress() {
        for mode in ["auto", "default", "acceptEdits", "bypassPermissions"] {
            #expect(card(.planning, mode: mode).stage(running: true, hasChanges: false) == .inProgress)
        }
        #expect(card(.testing, mode: "auto").stage(running: true, hasChanges: true) == .inProgress)
    }

    @Test func changedCodeAtTheEndOfATurnIsTesting() {
        #expect(card(.inProgress, mode: "auto").stage(running: false, hasChanges: true) == .testing)
        #expect(card(.inProgress, mode: "auto").stage(running: false, hasChanges: false) == .inProgress)
        #expect(card(.planning, mode: "auto").stage(running: false, hasChanges: false) == .inProgress)
    }

    @Test func aPullRequestIsRelease() {
        #expect(card(.testing, mode: "auto", pr: .open).stage(running: false, hasChanges: true) == .release)
        #expect(card(.inProgress, mode: "auto", pr: .draft).stage(running: true, hasChanges: false) == .release)
        #expect(card(.inProgress, mode: "plan", pr: .merged).stage(running: true, hasChanges: false) == .release)
        #expect(card(.release, mode: "auto", pr: .closed).stage(running: false, hasChanges: true) == .testing)
    }

    @Test func nothingKnownOrPinnedStaysPut() {
        #expect(card(.backlog, mode: nil).stage(running: true, hasChanges: true) == .backlog)
        #expect(card(.release, mode: "plan", pinned: true).stage(running: true, hasChanges: false) == .release)
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
        let out = #"{"type":"result","is_error":false,"result":"","structured_output":{"title":"Login page","summary":"Plan written","waiting_on":"Should I proceed?"}}"#
        let c = try Classifier.parse(Data(out.utf8))
        #expect(c == Classification(title: "Login page", summary: "Plan written", waitingOn: "Should I proceed?"))
    }

    @Test func fallsBackToTheResultText() throws {
        let out = #"{"type":"result","is_error":false,"result":"{\"title\":\"X\",\"summary\":\"Y\",\"waiting_on\":\"\"}"}"#
        let c = try Classifier.parse(Data(out.utf8))
        #expect(c.title == "X")
        #expect(c.waitingOn == nil)
    }

    @Test func waitingOnThatIsNoQuestionIsDropped() throws {
        let out = #"{"type":"result","is_error":false,"result":"","structured_output":{"title":"X","summary":"Y","waiting_on":"Both background agents to finish"}}"#
        #expect(try Classifier.parse(Data(out.utf8)).waitingOn == nil)
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
        let resumed = Launch.claudeArguments(for: card)
        #expect(resumed.prefix(2) == ["--resume", card.sessionId.uuidString.lowercased()])
        // A resumed session takes a prompt as its next turn: how a review wakes it.
        #expect(Launch.claudeArguments(for: card, prompt: "go").last == "go")
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

    @Test func reviewFilesNeedNoPermission() throws {
        let settings = try JSONSerialization.jsonObject(with: Data(Launch.hookSettings(reviewsDir: "/Users/a/Library/Application Support/Reeve/reviews").utf8)) as! [String: Any]
        let allow = (settings["permissions"] as! [String: Any])["allow"] as! [String]
        #expect(allow == ["Read(//Users/a/Library/Application Support/Reeve/reviews/*.json)", "Edit(//Users/a/Library/Application Support/Reeve/reviews/*.json)"])
        #expect(settings["hooks"] != nil)
        let plain = try JSONSerialization.jsonObject(with: Data(Launch.hookSettings().utf8)) as! [String: Any]
        #expect(plain["permissions"] == nil)
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

    @Test func environmentPointsGlossAtThePreview() {
        let id = UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000000")!
        let env = Launch.environment(base: [:], hookPort: 4000, cardId: id)
        #expect(env["GLOSS_HOST"] == "http://127.0.0.1:4000/gloss/1A2B3C4D-0000-0000-0000-000000000000")
    }
}

@Suite struct GlossTests {
    private func parse(_ json: String) -> Gloss.Message? {
        Gloss.parse(Data(json.utf8))
    }

    @Test func hello() {
        #expect(parse(#"{"type":"hello","script":"x()","binding":"__glossRpc","deliver":"__glossDeliver"}"#)
            == .hello(script: "x()", binding: "__glossRpc", deliver: "__glossDeliver"))
    }

    @Test func helloRefusesNamesThatArentPlain() {
        #expect(parse(#"{"type":"hello","script":"x()","binding":"a;alert(1)","deliver":"d"}"#) == nil)
    }

    @Test func deliverKeepsTheDelivery() throws {
        guard case let .deliver(json) = parse(#"{"type":"deliver","delivery":{"id":3,"state":{"round":1}}}"#) else {
            Issue.record("not a delivery")
            return
        }
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(object?["id"] as? Int == 3)
    }

    @Test func requests() {
        #expect(parse(#"{"type":"request","id":1,"method":"navigate","url":"http://localhost:3000/"}"#)
            == .request(id: 1, .navigate(URL(string: "http://localhost:3000/")!)))
        #expect(parse(#"{"type":"request","id":2,"method":"reload"}"#) == .request(id: 2, .reload))
        #expect(parse(#"{"type":"request","id":3,"method":"view"}"#) == .request(id: 3, .view))
        #expect(parse(#"{"type":"request","id":4,"method":"snapshot","clip":{"x":1,"y":2.5,"width":3,"height":4},"path":"/s/p.png"}"#)
            == .request(id: 4, .snapshot(clip: CGRect(x: 1, y: 2.5, width: 3, height: 4), path: "/s/p.png")))
        #expect(parse(#"{"type":"request","id":5,"method":"dance"}"#) == nil)
    }

    @Test func readyAndNoise() {
        #expect(parse(#"{"type":"ready","id":"abc","port":1}"#) == .ready)
        #expect(parse("Debugger attached.") == nil)
    }

    @Test func linesToGloss() throws {
        let rpc = Gloss.rpc(payload: #"{"id":1}"#, url: "http://localhost/", topFrame: true)
        #expect(rpc.last == 0x0A)
        let object = try JSONSerialization.jsonObject(with: rpc) as? [String: Any]
        #expect(object?["type"] as? String == "rpc")
        #expect(object?["topFrame"] as? Bool == true)
        let failed = try JSONSerialization.jsonObject(with: Gloss.reply(id: 2, error: "no page")) as? [String: Any]
        #expect(failed?["error"] as? String == "no page")
        #expect(failed?["result"] == nil)
    }

    @Test func sessionArguments() {
        #expect(Gloss.sessionArguments(cwd: "/w", url: "http://localhost/", live: true)
            == ["__session", "--host", "--cwd", "/w", "--url", "http://localhost/", "--live"])
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
        #expect(card.baseCommit == nil)
        #expect(card.plan == nil)
        #expect(card.review == nil)
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

    @Test func walksACardToShipping() {
        let options = VibesOptions()
        guard case .nudge(_, .build) = Vibes.next(stage: .inProgress, waitingOn: nil, nudges: nil, options: options) else {
            Issue.record("nothing changed yet: build it"); return
        }
        guard case .nudge(let test, .test) = Vibes.next(stage: .testing, waitingOn: nil, nudges: nil, options: options) else {
            Issue.record("changes made: test them"); return
        }
        #expect(test.contains("test"))
        let tested = VibesNudges(stage: .testing).adding(from: .testing, step: .test)
        guard case .nudge(let ship, .ship) = Vibes.next(stage: .testing, waitingOn: nil, nudges: tested, options: options) else {
            Issue.record("tested: ship it"); return
        }
        #expect(ship.contains("merge it into main"))
        #expect(!ship.contains("\n"))
        // Wherever its column ends up, a card told to ship is checked.
        let asked = tested.adding(from: .testing, step: .ship)
        #expect(Vibes.next(stage: .testing, waitingOn: nil, nudges: asked, options: options) == .checkShipped)
        #expect(Vibes.next(stage: .release, waitingOn: nil, nudges: asked, options: options) == .checkShipped)
    }

    @Test func skippingTestingShipsStraightFromChanges() {
        let options = VibesOptions(skipPlanning: false, skipTesting: true, autoMerge: false)
        guard case .nudge(let ship, .ship) = Vibes.next(stage: .testing, waitingOn: nil, nudges: nil, options: options) else {
            Issue.record("expected a nudge to ship"); return
        }
        #expect(ship.contains("Leave it open"))
        #expect(options.skips(.testing))
        #expect(!options.skips(.planning))
    }

    @Test func answersAQuestionLeftInTheMessage() {
        #expect(Vibes.next(stage: .planning, waitingOn: "Go ahead?", nudges: nil, options: VibesOptions()) == .answer("Go ahead?"))
    }

    @Test func answersDontUseUpThePushes() {
        var nudges = VibesNudges(stage: .testing)
        for _ in 0..<Vibes.maxNudges { nudges = nudges.answering(in: .testing) }
        #expect(Vibes.next(stage: .testing, waitingOn: "More?", nudges: nudges, options: VibesOptions()) == .giveUp)
        if case .nudge = Vibes.next(stage: .testing, waitingOn: nil, nudges: nudges, options: VibesOptions()) {} else {
            Issue.record("answers shouldn't stop the pushes")
        }
    }

    @Test func givesUpGoingRoundInCircles() {
        var nudges = VibesNudges(stage: .inProgress)
        for _ in 0..<Vibes.maxNudges { nudges = nudges.adding(from: .inProgress, step: .build) }
        #expect(Vibes.next(stage: .inProgress, waitingOn: nil, nudges: nudges, options: VibesOptions()) == .giveUp)
        // A new column starts the count again.
        #expect(nudges.adding(from: .testing, step: .test).count == 1)
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

@Suite struct PullRequestTests {
    private func parse(_ json: String) throws -> PullRequest? {
        try PullRequest.parse(Data(json.utf8))
    }

    @Test func noPullRequest() throws {
        #expect(try parse("[]") == nil)
    }

    @Test func prefersTheOpenOne() throws {
        let pr = try parse(#"[{"number":12,"state":"CLOSED","isDraft":false,"url":"u12"},{"number":9,"state":"OPEN","isDraft":false,"url":"u9"}]"#)
        #expect(pr == PullRequest(number: 9, state: .open, url: "u9"))
    }

    @Test func otherwiseTheNewest() throws {
        let pr = try parse(#"[{"number":3,"state":"CLOSED","isDraft":false,"url":"u3"},{"number":7,"state":"MERGED","isDraft":false,"url":"u7"}]"#)
        #expect(pr == PullRequest(number: 7, state: .merged, url: "u7"))
    }

    @Test func draftIsItsOwnState() throws {
        let pr = try parse(#"[{"number":4,"state":"OPEN","isDraft":true,"url":"u4"}]"#)
        #expect(pr?.state == .draft)
    }

    @Test func listsByHeadBranch() {
        #expect(PullRequest.listArguments(branch: "reeve/1a2b3c4d").prefix(4) == ["pr", "list", "--head", "reeve/1a2b3c4d"])
    }
}

@Suite struct PlanTests {
    @Test func findsTheLatestPlanInATranscript() {
        let jsonl = """
        {"type":"user","message":{"content":"plan a login page"}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"ExitPlanMode","input":{"plan":"first","planFilePath":"/h/.claude/plans/a.md"}}]}}
        {"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","name":"ExitPlanMode","input":{"plan":"subagent","planFilePath":"/h/.claude/plans/z.md"}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/h/.claude/plans/a.md"}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/code/app/plans/notes.txt"}}]}}
        """
        #expect(PlanSighting.latest(inTranscript: jsonl) == PlanSighting(text: "first", path: "/h/.claude/plans/a.md"))
    }

    @Test func aNewPlanFileReplacesTheOldPlan() {
        let draft = PlanSighting(text: nil, path: "/h/.claude/plans/b.md")
        #expect(draft.merged(over: PlanSighting(text: "first", path: "/h/.claude/plans/a.md")) == draft)
    }

    @Test func noPlanInATranscriptWithout() {
        #expect(PlanSighting.latest(inTranscript: #"{"type":"user","message":{"content":"hi"}}"#) == nil)
    }
}

@Suite struct DiffParserTests {
    // Real `git diff <base>` output, with the flags `DiffParser.arguments` pins.
    static let sample = """
    diff --git a/blob.bin b/blob.bin
    index bdc955b..8835708 100644
    Binary files a/blob.bin and b/blob.bin differ
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    index b023018..0000000
    --- a/gone.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye
    diff --git a/keep.txt b/keep.txt
    index 4cb29ea..51d3b44 100644
    --- a/keep.txt
    +++ b/keep.txt
    @@ -1,3 +1,3 @@
     one
    -two
    -three
    +--- two
    +three
    \\ No newline at end of file
    diff --git a/old.txt b/new.txt
    similarity index 100%
    rename from old.txt
    rename to new.txt
    diff --git a/tool.sh b/tool.sh
    old mode 100644
    new mode 100755
    diff --git a/fresh file.txt b/fresh file.txt
    new file mode 100644
    index 0000000..5786b13
    --- /dev/null
    +++ b/fresh file.txt\t
    @@ -0,0 +1,2 @@
    +brand
    +new

    """

    @Test func readsEveryKindOfChange() {
        let files = DiffParser.parse(Self.sample)
        #expect(files.map(\.path) == ["blob.bin", "gone.txt", "keep.txt", "new.txt", "tool.sh", "fresh file.txt"])
        #expect(files.map(\.status) == [.modified, .deleted, .modified, .renamed, .modified, .added])
        #expect(files[0].isBinary)
        #expect(files[1].newPath == nil && files[1].deletions == 1)
        #expect(files[3].oldPath == "old.txt" && files[3].hunks.isEmpty)
        #expect(files[4].modeChange == "100644 → 100755")
        #expect(files[5].oldPath == nil && files[5].additions == 2)
    }

    @Test func aRemovedLineThatLooksLikeAHeaderStaysInItsHunk() {
        let keep = DiffParser.parse(Self.sample)[2]
        #expect(keep.hunks.count == 1)
        #expect(keep.hunks[0].lines.map(\.kind) == [.context, .removed, .removed, .added, .added, .note])
        #expect(keep.hunks[0].lines[3].text == "--- two")
        #expect(keep.hunks[0].lines[3].newNumber == 2)
        #expect(keep.hunks[0].lines[2].oldNumber == 3)
        #expect(keep.hunks[0].lines[5].text == "No newline at end of file")
    }

    @Test func quotedPaths() {
        let text = """
        diff --git "a/tab\\there" "b/tab\\there"
        --- "a/tab\\there"
        +++ "b/tab\\there"
        @@ -1 +1 @@
        -a
        +b
        """
        #expect(DiffParser.parse(text).first?.path == "tab\there")
    }
}

@Suite struct MarkdownTests {
    @Test func readsAPlan() {
        let md = """
        # Login page

        ## Context
        Today there is no
        login.

        - Add a form
          that posts
        - [ ] Test it
        1. First
        10) Tenth

        ```swift
        let x = 1

        print(x)
        ```

        | File | Change |
        |---|:--:|
        | a.swift | new |

        > Note this
        ---
        """
        #expect(MarkdownBlock.parse(md) == [
            .heading(level: 1, text: "Login page"),
            .heading(level: 2, text: "Context"),
            .paragraph("Today there is no login."),
            .listItem(marker: "•", indent: 0, text: "Add a form that posts"),
            .listItem(marker: "•", indent: 0, text: "☐ Test it"),
            .listItem(marker: "1.", indent: 0, text: "First"),
            .listItem(marker: "10.", indent: 0, text: "Tenth"),
            .code(language: "swift", text: "let x = 1\n\nprint(x)"),
            .table([["File", "Change"], ["a.swift", "new"]]),
            .quote("Note this"),
            .rule,
        ])
    }
}

@Suite struct ReviewTests {
    private let diff = DiffParser.parse("""
    diff --git a/app.swift b/app.swift
    --- a/app.swift
    +++ b/app.swift
    @@ -1,3 +1,3 @@
     let a = 1
    -let b = 2
    +let b = 3
     let c = 4
    """)

    private func comment(_ path: String = "app.swift", _ side: ReviewThread.Side = .new, _ line: Int, _ code: String, pending: Bool = false) -> ReviewThread {
        ReviewThread(anchor: ReviewAnchor(path: path, side: side, line: line, code: code), messages: [ReviewMessage(author: .person, body: "why?", pending: pending)])
    }

    private func comment(_ side: ReviewThread.Side, _ line: Int, _ code: String) -> ReviewThread {
        comment("app.swift", side, line, code)
    }

    @Test func linesAnchorOnTheirSide() {
        let lines = diff[0].hunks[0].lines
        #expect(ReviewAnchor(file: diff[0], line: lines[1]) == ReviewAnchor(path: "app.swift", side: .old, line: 2, code: "let b = 2"))
        #expect(ReviewAnchor(file: diff[0], line: lines[2]) == ReviewAnchor(path: "app.swift", side: .new, line: 2, code: "let b = 3"))
        #expect(ReviewAnchor(file: diff[0], line: lines[3]) == ReviewAnchor(path: "app.swift", side: .new, line: 3, code: "let c = 4"))
    }

    @Test func threadsFollowTheirLineOrSayItChanged() {
        let onAdded = comment(.new, 2, "let b = 3")
        let onRemoved = comment(.old, 2, "let b = 2")
        let changed = comment(.new, 2, "let b = 9")
        let gone = comment(.new, 40, "let z = 0")
        let elsewhere = comment("other.swift", .new, 1, "x")
        let placed = ReviewPlacement([onAdded, onRemoved, changed, gone, elsewhere], in: diff)
        #expect(placed.byLine[onAdded.anchor.key] == [onAdded])
        #expect(placed.byLine[onRemoved.anchor.key] == [onRemoved])
        #expect(placed.outdated["app.swift"] == [changed, gone])
        #expect(placed.orphaned == [elsewhere])
    }

    @Test func theFileHoldsEveryThreadWaitingOnClaude() throws {
        let sent = comment(.new, 2, "let b = 3")
        var answered = comment(.new, 3, "let c = 4")
        answered.messages.append(ReviewMessage(author: .claude, body: "done"))
        let draft = comment("app.swift", .new, 1, "let a = 1", pending: true)
        var resolved = comment(.old, 2, "let b = 2")
        resolved.resolved = true
        let doc = try JSONSerialization.jsonObject(with: ReviewFile.encode([sent, answered, draft, resolved])) as! [String: Any]
        let comments = doc["comments"] as! [[String: Any]]
        #expect(comments.map { $0["id"] as! String } == [sent.id.uuidString])
        #expect(comments[0]["reply"] is NSNull)
        #expect(comments[0]["line"] as? Int == 2)
    }

    @Test func repliesComeBackOnce() {
        let a = comment(.new, 2, "let b = 3")
        let b = comment(.new, 3, "let c = 4")
        let file = Data(#"{"comments":[{"id":"\#(a.id.uuidString)","reply":"Fixed it."},{"id":"\#(b.id.uuidString)","reply":null},{"id":"\#(UUID().uuidString)","reply":"?"}]}"#.utf8)
        let merged = ReviewFile.merge(file, into: [a, b])
        #expect(merged[0].messages.last?.author == .claude)
        #expect(merged[0].messages.last?.body == "Fixed it.")
        #expect(!merged[0].awaitingReply)
        #expect(merged[1] == b)
        #expect(ReviewFile.merge(file, into: merged) == merged)
    }

    @Test func aBrokenFileChangesNothing() {
        let a = comment(.new, 2, "let b = 3")
        #expect(ReviewFile.merge(Data("{not json".utf8), into: [a]) == [a])
    }
}

@Suite struct RepoTests {
    @Test func isNamedForItsFolder() {
        #expect(Repo(path: "/code/app").name == "app")
        #expect(Repo(path: "/code/app/").name == "app")
    }

    @Test func seedingKeepsOneOfEachInOrder() {
        let repos = Repo.seeded(from: ["/code/b", "/code/a", "/code/b/", "/code/./a"])
        #expect(repos.map(\.path) == ["/code/b", "/code/a"])
    }

    @Test func roundTripsThroughJSON() throws {
        let repo = Repo(path: "/code/app")
        let decoded = try JSONDecoder().decode(Repo.self, from: JSONEncoder().encode(repo))
        #expect(decoded == repo)
    }
}
