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
- **The column comes from Claude.** When a turn ends, Reeve digests the
  session's transcript and asks `claude -p --model haiku` for structured
  output: which column the work is in, a title, a one-line summary, and any
  question Claude left you. This uses your existing Claude login, with no
  tools, no session saved and no settings loaded.
- **You can still drag.** A card you drag is pinned in its new column until
  your next prompt, so the classifier never undoes your move behind your back.
- **Each card gets its own worktree.** A card started in a git repo works in
  a fresh worktree at `.claude/worktrees/reeve-<id>`, on a new branch
  `reeve/<id>` from the folder's HEAD, so cards on one repo never collide.
  Reeve adds the folder to the repo's `.git/info/exclude`. Closing the card
  deletes the worktree, uncommitted changes and all (it asks first if there
  are any). The branch is deleted too unless it has commits, which stay in
  the repo. A folder outside git is used as it is.
- **Sessions survive restarts.** A card owns its session id (`--session-id`
  the first time, `--resume` after that). After a restart it sleeps until you
  open it.
- **Pick a model and effort per card.** The new card sheet passes them as
  `--model` and `--effort`, including on every resume, so a card keeps them
  across restarts. "Default" passes neither, which leaves your own settings
  in charge. The sheet remembers your last choice.

## VIBES MODE

VIBES MODE takes you out of the loop. Flip the switch in the header (⇧⌘V)
for the whole board, or put one card in it: from its context menu, the
switch in its open header, or the new card sheet. It is off until you turn
it on.

For a card in VIBES MODE, Reeve does what you would otherwise have to:

- **Questions answer themselves.** `AskUserQuestion` goes back to Claude
  through its hook, refused, with an instruction to make the call itself and
  say what it chose. A question Claude leaves in its last message gets the
  same answer, typed in.
- **Plans are approved unread.** Interactive Claude Code puts a plan to a
  person whatever a hook says, so Reeve presses Enter on the dialog's first
  option, a yes. With a model that has auto mode, that is auto mode.
- **Turns are pushed on.** When a turn ends and the card has been sorted,
  Reeve types the next step into its terminal: implement, test, then commit,
  push, open a pull request and (with Merge to Main on) merge it. A card told
  to ship whose turn ends in Release is done, and nothing pushes it after
  that. A card pushed from the same column three times running is left for
  you.

Claude Code's own tool permissions stay yours: a permission prompt still
waits for a person. Reeve never types into the card you have open, since you
may have something half-typed there; it pushes it once you go back to the
board. It only drives live sessions. After a relaunch a card sleeps until you
open it, as any card does, and VIBES MODE picks it up from its next turn.

The Vibes menu sets what it skips and whether it merges: Planning skipped,
Testing run and every pull request merged, out of the box. A skipped column
is taped off on the board, and a new card skips planning by starting
straight in auto mode. Every number on the scoreboard is counted from when
the switch was flipped and kept with the board.

Under Reduce Motion the colours stay and the movement stops. The lights also
hold still while a card is open, so the terminal stays quick.

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
| ⇧⌘V | VIBES MODE for the whole board |

Esc goes to Claude Code, where it interrupts a turn, so it doesn't close an
open card. Use ⌘B, the × in the card's header or a click outside it.

Right-click a card, or use the ⋯ in an open card's header, to move it, rename
it, re-sort it now, put it in VIBES MODE, restart its session or reveal its
folder.

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

Add `REEVE_SMOKE_VIBES=1` to put the card in VIBES MODE and leave it alone
until it ships (`REEVE_SMOKE_VIBES=board` flips the whole board's switch
instead). `REEVE_SMOKE_START=plan` starts it planning, and
`REEVE_SMOKE_MODEL`/`REEVE_SMOKE_EFFORT` pick its model and effort.
