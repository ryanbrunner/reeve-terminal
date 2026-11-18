# Reeve (terminal)

A native macOS kanban board of Claude Code sessions. Each card is a terminal
running the real `claude`, in a folder. The board fills the window; click a
card and its terminal opens over the board. Close it and you're back on the
board, with the session still running.

    backlog → planning → in_progress → testing → release

Reeve doesn't talk to Claude itself, so the terminal is Claude Code at full
feature parity. What Reeve adds is the board.

- **Name a card where it goes.** Each of Backlog, Planning and In Progress
  has a New card field (⌘N opens the one in the top lane's Backlog). Type a
  name and press Return; the field stays open for the next one, and Esc puts
  it away. The name is the card's title and the first thing Claude is told.
  Which column you name it in decides what happens:
  - **Backlog**: nothing. The card waits with no worktree and no session
    until you move it. Drag it to Planning and it starts in plan mode; to
    In Progress and it starts in auto mode. Its worktree is made then, from
    HEAD as it is then. An open backlog card has Plan it and Start building
    buttons that do the same.
  - **Planning**: Claude starts in plan mode on it straight away.
  - **In Progress**: Claude starts in auto mode on it straight away.

  The chips under the name pick the repo, model and effort. They start as
  your last card's.
- **Swimlanes.** Lanes are rows across the columns, named whatever you like:
  Add swimlane under the board, or ⇧⌘N. Drag a card into another lane's
  cell, or use Move to Lane in its menu. A lane's ⋯ renames it, moves it up
  or down, or deletes it, which moves its cards to the lane above. With one
  lane its name is hidden and the board looks as it always has. VIBES MODE
  shows every card in one set of columns.
- **A card can wait on another.** Wait On in a card's context menu picks
  the card it waits on (or `reeve card edit --wait-on`). While that card
  hasn't merged, a waiting card in Backlog can't start: a drag to Planning or
  In Progress, Plan it and Start building, and `reeve card move` are all
  refused, saying which card it waits on and how far off that one is
  ("Testing", "Release, PR not merged"). Its face says the same in amber.
  Merged means its pull request merged, its branch found on main, or archived.
  Closing the card it waits on lets it go, and a link that would make a loop
  is refused. VIBES MODE never starts a backlog card, waiting or not; one
  already started that waits on another is held (below).
- **Activity is live.** Each card's `claude` starts with hooks layered on
  through `--settings`, which leaves your own settings alone. The hooks post
  to a small server Reeve runs on 127.0.0.1. A prompt or a tool call turns
  the card sky blue (running). A permission prompt, `AskUserQuestion` or
  `ExitPlanMode` turns it amber (waiting on you). The end of a turn turns it
  green (ready for review), even when Claude's last message asks you
  something: only a dialog Claude Code is showing turns a card amber.
- **The column follows the session.** The hooks carry Claude Code's
  permission mode, so a card moves as the session does:
  - plan mode → **Planning**
  - working in any other mode (auto, default, accept edits) → **In Progress**
  - a turn that ends with changed code (an edit, uncommitted changes, or
    commits since the worktree was made) → **Testing**
  - an open, draft or merged pull request for the card's branch (see the
    badge below) → **Release**

  A pull request wins over everything else. A card only moves forward on its
  own: one in Testing stays there while Claude works on it again, and going
  back into plan mode or closing a pull request leaves a card where it got
  to. Moving it back is yours to do (drag it, or Move to… in its menu), and
  it moves on from there. Switching modes with ⇧⇥ fires no hook, so the card
  moves on the next prompt or tool call.
- **The title and summary come from Claude.** When a turn ends, Reeve digests
  the session's transcript and asks `claude -p --model haiku` for structured
  output: a title, a one-line summary, and any question Claude left you. This
  uses your existing Claude login, with no tools, no session saved and no
  settings loaded.
- **Ask Reeve from the header.** The field at the top of the board (⌘K)
  takes a request in plain words: "add a card to fix the login bug", "what's
  in testing?", "move the icon card to release", "tell the PRs card to rebase".
  Claude carries it out with `reeve` (below) and answers under the header.
  It runs `claude -p` on your Claude login in the repo new cards start in,
  with Bash as its only tool and `reeve` the only command it may run. It can
  close a card you name, but not one that would lose work (see `close`
  below), and `--force` is refused. No session is saved, and none of your
  settings, hooks or MCP servers are loaded.
- **You can still drag.** A card you drag is pinned in its new column until
  your next prompt, so the board never undoes your move behind your back.
- **Cards start in a repo.** Reeve keeps a list of the folders you work in,
  so a new card picks one rather than browsing for it. Add and remove them in
  Settings (⌘,), or with Add Repo… in the new card field, which starts in the
  repo you used last. For now a repo is just its folder.
- **Each card gets its own worktree.** A card started in a git repo works in
  a fresh worktree at `.claude/worktrees/reeve-<id>`, on a new branch
  `reeve/<id>` from the repo folder's HEAD, so cards on one repo never collide.
  Reeve adds the folder to the repo's `.git/info/exclude`. Closing the card
  deletes the worktree, uncommitted changes and all (it asks first if there
  are any). The branch is deleted too unless it has commits, which stay in
  the repo. A folder outside git is used as it is.
- **A card shows its pull request.** Once a pull request is opened from a
  card's branch, the card wears its number as a badge: green when open, grey
  as a draft, violet once merged, red if closed. A card keeps every pull
  request opened from any branch its worktree has been on, and the badge
  shows `+N` for the ones from other branches. Reeve asks your own `gh`
  at launch, when a turn ends and when you open the card. Without `gh` or a
  GitHub remote there is simply no badge.
- **Merge from the card.** A Release card whose open pull request GitHub
  says merges cleanly wears a Merge button. Press it, then Confirm within
  three seconds, and Reeve asks GitHub once more and squash-merges it with
  your `gh`. A draft, a conflict or branch protection leaves it unmerged:
  what gh said shows under the card. `reeve card merge` does the same.
- **Clean up merged cards into the Archive.** The archive button in the
  Release column's header archives every card whose pull requests have merged
  (the one on its current branch is merged and none it opened is still open
  or a draft). It asks first, ends each card's session, deletes its worktree
  and moves the card to the Archive, opened from the button in the header. A
  card whose worktree has uncommitted changes stays on the board. The Archive
  lists each card with a link to its pull request, and you can remove entries
  from it.
- **Each open card has five tabs.** Terminal is the session. Plan shows the
  plan Claude wrote in plan mode, read from its file so later edits show,
  with a dot on the tab when a new one arrives. While Claude Code's plan
  dialog is open, **Approve** answers it for you: Reeve reads the dialog off
  the terminal and picks "Yes, and use auto mode", and the tab marks the
  plan Approved, as it does however the plan was approved. When the dialog
  has no auto mode option (a model without it, or with bypass permissions
  on), it takes the first yes that keeps the context and doesn't bypass
  permissions. Changes is everything the card has done in its worktree since
  it started: commits, uncommitted edits and new files, read again as Claude
  works, with a tree of the changed files beside it: click one to jump to it
  (opening it if it was too long to start open), or hide the tree from the
  bar above. Preview is the app the card is building, under review in
  [Gloss](https://github.com/ryanbrunner/gloss) (below). PRs lists every
  pull request the card has opened, newest first, each with its state, its
  checks (passing, running or failing) and its review; it asks GitHub again
  when it shows, and every 30 seconds while a check is running. ⌥⌘1–5
  switch between them.
- **Review the changes like a pull request.** Hover a line in Changes and
  click + to comment on it. **Comment now** sends it straight away; **Add to
  review** keeps it as pending until you **Submit review**. Reeve writes the
  comments to a file in its data folder (`reviews/<card>.json`) and types a
  prompt into the session asking Claude to address each one and write its
  reply there. A sleeping session is resumed with that prompt. The replies
  show under your comments as threads you can answer or resolve. A comment
  whose line has since changed moves under its file's header, marked
  Outdated. Claude may read and write those files without asking, through a
  permission rule in the `--settings` Reeve passes. Sending waits while
  Claude is asking you something, and while it is in plan mode.
- **Review the plan the same way.** Hover a heading, paragraph or list item
  in Plan and click + in the margin to comment on it, then send it now or
  as part of a review. The comments go to `reviews/<card>-plan.json`, and
  Claude revises the plan to address them and replies in that file. While
  the plan dialog is open, **Submit review** answers it with "Tell Claude
  what to change" instead of approving. As with approving, Reeve checks the
  selection on screen before it types anything. Plan mode refuses every edit
  except the plan's, whatever the settings allow, so Reeve's `PreToolUse`
  hook answers `allow` for edits to its own review files. A comment on a
  part Claude has since rewritten moves to the top, under "On an earlier
  draft".
- **Gloss runs in the Preview tab.** Each card's `claude` gets `GLOSS_HOST`,
  so a `gloss open <url>` in the card (or the Gloss plugin's `/gloss <url>`)
  shows the page in the card's Preview tab, with Gloss's feedback bar across
  the top, instead of opening a Chromium window. You can also type the URL
  in the tab yourself. Reeve runs `gloss __session --host` in the card's
  folder: Gloss keeps the round and the API that `gloss wait`, `working`
  and `ready` use, and Reeve is the browser, carrying the bar in a WebKit
  content world of its own that the page's scripts can't reach. Comments,
  pins (with their pictures), Submit and Approve all work as in Gloss's
  window. "End review" or `gloss close` ends the session and leaves the page.
  It needs a Gloss with `--host`; without `gloss` on your PATH the tab is a
  plain preview. `REEVE_GLOSS` points Reeve at another `gloss`, such as a
  checkout's `bin/gloss.js`.
- **Sessions survive restarts.** A card owns its session id (`--session-id`
  the first time, `--resume` after that). After a restart it sleeps until you
  open it.
- **Pick a model and effort per card.** The new card field passes them as
  `--model` and `--effort`, including on every resume, so a card keeps them
  across restarts. "Default" passes neither, which leaves your own settings
  in charge. The field remembers your last choice.

## VIBES MODE

VIBES MODE takes you out of the loop. Flip the switch in the header (⇧⌘V)
for the whole board, or put one card in it: from its context menu, the
or the switch in its open header. It is off until you turn it on.

For a card in VIBES MODE, Reeve does what you would otherwise have to:

- **Questions answer themselves.** `AskUserQuestion` goes back to Claude
  through its hook, refused, with an instruction to make the call itself and
  say what it chose. A question Claude leaves in its last message gets the
  same answer, typed in.
- **Plans are approved unread.** Interactive Claude Code puts a plan to a
  person whatever a hook says, so Reeve presses Enter on the dialog's first
  option, a yes. With a model that has auto mode, that is auto mode.
- **Turns are pushed on.** When a turn ends and the card has been sorted,
  Reeve types the next step into its terminal: build it while nothing has
  changed, test it once there are changes, then commit, push, open a pull
  request and (with Merge to Main on) merge it.
- **Shipped means landed.** After the ship step, Reeve asks git and GitHub,
  not Claude: the card is done when its commits are on the repo's
  checked-out branch or its pull request merged (or, with Merge to Main off,
  when its pull request is up). Otherwise it is told to ship again. A card
  pushed from the same column three times running is left for you.
- **Waiting still means waiting.** A started card waiting on another that
  hasn't merged isn't pushed on when its turn ends, and its chip names the
  card it waits on. Once that card merges, it is picked up. A waiting card in
  Backlog still waits for you to start it.

With the board's switch on, two more things happen that a card in VIBES MODE
on its own never does:

- **Backlog runs on arrival.** Every card in Backlog is started, in the
  column VIBES MODE starts in, including one you name there while the switch
  is on. One waiting on a card that hasn't merged is held until it does. A
  card git can't make a worktree for is left for you.
- **It thinks of what's next.** When the last card in a repo ships, and
  nothing in it is left short of Release, Reeve asks `claude -p` in that repo
  what should follow, with nothing but tools that read. Up to three ideas
  land in Backlog, in that card's lane, and start like any other. Each card
  is asked once: a repo whose ideas came to nothing waits until something
  else in it ships. The scoreboard counts them as "Ideas of its own".

Flipping the board's switch arms it for two seconds before anything is
typed, so flipping it back in that time undoes it. Claude Code's own tool
permissions stay yours: a permission prompt still waits for a person. Reeve never types into the card you have open, since you
may have something half-typed there; it pushes it once you go back to the
board or on to another card. It only drives live sessions. After a relaunch a card sleeps until you
open it, as any card does, and VIBES MODE picks it up from its next turn.

The Vibes menu sets what it skips and whether it merges: Planning skipped,
Testing run and every pull request merged, out of the box. A skipped column
is taped off on the board, and a new card skips planning by starting
straight in auto mode. Every number on the scoreboard is counted from when
the switch was flipped and kept with the board.

Under Reduce Motion the colours stay and the movement stops, except that a
card still moves to its new column, quickly. The lights also hold still while
a card is open, so the terminal stays quick.

## Build

Needs Xcode (26 or newer) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
script/build            # → build/Build/Products/Debug/Reeve.app
open build/Build/Products/Debug/Reeve.app
```

To work in Xcode, run `xcodegen generate` and open `Reeve.xcodeproj`. Trust
the SwiftTerm plugin when Xcode asks. Pure logic and its tests live in
`ReeveKit` (`cd ReeveKit && swift test`).

The app icon is the Reeve mark on an ink plate, drawn by `script/icon` into
`App/Resources/Assets.xcassets`. Run it again after changing the mark.

SwiftTerm is pinned to 1.11.2. Releases from 1.12 on need Xcode's Metal
toolchain, and 1.99 doesn't compile with the current Swift.

## Release

Reeve can't be sandboxed (each card runs a shell and `claude`), so it can't
go through the App Store or TestFlight. Instead it's signed with Developer ID
and notarized by Apple, using the account Xcode is signed in to:

```sh
script/release          # archive, sign and send to Apple to notarize
script/release fetch    # once Apple is done → build/release/Reeve.zip
```

`fetch` fails while Apple is still processing; run it again a little later.

## Keys

| | |
|---|---|
| ⌘N | New card, named in the top lane's Backlog |
| ⇧⌘N | New swimlane |
| ⌘K | Ask Reeve: the command bar above the board |
| ⌘, | Settings: the repos new cards start in |
| ⌘W | Close card (asks first if its session is live) |
| ⌘1…⌘9 | Open card 1–9, in board order |
| ⇧⌘] / ⇧⌘[ | Next / previous card |
| ⌘↩ | In a card's terminal: a new line in the prompt, rather than sending it |
| ⌘B | Back to the board (the session keeps running) |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 / ⌥⌘4 / ⌥⌘5 | The open card's Terminal / Plan / Changes / Preview / PRs |
| ⇧⌘V | VIBES MODE for the whole board |

Esc goes to Claude Code, where it interrupts a turn, so it doesn't close an
open card. Use ⌘B, the × in the card's header or a click outside it.

Right-click a card, or use the ⋯ in an open card's header, to move it, have
it wait on another card, rename it, re-sort it now, put it in VIBES MODE,
restart its session or reveal its folder.

## Command line

`reeve` drives the board from a shell, with the same commands as reeve-board's
`reeve` where this app does the same thing. It is built into
`Reeve.app/Contents/Helpers`, and every card's terminal has it first on its
PATH, so Claude in a card can use it too. To use it from your own shell:

```sh
script/install-cli      # links it into ~/.local/bin (or pass a folder)
```

reeve-board's CLI is also called `reeve`; whichever comes first on your PATH
wins (a card's terminal always gets this one).

```
reeve board [--stage S] [--lane L] [--repo PATH]  every card, column by column
reeve card show|plan|diff|worktree|pr [<card>]
reeve card add [<title…>] [--prompt TEXT] [--mode plan|build|backlog] [--lane L] [--cwd DIR] [--model M] [--effort E]
reeve card edit <card> [--title TITLE | --no-title] [--vibes | --no-vibes] [--wait-on CARD | --no-wait-on]
reeve card move <card> [<stage>] [--lane L] [--in-folder]
reeve card run <card> [--restart]
reeve card reply <card> <text…> [--file PATH|-] [--force]
reeve card wait [<card>] [--timeout SECONDS]
reeve card merge <card>
reeve card close <card> [--force]
reeve vibes [on | off]                      the board's VIBES MODE switch
reeve open [<card>] · status · models · doctor
```

- **Naming a card.** A card is named by its id, or its first characters as
  in its branch (`reeve/<id>`), or its title. Left out, it is the card whose
  terminal or worktree you're in.
- **`--json`.** Prints the API's answer and nothing else.
- **`reply`.** Types into the card's terminal when its session is running,
  or starts the session with the message. It refuses while Claude Code shows
  a dialog, unless you pass `--force`.
- **Backlog cards.** `card add --mode backlog` makes one, with `--prompt`
  kept until it starts. `move` to planning or in-progress starts it; `run`
  and `reply` refuse it until then. `card edit --wait-on <card>` has it wait
  on another card: `move` refuses to start it (exit 1, naming that card)
  until that one merges. `card show` says what it depends on.
- **`merge`.** Merges a Release card's pull request on GitHub, squashed, as
  the card's Merge button does, once GitHub says it merges cleanly. Branch
  protection still applies: when gh refuses, it says why. Merging a change
  under `.github/workflows/` needs gh's token to have the `workflow` scope,
  which `reeve doctor` checks (`gh auth refresh -h github.com -s workflow`).
- **`close`.** Deletes the worktree, as ⌘W does. It refuses uncommitted
  changes, unmerged commits or an open pull request unless you pass `--force`.

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | ok |
| 1 | error |
| 2 | bad command line |

`card wait` has its own codes. It keeps waiting while a card waits on its
background work:

| Code | Meaning |
|---|---|
| 0 | ready for review |
| 3 | waiting on you |
| 4 | failed |
| 5 | nothing running |
| 6 | timed out |

A prompt that hasn't reached Claude after 30 seconds puts the card in
"needs input". That happens when something in the terminal is holding it
up, such as trusting a new folder.

**How it reaches the app.** It talks to the app over 127.0.0.1. The app writes
its port and a fresh token to `server.json` in the data folder. Only you can
read that file, and every request must carry the token. Requests from web
pages are refused.

## Data

The board, and the list of repos, are saved to `~/Library/Application Support/Reeve Terminal/board.json`.
Set `REEVE_DATA_DIR` to put it somewhere else. `reeve` reads it too, to find
the same app.

A Reeve on another `REEVE_DATA_DIR` also keeps its preferences (the repo,
model and effort the new card field remembers) apart from yours, in
`com.ryanbrunner.reeve-terminal.other-data`, so a smoke test never changes
where your next card starts.

## Smoke test

This runs the whole loop with nobody at the keyboard. It makes a card, lets
Claude take a turn, waits for the card to be sorted, saves screenshots and the
cards as JSON, then quits:

```sh
REEVE_DATA_DIR=/tmp/reeve-smoke/data REEVE_SMOKE_DIR=/tmp/reeve-smoke/work \
REEVE_SMOKE_OUT=/tmp/reeve-smoke/out REEVE_SMOKE_PROMPT="Plan adding hello.txt; ask before doing it." \
  build/Build/Products/Debug/Reeve.app/Contents/MacOS/Reeve
```

Add `REEVE_SMOKE_VIBES=1` to put the card in VIBES MODE and leave it alone
until it ships (`REEVE_SMOKE_VIBES=board` flips the whole board's switch
instead). `REEVE_SMOKE_START=plan` starts it planning, and
`REEVE_SMOKE_MODEL`/`REEVE_SMOKE_EFFORT` pick its model and effort.
`REEVE_SMOKE_APPROVE=1` (with `REEVE_SMOKE_START=plan`) presses the Plan
tab's Approve once the plan dialog is up and logs the mode it lands in.

`REEVE_SMOKE_MODE=repos` checks repos, backlog cards and swimlanes without
Claude taking a turn: it adds `REEVE_SMOKE_DIR` as a repo, names a card in
Backlog and checks nothing starts, moves it to a new lane and deletes the
lane, has it wait on a second card and checks a loop is refused and a move
to Planning is refused, closes that card, moves it to Planning and checks it starts there in a worktree, closes
it, and opens Settings to take the repo off and put it back, with a
picture of each window and a line per check in `timeline.txt`. Run it twice
on one `REEVE_DATA_DIR` to see the list kept.

`REEVE_SMOKE_MODE=commandbar` asks the command bar to add a card in
`REEVE_SMOKE_DIR` (or `REEVE_SMOKE_PROMPT`), then how the board stands, then
for something it may not do, and checks the card started in that repo and
nothing was closed. Claude takes real turns.

`REEVE_SMOKE_MODE=preview` checks the Preview tab instead, without Claude
taking a turn. It makes a card with no prompt, then does what the card's
Claude and a reviewer would: `gloss open`, a round from the bar (one comment
pinned), `gloss wait`, `working`, `ready` and `close`. It saves the verdict,
the timeline and a picture of each step. Run any dev server for it to show,
such as Gloss's own (`npm run dev -- --port 4400` in a Gloss checkout):

```sh
REEVE_DATA_DIR=/tmp/reeve-smoke/data REEVE_SMOKE_DIR=/tmp/reeve-smoke/work \
REEVE_SMOKE_OUT=/tmp/reeve-smoke/out REEVE_SMOKE_MODE=preview \
REEVE_SMOKE_URL=http://127.0.0.1:4400/ GLOSS_HOME=/tmp/reeve-smoke/gloss \
  build/Build/Products/Debug/Reeve.app/Contents/MacOS/Reeve
```
