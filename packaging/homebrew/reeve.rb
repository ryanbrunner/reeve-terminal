# The cask for ryanbrunner/homebrew-tap. `script/release publish` fills in
# version and sha256 for each release and pushes the result to the tap.
# Change it here: the tap's copy is overwritten.
cask "reeve" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/ryanbrunner/reeve-terminal/releases/download/v#{version}/Reeve.zip"
  name "Reeve"
  desc "Kanban board of Claude Code sessions, each card a terminal"
  homepage "https://github.com/ryanbrunner/reeve-terminal"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Reeve.app"
  binary "#{appdir}/Reeve.app/Contents/Helpers/reeve"

  zap trash: [
    "~/Library/Application Support/Reeve Terminal",
    "~/Library/Preferences/com.ryanbrunner.reeve-terminal.plist",
    "~/Library/Saved Application State/com.ryanbrunner.reeve-terminal.savedState",
  ]

  # Not dependencies: Claude Code and gh are often installed some other way,
  # and a second copy from Homebrew would shadow the one already set up.
  caveats <<~EOS
    Each card runs Claude Code, which Reeve finds on your login shell's PATH.
    Install it and log in once before opening a card:
      https://claude.com/claude-code

    Optional:
      gh     pull request badges on cards (brew install gh; gh auth login)
      gloss  the Preview tab (brew install ryanbrunner/tap/gloss)
  EOS
end
