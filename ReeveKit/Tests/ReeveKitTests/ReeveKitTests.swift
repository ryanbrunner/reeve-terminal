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

    @Test func stopWithBackgroundShellsIsWaiting() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"Stop","last_assistant_message":"I'll report back.","background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"Explore hooks","agent_type":"Explore"},{"id":"b1","type":"shell","status":"running","description":"swift test","command":"swift test"}]}"#)
        #expect(e.effect.activity == .waiting)
        #expect(e.effect.classify)
        #expect(e.effect.waitingOn == .some(nil))
        #expect(e.effect.background == [BackgroundWork(id: "b1", type: "shell", description: "swift test")])
    }

    @Test func stopWithOnlyAgentsAndMonitorsIsReview() throws {
        let e = try event(#"{"session_id":"s","hook_event_name":"Stop","background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"Explore hooks","agent_type":"Explore"},{"id":"w1","type":"workflow","status":"running"},{"id":"m1","type":"monitor","status":"running","description":"watch logs"}]}"#)
        #expect(e.effect.activity == .needsReview)
        #expect(e.effect.background == [])
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
        card.background = [BackgroundWork(id: "a", type: "shell"), BackgroundWork(id: "b", type: "shell")]
        #expect(card.backgroundLine == "Waiting on 2 shells")
        card.background = [BackgroundWork(id: "a", type: "shell")]
        #expect(card.backgroundLine == "Waiting on 1 shell")
        // A card saved while agents counted still reads sensibly.
        card.background = [BackgroundWork(id: "a", type: "shell"), BackgroundWork(id: "s", type: "subagent")]
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
        card.branch = "reeve/1a2b3c4d"
        card.pullRequests = pr.map { [PullRequest(number: 1, state: $0, url: "https://github.com/o/r/pull/1", branch: "reeve/1a2b3c4d")] }
        card.stagePinned = pinned
        return card
    }

    @Test func aPullRequestFromABranchLeftBehindIsNotRelease() {
        var moved = card(.testing, mode: "auto", pr: .merged)
        moved.headBranch = "next-thing"
        #expect(moved.pullRequest == nil)
        #expect(moved.stage(running: false, hasChanges: true) == .testing)
    }

    @Test func planModeIsPlanning() {
        #expect(card(.backlog, mode: "plan").stage(running: true, hasChanges: true) == .planning)
        #expect(card(.backlog, mode: "plan").stage(running: false, hasChanges: false) == .planning)
    }

    @Test func workingOutsidePlanModeIsInProgress() {
        for mode in ["auto", "default", "acceptEdits", "bypassPermissions"] {
            #expect(card(.planning, mode: mode).stage(running: true, hasChanges: false) == .inProgress)
        }
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
        #expect(card(.inProgress, mode: "auto", pr: .closed).stage(running: false, hasChanges: true) == .testing)
    }

    @Test func neverMovesBackwardsOnItsOwn() {
        // Working on a card in Testing again leaves it there.
        #expect(card(.testing, mode: "auto").stage(running: true, hasChanges: true) == .testing)
        #expect(card(.testing, mode: "auto").stage(running: false, hasChanges: false) == .testing)
        // Back in plan mode, or its pull request closed: still where it got to.
        #expect(card(.inProgress, mode: "plan").stage(running: true, hasChanges: true) == .inProgress)
        #expect(card(.testing, mode: "plan").stage(running: false, hasChanges: false) == .testing)
        #expect(card(.release, mode: "auto", pr: .closed).stage(running: false, hasChanges: true) == .release)
        #expect(card(.release, mode: "auto").stage(running: true, hasChanges: false) == .release)
        #expect(Stage.allCases == Stage.allCases.sorted())
    }

    @Test func aPersonMovingItBackStartsItFromThere() {
        // Dragged back to In Progress: it stays while pinned, then moves on
        // from there once the person speaks to Claude.
        let pinned = card(.inProgress, mode: "auto", pinned: true)
        #expect(pinned.stage(running: false, hasChanges: true) == .inProgress)
        var unpinned = pinned
        unpinned.stagePinned = false
        #expect(unpinned.stage(running: true, hasChanges: true) == .inProgress)
        #expect(unpinned.stage(running: false, hasChanges: true) == .testing)
    }

    @Test func onlyAMergedPullRequestWithNothingOpenIsFullyMerged() {
        #expect(card(.release, mode: "auto", pr: .merged).isFullyMerged)
        #expect(!card(.release, mode: "auto", pr: .open).isFullyMerged)
        #expect(!card(.release, mode: "auto", pr: .draft).isFullyMerged)
        #expect(!card(.release, mode: "auto", pr: .closed).isFullyMerged)
        #expect(!card(.release, mode: "auto").isFullyMerged)

        var another = card(.release, mode: "auto", pr: .merged)
        another.pullRequests?.append(PullRequest(number: 2, state: .open, url: "https://github.com/o/r/pull/2", branch: "other"))
        #expect(!another.isFullyMerged)
        another.pullRequests?[1].state = .closed
        #expect(another.isFullyMerged)

        var left = card(.release, mode: "auto", pr: .merged)
        left.headBranch = "next-thing"
        #expect(!left.isFullyMerged)
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

    @Test func theCLIGoesFirstOnPathAfterTheProfile() {
        #expect(Launch.shellCommand("/bin/claude", ["--resume", "x"], cliDirectory: nil) == "exec /bin/claude --resume x")
        #expect(Launch.shellCommand("/bin/claude", [], cliDirectory: "/Apps/Reeve.app/Contents/Helpers")
            == #"export PATH=/Apps/Reeve.app/Contents/Helpers:"$PATH"; exec /bin/claude"#)
        #expect(Launch.shellCommand("claude", [], cliDirectory: "/My Apps/bin").hasPrefix("export PATH='/My Apps/bin':"))
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
    private func parse(_ json: String) throws -> [PullRequest] {
        try PullRequest.parseAll(Data(json.utf8))
    }

    /// One pull request on branch `b` with the given status rollup.
    private func checks(_ rollup: String) throws -> PullRequest.Checks? {
        try parse(#"[{"number":1,"state":"OPEN","url":"u","headRefName":"b","statusCheckRollup":"# + rollup + #"}]"#).first?.checks
    }

    @Test func noPullRequest() throws {
        #expect(try parse("[]").isEmpty)
        #expect(PullRequest.primary(of: [], on: "b") == nil)
    }

    @Test func readsThemAllNewestFirst() throws {
        let prs = try parse(#"[{"number":3,"state":"CLOSED","url":"u3","title":"First go","headRefName":"a"},{"number":7,"state":"MERGED","url":"u7","title":"Second go","headRefName":"b"}]"#)
        #expect(prs == [
            PullRequest(number: 7, state: .merged, url: "u7", title: "Second go", branch: "b"),
            PullRequest(number: 3, state: .closed, url: "u3", title: "First go", branch: "a"),
        ])
    }

    @Test func prefersTheOpenOne() throws {
        let prs = try parse(#"[{"number":12,"state":"CLOSED","isDraft":false,"url":"u12","headRefName":"b"},{"number":9,"state":"OPEN","isDraft":false,"url":"u9","headRefName":"b"}]"#)
        #expect(PullRequest.primary(of: prs, on: "b")?.number == 9)
    }

    @Test func otherwiseTheNewest() throws {
        let prs = try parse(#"[{"number":3,"state":"CLOSED","isDraft":false,"url":"u3","headRefName":"b"},{"number":7,"state":"MERGED","isDraft":false,"url":"u7","headRefName":"b"}]"#)
        #expect(PullRequest.primary(of: prs, on: "b")?.number == 7)
    }

    @Test func onlyTheBranchTheCardIsOn() throws {
        let prs = try parse(#"[{"number":5,"state":"OPEN","url":"u5","headRefName":"old"}]"#)
        #expect(PullRequest.primary(of: prs, on: "new") == nil)
        #expect(PullRequest.primary(of: prs, on: nil) == nil)
    }

    @Test func draftIsItsOwnState() throws {
        let prs = try parse(#"[{"number":4,"state":"OPEN","isDraft":true,"url":"u4"}]"#)
        #expect(prs.first?.state == .draft)
    }

    @Test func noChecksIsNil() throws {
        #expect(try checks("[]") == nil)
        #expect(try parse(#"[{"number":1,"state":"OPEN","url":"u"}]"#).first?.checks == nil)
    }

    @Test func countsCheckRunsAndStatuses() throws {
        let failing = try checks(#"[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"StatusContext","state":"PENDING"}]"#)
        #expect(failing == PullRequest.Checks(passed: 1, failed: 1, pending: 1))
        #expect(failing?.overall == .failing)

        let pending = try checks(#"[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"}]"#)
        #expect(pending == PullRequest.Checks(passed: 1, pending: 1))
        #expect(pending?.overall == .pending)

        let passing = try checks(#"[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"NEUTRAL"},{"__typename":"StatusContext","state":"SUCCESS"}]"#)
        #expect(passing == PullRequest.Checks(passed: 2))
        #expect(passing?.overall == .passing)

        let errored = try checks(#"[{"__typename":"StatusContext","state":"ERROR"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"TIMED_OUT"}]"#)
        #expect(errored == PullRequest.Checks(failed: 2))
    }

    @Test func aSuccessfulStatusIsNotPending() throws {
        #expect(try checks(#"[{"__typename":"StatusContext","state":"SUCCESS"}]"#) == PullRequest.Checks(passed: 1))
    }

    @Test func readsTheReviewDecision() throws {
        func review(_ decision: String) throws -> PullRequest.Review? {
            try parse(#"[{"number":1,"state":"OPEN","url":"u","reviewDecision":""# + decision + #""}]"#).first?.review
        }
        #expect(try review("APPROVED") == .approved)
        #expect(try review("CHANGES_REQUESTED") == .changesRequested)
        #expect(try review("REVIEW_REQUIRED") == .required)
        #expect(try review("") == nil)
    }

    @Test func readsWhenItWasOpened() throws {
        let prs = try parse(#"[{"number":1,"state":"OPEN","url":"u","createdAt":"2025-11-10T09:30:00Z"}]"#)
        #expect(prs.first?.createdAt == Date(timeIntervalSince1970: 1_762_767_000))
    }

    @Test func leavesAColleaguesPullRequestAlone() {
        let made = Date(timeIntervalSince1970: 1_000_000)
        let before = made.addingTimeInterval(-60), after = made.addingTimeInterval(60)
        let found = [
            PullRequest(number: 1, state: .merged, url: "u1", branch: "theirs", createdAt: before),
            PullRequest(number: 2, state: .open, url: "u2", branch: "split", createdAt: after),
            PullRequest(number: 3, state: .open, url: "u3", branch: "feature", createdAt: before),
            PullRequest(number: 4, state: .open, url: "u4", branch: "old", createdAt: before),
        ]
        let tracked = [PullRequest(number: 4, state: .draft, url: "u4", branch: "old")]
        let kept = PullRequest.belonging(found, owns: ["feature"], tracked: tracked, since: made)
        #expect(kept.map(\.number) == [2, 3, 4])
    }

    @Test func mergeReplacesAndKeeps() {
        let tracked = [PullRequest(number: 3, state: .open, url: "u3", branch: "a"), PullRequest(number: 5, state: .open, url: "u5", branch: "b")]
        let found = [PullRequest(number: 8, state: .draft, url: "u8", branch: "b"), PullRequest(number: 3, state: .merged, url: "u3", branch: "a")]
        #expect(PullRequest.merge(tracked, found).map(\.number) == [8, 5, 3])
        #expect(PullRequest.merge(tracked, found).last?.state == .merged)
    }

    @Test func branchesFromTheReflog() {
        let reflog = """
        commit: Split out the parser
        checkout: moving from reeve/1a2b3c4d to parser-split
        commit: Add the PRs tab
        checkout: moving from 0123456789abcdef0123456789abcdef01234567 to reeve/1a2b3c4d
        checkout: moving from main to 0123456789abcdef0123456789abcdef01234567
        reset: moving to HEAD
        """
        #expect(PullRequest.checkedOutBranches(reflog: reflog) == ["parser-split", "reeve/1a2b3c4d", "main"])
        #expect(PullRequest.checkedOutBranches(reflog: reflog, limit: 1) == ["parser-split"])
        #expect(PullRequest.checkedOutBranches(reflog: "") == [])
    }

    @Test func listsByHeadBranch() {
        let arguments = PullRequest.listArguments(branch: "reeve/1a2b3c4d")
        #expect(arguments.prefix(4) == ["pr", "list", "--head", "reeve/1a2b3c4d"])
        #expect(arguments.contains("number,state,isDraft,url,title,headRefName,statusCheckRollup,reviewDecision,createdAt"))
    }

    @Test func aCardSavedWithOnePullRequestStillLoads() throws {
        let json = #"{"id":"1A2B3C4D-0000-0000-0000-000000000000","sessionId":"1A2B3C4D-0000-0000-0000-000000000001","title":"","titledByPerson":false,"cwd":"/code/app","pullRequest":{"number":4,"state":"open","url":"u4"},"stage":"release","activity":"idle","stagePinned":false,"hasConversation":false,"createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let card = try decoder.decode(Card.self, from: Data(json.utf8))
        #expect(card.pullRequests == nil)
        #expect(card.stage == .release)
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

@Suite struct FileTreeTests {
    private func files(_ paths: String...) -> [FileDiff] {
        paths.map { FileDiff(oldPath: $0, newPath: $0) }
    }

    /// Each visible row as indent and name, so a test reads like the tree.
    private func outline(_ tree: FileTree, collapsed: Set<String> = []) -> [String] {
        tree.rows(collapsed: collapsed).map { String(repeating: "  ", count: $0.depth) + $0.node.name }
    }

    @Test func foldersComeFirstInNameOrder() {
        let tree = FileTree(files("README.md", "b/z.swift", "a.txt", "b/c/d.swift", "B2/x", "b/file10", "b/file9"))
        #expect(outline(tree) == ["b", "  c", "    d.swift", "  file9", "  file10", "  z.swift", "B2", "  x", "a.txt", "README.md"])
    }

    @Test func loneFoldersShareARow() {
        let tree = FileTree(files("App/Sources/Views/A.swift", "App/Sources/Views/B.swift"))
        #expect(outline(tree) == ["App/Sources/Views", "  A.swift", "  B.swift"])
        #expect(tree.nodes.first?.id == "App/Sources/Views/")
    }

    @Test func foldsOnlyUpToWhereTheTreeBranches() {
        let tree = FileTree(files("App/Sources/Views/A.swift", "App/Sources/Model/B.swift", "App/README.md"))
        #expect(outline(tree) == ["App", "  Sources", "    Model", "      B.swift", "    Views", "      A.swift", "  README.md"])
        #expect(tree.rows(collapsed: []).map(\.node.id).contains("App/Sources/Views/"))
    }

    @Test func aFileKeepsItsIndexAndId() {
        let diffs = files("z/one", "a/two")
        let tree = FileTree(diffs)
        let leaves = tree.rows(collapsed: []).compactMap { row -> (String, Int)? in
            if case let .file(i) = row.node.kind { (row.node.id, i) } else { nil }
        }
        #expect(leaves.map(\.0) == [diffs[1].id, diffs[0].id])
        #expect(leaves.map(\.1) == [1, 0])
    }

    @Test func aRenameSitsAtItsNewPath() {
        let tree = FileTree([FileDiff(oldPath: "old/name.swift", newPath: "new/name.swift", status: .renamed)])
        #expect(outline(tree) == ["new", "  name.swift"])
    }

    @Test func aDeletedFileSitsAtItsOldPath() {
        let tree = FileTree([FileDiff(oldPath: "gone/file", newPath: nil, status: .deleted)])
        #expect(outline(tree) == ["gone", "  file"])
    }

    @Test func aClosedFolderHidesWhatsInIt() {
        let tree = FileTree(files("a/x", "a/y", "b/z", "c"))
        #expect(outline(tree, collapsed: ["a/"]) == ["a", "b", "  z", "c"])
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

    @Test func knowsWhereEachBlockStarts() {
        let md = "# Plan\n\nToday there is no\nlogin.\n\n- Add a form\n  that posts\n\n```\nx\n```\n| a |\n|---|\n| b |"
        let located = MarkdownBlock.locate(md)
        #expect(located.map(\.line) == [1, 3, 6, 9, 12])
        #expect(located.map(\.source) == ["# Plan", "Today there is no\nlogin.", "- Add a form\n  that posts", "```\nx\n```", "| a |\n|---|\n| b |"])
        #expect(located.map(\.block) == MarkdownBlock.parse(md))
    }
}

@Suite struct StageNameTests {
    @Test func acceptsWhatPeopleType() {
        #expect(StageName.parse("backlog") == .backlog)
        #expect(StageName.parse("in-progress") == .inProgress)
        #expect(StageName.parse("in_progress") == .inProgress)
        #expect(StageName.parse("In Progress") == .inProgress)
        #expect(StageName.parse("Testing") == .testing)
        #expect(StageName.parse("done") == .release)
        #expect(StageName.parse("shipped") == nil)
        #expect(StageName.name(.inProgress) == "in-progress")
    }
}

@Suite struct CardRefTests {
    private let a = Card(id: UUID(uuidString: "5B701C1D-0000-4000-8000-000000000001")!, title: "Login form", cwd: "/r")
    private let b = Card(id: UUID(uuidString: "5B70AAAA-0000-4000-8000-000000000002")!, title: "Fix tests", cwd: "/r")
    private var cards: [Card] { [a, b] }

    @Test func byIdPrefixOrTitle() throws {
        #expect(try CardRef.resolve("5b701c1d", in: cards).id == a.id)
        #expect(try CardRef.resolve(a.id.uuidString.lowercased(), in: cards).id == a.id)
        #expect(try CardRef.resolve("5B70AA", in: cards).id == b.id)
        #expect(try CardRef.resolve("fix TESTS", in: cards).id == b.id)
    }

    @Test func refusesWhatIsAmbiguousOrMissing() {
        #expect(throws: CardRef.Failure.ambiguous("5b70", [a.id, b.id])) { try CardRef.resolve("5b70", in: cards) }
        #expect(throws: CardRef.Failure.notFound("nope")) { try CardRef.resolve("nope", in: cards) }
        // Too short to be taken for an id.
        #expect(throws: CardRef.Failure.notFound("5b7")) { try CardRef.resolve("5b7", in: cards) }
    }

    @Test func defaultsToTheCardsOwnTerminal() throws {
        let found = try CardRef.current(in: cards, cwd: "/elsewhere", environment: ["REEVE_CARD_ID": b.id.uuidString], realpath: { $0 })
        #expect(found.id == b.id)
    }

    @Test func defaultsToTheDeepestWorktreeHoldingTheFolder() throws {
        var outer = a, inner = b
        outer.worktreePath = "/private/tmp/repo"
        inner.worktreePath = "/private/tmp/repo/.claude/worktrees/reeve-5b70aaaa"
        let realpath = { (p: String) in p.hasPrefix("/tmp") ? "/private" + p : p }
        #expect(try CardRef.current(in: [outer, inner], cwd: "/tmp/repo/.claude/worktrees/reeve-5b70aaaa/src", environment: [:], realpath: realpath).id == b.id)
        #expect(try CardRef.current(in: [outer, inner], cwd: "/tmp/repo/src", environment: [:], realpath: realpath).id == a.id)
        // A sibling folder that only starts with the same name isn't inside it.
        #expect(throws: CardRef.Failure.noDefault) {
            try CardRef.current(in: [outer], cwd: "/private/tmp/repo-2", environment: [:], realpath: realpath)
        }
    }

    @Test func aNamedCardWinsOverTheDefault() throws {
        let found = try CardRef.resolve("login form", in: cards, cwd: "/", environment: ["REEVE_CARD_ID": b.id.uuidString], realpath: { $0 })
        #expect(found.id == a.id)
    }
}

@Suite struct ArgumentsTests {
    @Test func splitsPositionalsOptionsAndFlags() throws {
        let args = try Arguments(["fix", "the", "--title", "New", "--json", "-f", "--model=opus", "--", "--literal"],
                                 valued: ["title", "model"], flags: ["json", "follow"], short: ["f": "follow"])
        #expect(args.positionals == ["fix", "the", "--literal"])
        #expect(args.value("title") == "New")
        #expect(args.value("model") == "opus")
        #expect(args.has("json"))
        #expect(args.has("follow"))
    }

    @Test func refusesWhatItDoesntKnow() {
        #expect(throws: UsageError("unknown option --nope")) { try Arguments(["--nope"], valued: [], flags: []) }
        #expect(throws: UsageError("--title needs a value")) { try Arguments(["--title"], valued: ["title"], flags: []) }
        #expect(throws: UsageError("--json doesn't take a value")) { try Arguments(["--json=1"], valued: [], flags: ["json"]) }
    }

    @Test func aDashAloneIsStdin() throws {
        #expect(try Arguments(["-"], valued: [], flags: []).positionals == ["-"])
    }
}

@Suite struct TableTests {
    @Test func padsAllButTheLastColumn() {
        let text = Table.format([["a", "stage", "title one"], ["bbb", "x", "t"]], indent: "  ")
        #expect(text == "  a    stage  title one\n  bbb  x      t")
    }
}

@Suite struct WaitOutcomeTests {
    private func card(_ activity: Activity, live: Bool = true, starting: Bool = false) -> APICard {
        APICard(card: Card(cwd: "/r", activity: activity), live: live, starting: starting, dialogOpen: false, displayTitle: "t")
    }

    @Test func endsTheWayReeveBoardsDoes() {
        #expect(WaitOutcome.of(card(.running)) == nil)
        #expect(WaitOutcome.of(card(.waiting)) == nil)
        #expect(WaitOutcome.of(card(.idle, starting: true)) == nil)
        #expect(WaitOutcome.of(card(.needsReview)) == .ok)
        #expect(WaitOutcome.of(card(.needsInput)) == .needsInput)
        #expect(WaitOutcome.of(card(.error)) == .failed)
        #expect(WaitOutcome.of(card(.idle)) == .idle)
        // Left running by a session that is gone: nothing to wait for.
        #expect(WaitOutcome.of(card(.running, live: false)) == .idle)
    }
}

@Suite struct APITests {
    @Test func aCardIsFlatWithWhatTheAppKnows() throws {
        var card = Card(title: "Login", cwd: "/r", stage: .inProgress, activity: .running)
        card.branch = "reeve/1a2b3c4d"
        card.pullRequests = [PullRequest(number: 4, state: .open, url: "https://x/4", branch: "reeve/1a2b3c4d"),
                             PullRequest(number: 2, state: .merged, url: "https://x/2", branch: "earlier")]
        let api = APICard(card: card, live: true, starting: false, dialogOpen: true, displayTitle: "Login")
        let data = try API.encoder().encode(api)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((json["pullRequest"] as? [String: Any])?["number"] as? Int == 4)
        #expect((json["pullRequests"] as? [Any])?.count == 2)
        #expect(json["stage"] as? String == "in_progress")
        #expect(json["live"] as? Bool == true)
        #expect(json["dialogOpen"] as? Bool == true)
        #expect(json["displayTitle"] as? String == "Login")
        let back = try API.decoder().decode(APICard.self, from: data)
        #expect(back.card.id == card.id)
        #expect(back.card.pullRequest == card.pullRequest)
        #expect(back.card.pullRequests == card.pullRequests)
        #expect(back.live && back.dialogOpen && !back.starting)
    }

    @Test func serverInfoIsPrivateToThePerson() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let info = ServerInfo(port: 5000, pid: 42, token: ServerInfo.newToken())
        try info.write(dataDir: dir)
        #expect(ServerInfo.read(dataDir: dir) == info)
        let mode = try FileManager.default.attributesOfItem(atPath: ServerInfo.url(in: dir).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        ServerInfo.remove(dataDir: dir, pid: 7)
        #expect(ServerInfo.read(dataDir: dir) != nil)
        ServerInfo.remove(dataDir: dir, pid: 42)
        #expect(ServerInfo.read(dataDir: dir) == nil)
    }

    @Test func dataDirectoryFollowsTheEnvironment() {
        #expect(DataDirectory.url(environment: ["REEVE_DATA_DIR": "/tmp/r"]).path == "/tmp/r")
        #expect(DataDirectory.url(environment: [:]).path.hasSuffix("Application Support/Reeve Terminal"))
        // A Reeve on other data, as a smoke test runs, keeps its preferences apart.
        #expect(DataDirectory.preferencesSuite(environment: [:]) == nil)
        #expect(DataDirectory.preferencesSuite(environment: ["REEVE_DATA_DIR": ""]) == nil)
        #expect(DataDirectory.preferencesSuite(environment: ["REEVE_DATA_DIR": "/tmp/r"]) == "com.ryanbrunner.reeve-terminal.other-data")
    }
}

@Suite struct DiffRenderTests {
    @Test func rendersWhatItParses() {
        let text = """
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -1,3 +1,3 @@
         # Reeve
        -old line
        +new line
         end
        \\ No newline at end of file
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hello
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/old.txt b/moved.txt
        rename from old.txt
        rename to moved.txt
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        diff --git a/logo.png b/logo.png
        Binary files a/logo.png and b/logo.png differ

        """
        let files = DiffParser.parse(text)
        #expect(files.count == 6)
        #expect(DiffParser.parse(DiffParser.render(files)) == files)
    }

    @Test func survivesJSON() throws {
        let files = DiffParser.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-x\n+y\n")
        let changes = ChangesResponse(files: files, base: "abc1234", untrackedLeftOut: 0, truncated: false)
        let back = try API.decoder().decode(ChangesResponse.self, from: API.encoder().encode(changes))
        #expect(back == changes)
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

    @Test func planCommentsGoOutdatedWhenTheirPartIsRewritten() {
        let path = "/u/.claude/plans/p.md"
        let before = MarkdownBlock.locate("# Plan\n\nUse a cookie.\n\n- Test it")
        let onCookie = ReviewThread(anchor: ReviewAnchor(plan: path, block: before[1]), messages: [ReviewMessage(author: .person, body: "why?")])
        let onTests = ReviewThread(anchor: ReviewAnchor(plan: path, block: before[2]), messages: [ReviewMessage(author: .person, body: "which?")])
        #expect(PlanReviewPlacement([onCookie, onTests], plan: path, blocks: before).byBlock.count == 2)
        let after = MarkdownBlock.locate("# Plan\n\nUse a session token.\n\n- Test it")
        let placed = PlanReviewPlacement([onCookie, onTests], plan: path, blocks: after)
        #expect(placed.outdated == [onCookie])
        #expect(placed.byBlock[ReviewAnchor(plan: path, block: after[2]).key] == [onTests])
        #expect(PlanReviewPlacement([onTests], plan: "/u/.claude/plans/other.md", blocks: after).outdated == [onTests])
    }

    @Test func planCommentsFollowTheirPartWhenItMoves() {
        let path = "/p.md"
        let before = MarkdownBlock.locate("# Plan\n\n- Test it")
        let onTests = ReviewThread(anchor: ReviewAnchor(plan: path, block: before[1]), messages: [ReviewMessage(author: .person, body: "which?")])
        let after = MarkdownBlock.locate("# Plan\n\nFirst, a new step.\n\n- Test it")
        let placed = PlanReviewPlacement([onTests], plan: path, blocks: after)
        #expect(placed.outdated.isEmpty)
        #expect(placed.byBlock[ReviewAnchor(plan: path, block: after[2]).key] == [onTests])
    }

    @Test func thePlanFileSaysWhatEachCommentIsOn() throws {
        let block = MarkdownBlock.locate("# Plan\n\nUse a cookie.")[1]
        let thread = ReviewThread(anchor: ReviewAnchor(plan: "/p.md", block: block), messages: [ReviewMessage(author: .person, body: "why?")])
        let doc = try JSONSerialization.jsonObject(with: ReviewFile.encode(plan: [thread], planPath: "/p.md")) as! [String: Any]
        let comments = doc["comments"] as! [[String: Any]]
        #expect(doc["plan"] as? String == "/p.md")
        #expect(comments[0]["line"] as? Int == 3)
        #expect(comments[0]["text"] as? String == "Use a cookie.")
        #expect(comments[0]["reply"] is NSNull)
    }

    @Test func claudeMayEditReviewFilesInPlanMode() throws {
        func event(_ name: String, _ tool: String, _ path: String) throws -> HookEvent {
            try HookEvent.decode(Data(#"{"session_id":"s","hook_event_name":"\#(name)","permission_mode":"plan","tool_name":"\#(tool)","tool_input":{"file_path":"\#(path)"}}"#.utf8))
        }
        let dir = "/Users/a/Library/Application Support/Reeve/reviews"
        let allowed = try #require(ReviewFile.permission(for: event("PreToolUse", "Edit", dir + "/X-plan.json"), reviewsDir: dir))
        let output = try JSONSerialization.jsonObject(with: allowed) as! [String: Any]
        #expect((output["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String == "allow")
        #expect(try ReviewFile.permission(for: event("PreToolUse", "Write", dir + "/X.json"), reviewsDir: dir + "/") != nil)
        #expect(try ReviewFile.permission(for: event("PreToolUse", "Edit", dir + "/../board.json"), reviewsDir: dir) == nil)
        #expect(try ReviewFile.permission(for: event("PreToolUse", "Edit", dir + "/X.md"), reviewsDir: dir) == nil)
        #expect(try ReviewFile.permission(for: event("PreToolUse", "Edit", "/repo/app.swift"), reviewsDir: dir) == nil)
        #expect(try ReviewFile.permission(for: event("PostToolUse", "Edit", dir + "/X.json"), reviewsDir: dir) == nil)
        #expect(try ReviewFile.permission(for: event("PreToolUse", "Bash", dir + "/X.json"), reviewsDir: dir) == nil)
    }

    @Test func aBrokenFileChangesNothing() {
        let a = comment(.new, 2, "let b = 3")
        #expect(ReviewFile.merge(Data("{not json".utf8), into: [a]) == [a])
    }
}

@Suite struct PlanDialogTests {
    // The labels Claude Code 2.1.286 draws, with the plan above them.
    private let screen = [
        "│ 1. Add the button                                │",
        "│ 2. Wire it up                                    │",
        "",
        " Would you like to proceed?",
        "",
        " ❯ 1. Yes, clear context (42% used) and use auto mode",
        "   2. Yes, and use auto mode",
        "   3. Yes, manually approve edits",
        "   4. Tell Claude what to change",
        "      shift+tab to approve with this feedback",
        "",
        " ctrl-g to edit in Vim",
    ]

    @Test func readsTheDialogBelowThePlan() {
        let dialog = PlanDialog.find(onScreen: screen)
        #expect(dialog?.options == ["Yes, clear context (42% used) and use auto mode", "Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"])
        #expect(dialog?.selected == 0)
    }

    @Test func approvesIntoAutoModeKeepingTheContext() throws {
        let dialog = try #require(PlanDialog.find(onScreen: screen))
        #expect(dialog.approval == 1)
        #expect(dialog.moves(to: dialog.approval) == ["\u{1b}[B"])
    }

    @Test func followsAPointerMovedByHand() throws {
        var moved = screen
        moved[5] = "   1. Yes, clear context (42% used) and use auto mode"
        moved[8] = " ❯ 4. Tell Claude what to change"
        let dialog = try #require(PlanDialog.find(onScreen: moved))
        #expect(dialog.selected == 3)
        #expect(dialog.moves(to: dialog.approval) == ["\u{1b}[A", "\u{1b}[A"])
    }

    @Test func withoutAutoModeAcceptsEdits() throws {
        let dialog = try #require(PlanDialog.find(onScreen: [" ❯ 1. Yes, auto-accept edits", "   2. Yes, manually approve edits", "   3. No, keep planning"]))
        #expect(dialog.approval == 0)
        #expect(dialog.moves(to: 0).isEmpty)
    }

    @Test func feedbackGoesToTheOptionThatDoesntApprove() throws {
        #expect(try #require(PlanDialog.find(onScreen: screen)).feedback == 3)
        let older = try #require(PlanDialog.find(onScreen: [" ❯ 1. Yes, auto-accept edits", "   2. Yes, manually approve edits", "   3. No, keep planning"]))
        #expect(older.feedback == 2)
        #expect(older.moves(to: 2) == ["\u{1b}[B", "\u{1b}[B"])
    }

    @Test func neverPicksBypassingPermissions() throws {
        let dialog = try #require(PlanDialog.find(onScreen: [" ❯ 1. Yes, and switch to bypass permissions for this session", "   2. Yes, manually approve edits", "   3. No, keep planning"]))
        #expect(dialog.approval == 1)
    }

    @Test func readsGapsTheTerminalLeftEmpty() throws {
        // As SwiftTerm reads Claude Code's dialog back: skipped cells are NULs.
        let dialog = try #require(PlanDialog.find(onScreen: ["\u{0} ❯ 1. Yes, and use auto mode", "\u{0}\u{0}\u{0}\u{0}\u{0}2. Yes,\u{0}manually\u{0}approve\u{0}edits", "     3. Tell Claude what to change"]))
        #expect(dialog.options == ["Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"])
        #expect(dialog.approval == 0)
    }

    @Test func noPointerNoTellingWhereEnterLands() {
        #expect(PlanDialog.find(onScreen: ["   1. Yes, and use auto mode", "   2. Yes, manually approve edits", "   3. Tell Claude what to change"]) == nil)
    }

    @Test func noDialogNoOptions() {
        #expect(PlanDialog.find(onScreen: ["> hello", "1. Add the button", "2. Wire it up"]) == nil)
    }

    @Test func approvalAndDialogHooks() throws {
        let approved = try HookEvent.decode(Data(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"ExitPlanMode"}"#.utf8))
        #expect(approved.approvesPlan && approved.closesPlanDialog)
        let subagent = try HookEvent.decode(Data(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Read","agent_id":"a"}"#.utf8))
        #expect(!subagent.closesPlanDialog)
        let notification = try HookEvent.decode(Data(#"{"session_id":"s","hook_event_name":"Notification","notification_type":"permission_prompt"}"#.utf8))
        #expect(!notification.closesPlanDialog)
    }

    @Test func aNewPlanIsNotYetApproved() throws {
        func event(_ json: String) throws -> HookEvent { try HookEvent.decode(Data(json.utf8)) }
        #expect(try event(#"{"session_id":"s","hook_event_name":"PreToolUse","permission_mode":"plan","tool_name":"ExitPlanMode","tool_input":{"plan":"p"}}"#).putsUpNewPlan)
        #expect(try event(#"{"session_id":"s","hook_event_name":"PostToolUse","permission_mode":"plan","tool_name":"Write","tool_input":{"file_path":"/u/.claude/plans/a.md"}}"#).putsUpNewPlan)
        // Ticking off the approved plan as the work goes.
        #expect(try !event(#"{"session_id":"s","hook_event_name":"PostToolUse","permission_mode":"auto","tool_name":"Edit","tool_input":{"file_path":"/u/.claude/plans/a.md"}}"#).putsUpNewPlan)
        #expect(try !event(#"{"session_id":"s","hook_event_name":"PostToolUse","permission_mode":"plan","tool_name":"ExitPlanMode"}"#).putsUpNewPlan)
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

@Suite struct CommandBarTests {
    @Test func runsOnlyReeveWithNothingOfThePersonsLoaded() {
        let args = CommandBar.arguments(repos: ["/r/a"], startRepo: "/r/a")
        func value(after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(args.first == "-p")
        #expect(value(after: "--tools") == "Bash")
        #expect(value(after: "--allowedTools") == "Bash(reeve *)")
        let denied = args.firstIndex(of: "--disallowedTools").map { Array(args[($0 + 1)...].prefix { !$0.hasPrefix("--") }) }
        #expect(denied == ["Bash(reeve card close*)", "Bash(reeve *--force*)"])
        #expect(value(after: "--permission-mode") == "dontAsk")
        #expect(value(after: "--setting-sources") == "")
        #expect(value(after: "--output-format") == "json")
        #expect(args.contains("--no-session-persistence") && args.contains("--strict-mcp-config"))
    }

    @Test func promptNamesTheReposAndWhereNewCardsStart() {
        let prompt = CommandBar.systemPrompt(repos: ["/r/a", "/r/b"], startRepo: "/r/b")
        #expect(prompt.contains("- /r/a\n- /r/b"))
        #expect(prompt.contains("Use /r/b unless the person names another."))
        #expect(prompt.contains("Always pass --cwd"))
        #expect(prompt.contains(CLIUsage.text))
        #expect(CommandBar.systemPrompt(repos: [], startRepo: nil).contains("no repos on the list"))
    }

    @Test func readsTheReplyAndWhatWasRefused() throws {
        let json = """
        {"type":"result","subtype":"success","is_error":false,"result":"  Added “Fix login”. \\n",
         "permission_denials":[{"tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"reeve card close abc"}}]}
        """
        let answer = try CommandBar.parse(Data(json.utf8))
        #expect(answer == CommandBarAnswer(reply: "Added “Fix login”.", refused: ["reeve card close abc"]))
    }

    @Test func anErrorIsThrown() {
        let json = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#
        #expect(throws: ClassifierError.self) { try CommandBar.parse(Data(json.utf8)) }
        #expect(throws: ClassifierError.self) { try CommandBar.parse(Data("nope".utf8)) }
    }
}

@Suite struct LaneTests {
    @Test func aCardOutsideEveryLaneIsInTheFirst() {
        let lanes = [Lane(name: "Web"), Lane(name: "Infra")]
        var card = Card(cwd: "/r")
        #expect(card.lane(in: lanes) == lanes[0])
        card.laneId = lanes[1].id
        #expect(card.lane(in: lanes) == lanes[1])
        card.laneId = UUID()
        #expect(card.lane(in: lanes) == lanes[0])
        #expect(card.lane(in: []) == nil)
    }

    @Test func aLaneIsNamedByNameOrId() {
        let lanes = [Lane(name: "Web"), Lane(name: "Infra")]
        #expect(Lane.find("infra", in: lanes) == lanes[1])
        #expect(Lane.find(" Web ", in: lanes) == lanes[0])
        #expect(Lane.find(lanes[1].id.uuidString, in: lanes) == lanes[1])
        #expect(Lane.find(String(lanes[1].id.uuidString.prefix(8)).lowercased(), in: lanes) == lanes[1])
        #expect(Lane.find("Mobile", in: lanes) == nil)
        #expect(Lane.find("", in: lanes) == nil)
    }

    @Test func leavingTheBacklogStartsByColumn() {
        #expect(Card.launch(movingTo: .planning) == .plan)
        #expect(Card.launch(movingTo: .inProgress) == .build)
        #expect(Card.launch(movingTo: .backlog) == nil)
        #expect(Card.launch(movingTo: .testing) == nil)
        #expect(Card.launch(movingTo: .release) == nil)
    }

    @Test func aCardSavedBeforeLanesIsInNoneAndStarted() throws {
        var card = Card(title: "Old", cwd: "/r")
        card.laneId = UUID()
        card.queued = true
        var json = try JSONSerialization.jsonObject(with: API.encoder().encode(card)) as! [String: Any]
        json["laneId"] = nil
        json["queued"] = nil
        let old = try API.decoder().decode(Card.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.laneId == nil && old.queued == nil)
    }

    @Test func createAndMoveBodiesTakeBacklogAndLanes() throws {
        let plain = try API.decoder().decode(CreateCardBody.self, from: Data(#"{"cwd":"/r"}"#.utf8))
        #expect(!plain.backlog && plain.lane == nil && plain.mode == .plan)
        let queued = try API.decoder().decode(CreateCardBody.self, from: Data(#"{"cwd":"/r","backlog":true,"lane":"Web"}"#.utf8))
        #expect(queued.backlog && queued.lane == "Web")

        // As an older `reeve` sends it.
        let stageOnly = try API.decoder().decode(MoveBody.self, from: Data(#"{"stage":"testing"}"#.utf8))
        #expect(stageOnly == MoveBody(stage: .testing))
        let laneOnly = try API.decoder().decode(MoveBody.self, from: Data(#"{"lane":"Infra","inFolder":true}"#.utf8))
        #expect(laneOnly.stage == nil && laneOnly.lane == "Infra" && laneOnly.inFolder)
    }

    @Test func theBoardListsItsLanes() throws {
        let lanes = [Lane(name: "Web")]
        let board = BoardResponse(cards: [], lanes: lanes, selectedId: nil)
        #expect(try API.decoder().decode(BoardResponse.self, from: API.encoder().encode(board)).lanes == lanes)
        let old = try API.decoder().decode(BoardResponse.self, from: Data(#"{"cards":[]}"#.utf8))
        #expect(old.lanes == nil)
    }
}

@Suite struct IdeasTests {
    private let since = Date(timeIntervalSince1970: 1_000)

    private func card(_ title: String, repo: String = "/code/app", stage: Stage = .release, shipped: Double? = nil) -> Card {
        var card = Card(title: title, cwd: repo + "/.claude/worktrees/x", stage: stage)
        card.repoPath = repo
        card.shippedAt = shipped.map { Date(timeIntervalSince1970: $0) }
        return card
    }

    @Test func theLastCardToShipSinceTheSwitchIsAskedOnce() {
        let first = card("First", shipped: 2_000)
        var last = card("Last", shipped: 3_000)
        let before = card("Before the switch", shipped: 500)
        #expect(Ideas.source(for: "/code/app", board: [first, last, before], archive: [], since: since)?.id == last.id)
        last.ideasAsked = true
        // Not the one before it: that would work back through the repo's history.
        #expect(Ideas.source(for: "/code/app", board: [first, last], archive: [], since: since) == nil)
    }

    @Test func notWhileTheRepoHasWorkOpen() {
        let shipped = card("Shipped", shipped: 2_000)
        #expect(Ideas.source(for: "/code/app", board: [shipped, card("Building", stage: .inProgress)], archive: [], since: since) == nil)
        var queued = Card(title: "Queued", cwd: "/code/app", stage: .backlog)
        queued.queued = true
        #expect(Ideas.source(for: "/code/app", board: [shipped, queued], archive: [], since: since) == nil)
        // Another repo's work, or a pull request in Release, doesn't hold it up.
        let elsewhere = card("Elsewhere", repo: "/code/other", stage: .inProgress)
        let releasing = card("Releasing", stage: .release)
        #expect(Ideas.source(for: "/code/app", board: [shipped, elsewhere, releasing], archive: [], since: since)?.id == shipped.id)
    }

    @Test func anArchivedCardStillCounts() {
        var archived = card("Archived", shipped: 2_000)
        archived.archivedAt = Date(timeIntervalSince1970: 2_500)
        #expect(Ideas.source(for: "/code/app", board: [], archive: [archived], since: since)?.id == archived.id)
        #expect(Ideas.source(for: "/code/app", board: [], archive: [], since: since) == nil)
    }

    @Test func acceptsAtMostThreeNewNamedIdeas() {
        let ideas = ["Shipped before", "  ", "Dark mode", "dark mode ", "Search", "Export", "Import"]
            .map { Ideas.Idea(title: $0, body: "b") }
        #expect(Ideas.accepted(ideas, existingTitles: ["shipped before"]).map(\.title) == ["Dark mode", "Search", "Export"])
    }

    @Test func readsIdeasAndFoldsCriteriaIntoTheBrief() throws {
        let out = #"{"type":"result","is_error":false,"result":"","structured_output":{"ideas":[{"title":" Dark mode ","body":"Add it.","criteria":["Toggle in settings"," "]}]}}"#
        let ideas = try Ideas.parse(Data(out.utf8))
        #expect(ideas == [Ideas.Idea(title: "Dark mode", body: "Add it.", criteria: ["Toggle in settings"])])
        #expect(ideas[0].brief == "Dark mode\n\nAdd it.\n\nDone when:\n- Toggle in settings")
        #expect(Ideas.Idea(title: "T", body: "Just this.").brief == "T\n\nJust this.")
        let none = #"{"type":"result","is_error":false,"result":"{\"ideas\":[]}"}"#
        #expect(try Ideas.parse(Data(none.utf8)).isEmpty)
    }

    @Test func schemaIsValidJSONAndToolsOnlyRead() throws {
        _ = try JSONSerialization.jsonObject(with: Data(Ideas.schema.utf8))
        let args = Ideas.arguments(prompt: "p")
        #expect(args[args.firstIndex(of: "--tools")! + 1] == "Read,Grep,Glob")
    }

    @Test func promptListsTheRepoNewestFirst() {
        var older = card("Older")
        older.createdAt = Date(timeIntervalSince1970: 1)
        var newer = card("Newer", shipped: 2_000)
        newer.createdAt = Date(timeIntervalSince1970: 2)
        newer.summary = "Added a thing"
        let prompt = Ideas.prompt(repo: "/code/app", directory: "/code/app", source: newer, history: [older, newer])
        #expect(prompt.contains("**app**"))
        #expect(prompt.contains("- Newer (shipped)\n- Older (Release)"))
        #expect(prompt.contains("Added a thing"))
    }

    /// A brief Claude wrote reaches the card's `claude` as written: backticks
    /// and `$(` stay text, and nothing runs in the person's checkout.
    @Test func aBriefSurvivesTheShell() throws {
        let brief = Ideas.Idea(title: "It's \"quoted\"", body: "Run `ls` and $(touch /tmp/no)\nthen $HOME", criteria: ["'q'"]).brief
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s " + Launch.shellQuote(brief)]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == brief)
    }

    @Test func boardsSavedBeforeIdeasStillLoad() throws {
        var ledger = VibesLedger(since: since)
        ledger.ideas = 2
        var json = try JSONSerialization.jsonObject(with: API.encoder().encode(ledger)) as! [String: Any]
        json["ideas"] = nil
        let old = try API.decoder().decode(VibesLedger.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.ideas == nil && old.since == since)
    }
}

@Suite struct DependencyTests {
    private func card(_ title: String, stage: Stage = .backlog, pr: PullRequest.State? = nil) -> Card {
        var card = Card(title: title, cwd: "/r", stage: stage)
        card.branch = "reeve/\(title)"
        card.pullRequests = pr.map { [PullRequest(number: 1, state: $0, url: "https://github.com/o/r/pull/1", branch: "reeve/\(title)")] }
        return card
    }

    private func waiting(on target: Card) -> Card {
        var waiting = card("waiting")
        waiting.queued = true
        waiting.dependsOnId = target.id
        return waiting
    }

    @Test func unmergedBlocks() {
        let target = card("target", stage: .release, pr: .open)
        let waiter = waiting(on: target)
        #expect(Dependency.blocker(of: waiter, in: [waiter, target])?.id == target.id)
        #expect(Dependency.status(of: target) == "Release, PR not merged")
        let refusal = Dependency.refusal(waiter, in: [waiter, target], name: \.title)
        #expect(refusal?.error == "waits on “target”, which hasn't merged")
        #expect(refusal?.detail?.contains(CardRef.short(target.id)) == true)
    }

    @Test func mergedPullRequestLetsItStart() {
        let target = card("target", stage: .release, pr: .merged)
        let waiter = waiting(on: target)
        #expect(Dependency.blocker(of: waiter, in: [waiter, target]) == nil)
        #expect(Dependency.refusal(waiter, in: [waiter, target], name: \.title) == nil)
        #expect(Dependency.status(of: target) == "merged")
    }

    @Test func branchFoundOnMainLetsItStart() {
        var target = card("target", stage: .testing)
        target.merged = true
        #expect(!Dependency.stillBlocking(target))
    }

    @Test func archivedOrClosedDoesNotBlock() {
        var target = card("target", stage: .release, pr: .open)
        target.archivedAt = Date()
        #expect(!Dependency.stillBlocking(target))
        let waiter = waiting(on: card("gone"))
        #expect(Dependency.blocker(of: waiter, in: [waiter]) == nil)
    }

    @Test func statusSaysHowFarOff() {
        var queued = card("q")
        queued.queued = true
        #expect(Dependency.status(of: queued) == "Backlog, not started")
        #expect(Dependency.status(of: card("t", stage: .testing)) == "Testing")
        #expect(Dependency.status(of: card("r", stage: .release)) == "Release, no pull request yet")
    }

    @Test func noWaitingOnItself() {
        let a = card("a")
        #expect(Dependency.linkRefusal(a, waitingOn: a, in: [a], name: \.title)?.error == "a card can't wait on itself")
    }

    @Test func noLoops() {
        let a = card("a")
        var b = card("b")
        var c = card("c")
        b.dependsOnId = a.id
        #expect(Dependency.linkRefusal(a, waitingOn: b, in: [a, b], name: \.title)?.detail == "“b” already waits on “a”")
        c.dependsOnId = b.id
        let loop = Dependency.linkRefusal(a, waitingOn: c, in: [a, b, c], name: \.title)
        #expect(loop?.error == "that would make a loop")
        #expect(loop?.detail == "“c” already waits on “a”, through “b”")
        #expect(Dependency.linkRefusal(c, waitingOn: a, in: [a, b, c], name: \.title) == nil)
    }

    @Test func aBadLoopOnDiskDoesNotHang() {
        var a = card("a")
        var b = card("b")
        a.dependsOnId = b.id
        b.dependsOnId = a.id
        let c = card("c")
        #expect(Dependency.linkRefusal(c, waitingOn: a, in: [a, b, c], name: \.title) == nil)
    }

    @Test func heldCardsSayWhyInVibesMode() {
        #expect(Vibes.chip(stage: .backlog, activity: .idle, shipped: false, merged: false, waitingOn: "“Login”", options: VibesOptions()) == "waits on “Login”")
        #expect(Vibes.chip(stage: .backlog, activity: .idle, shipped: false, merged: false, options: VibesOptions()) == "auto-run")
    }

    @Test func theLinkTravelsWithTheCard() throws {
        let target = card("target")
        let waiter = waiting(on: target)
        let api = APICard(card: waiter, live: false, starting: false, dialogOpen: false, displayTitle: "waiting",
                          dependsOn: DependencyLink(id: target.id, title: "target", done: false, status: "Backlog"))
        let back = try API.decoder().decode(APICard.self, from: API.encoder().encode(api))
        #expect(back.dependsOn == api.dependsOn)
        #expect(back.card.dependsOnId == target.id)
    }
}
