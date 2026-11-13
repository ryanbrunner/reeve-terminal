# Reeve (terminal)

A native macOS kanban board of Claude Code sessions. Each card is a terminal
running the real `claude`, in a folder. The board fills the window; click a
card and its terminal opens over the board. Close it and you're back on the
board, with the session still running.

    backlog → planning → in_progress → testing → release

Reeve doesn't talk to Claude itself, so the terminal is Claude Code at full
feature parity. What Reeve adds is the board.

- **Activity is live.** Each card's `claude` starts with hooks layered on
  through `--settings`, which leaves your own settings alone. The hooks post
  to a small server Reeve runs on 127.0.0.1. A prompt or a tool call turns
  the card sky blue (running). A permission prompt, `AskUserQuestion` or
  `ExitPlanMode` turns it amber (waiting on you). The end of a turn turns it
  green (ready for review).
- **The column follows the session.** The hooks carry Claude Code's
  permission mode, so a card moves as the session does:
  - plan mode → **Planning**
  - working in any other mode (auto, default, accept edits) → **In Progress**
  - a turn that ends with changed code (an edit, uncommitted changes, or
    commits since the worktree was made) → **Testing**
  - an open, draft or merged pull request for the card's branch (see the
    badge below) → **Release**

  A pull request wins over everything else. Switching modes with ⇧⇥ fires no
  hook, so the card moves on the next prompt or tool call.
- **The title and summary come from Claude.** When a turn ends, Reeve digests
  the session's transcript and asks `claude -p --model haiku` for structured
  output: a title, a one-line summary, and any question Claude left you. This
  uses your existing Claude login, with no tools, no session saved and no
  settings loaded.
- **You can still drag.** A card you drag is pinned in its new column until
  your next prompt, so the board never undoes your move behind your back.
- **Each card gets its own worktree.** A card started in a git repo works in
  a fresh worktree at `.claude/worktrees/reeve-<id>`, on a new branch
  `reeve/<id>` from the folder's HEAD, so cards on one repo never collide.
  Reeve adds the folder to the repo's `.git/info/exclude`. Closing the card
  deletes the worktree, uncommitted changes and all (it asks first if there
  are any). The branch is deleted too unless it has commits, which stay in
  the repo. A folder outside git is used as it is.
- **A card shows its pull request.** Once a pull request is opened from a
  card's branch, the card wears its number as a badge: green when open, grey
  as a draft, violet once merged, red if closed. Reeve asks your own `gh`
  at launch, when a turn ends and when you open the card. Without `gh` or a
  GitHub remote there is simply no badge.
- **Each open card has four tabs.** Terminal is the session. Plan shows
  the plan Claude wrote in plan mode, read from its file so later edits show,
  with a dot on the tab when a new one arrives. Changes is everything the card
  has done in its worktree since it started: commits, uncommitted edits and
  new files, read again as Claude works. Preview is the app the card is
  building, under review in [Gloss](https://github.com/ryanbrunner/gloss)
  (below). ⌥⌘1–4 switch between them.
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
- **Pick a model and effort per card.** The new card sheet passes them as
  `--model` and `--effort`, including on every resume, so a card keeps them
  across restarts. "Default" passes neither, which leaves your own settings
  in charge. The sheet remembers your last choice.

## Build

Needs Xcode (26 or newer) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
script/build            # → build/Build/Products/Debug/Reeve.app
open build/Build/Products/Debug/Reeve.app
```

To work in Xcode, run `xcodegen generate` and open `Reeve.xcodeproj`. Trust
the SwiftTerm plugin when Xcode asks. Pure logic and its tests live in
`ReeveKit` (`cd ReeveKit && swift test`).

SwiftTerm is pinned to 1.11.2. Releases from 1.12 on need Xcode's Metal
toolchain, and 1.99 doesn't compile with the current Swift.

## Keys

| | |
|---|---|
| ⌘N | New card |
| ⌘W | Close card (asks first if its session is live) |
| ⌘1…⌘9 | Open card 1–9, in board order |
| ⇧⌘] / ⇧⌘[ | Next / previous card |
| ⌘B | Back to the board (the session keeps running) |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 / ⌥⌘4 | The open card's Terminal / Plan / Changes / Preview |

Esc goes to Claude Code, where it interrupts a turn, so it doesn't close an
open card. Use ⌘B, the × in the card's header or a click outside it.

Right-click a card, or use the ⋯ in an open card's header, to move it, rename
it, re-sort it now, restart its session or reveal its folder.

## Data

The board is saved to `~/Library/Application Support/Reeve Terminal/board.json`.
Set `REEVE_DATA_DIR` to put it somewhere else.

## Smoke test

This runs the whole loop with nobody at the keyboard. It makes a card, lets
Claude take a turn, waits for the card to be sorted, saves screenshots and the
cards as JSON, then quits:

```sh
REEVE_DATA_DIR=/tmp/reeve-smoke/data REEVE_SMOKE_DIR=/tmp/reeve-smoke/work \
REEVE_SMOKE_OUT=/tmp/reeve-smoke/out REEVE_SMOKE_PROMPT="Plan adding hello.txt; ask before doing it." \
  build/Build/Products/Debug/Reeve.app/Contents/MacOS/Reeve
```

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
