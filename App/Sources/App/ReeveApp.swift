import AppKit
import ReeveKit
import SwiftUI

@main
struct ReeveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Reeve", id: "board") {
            ContentView()
                .environmentObject(delegate.board)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)
        .commands { BoardCommands(board: delegate.board) }

        Settings {
            ReposSettings()
                .environmentObject(delegate.board)
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Made on first use rather than at init: the fonts have to be registered
    // before anything measures text, and that happens in didFinishLaunching.
    lazy var board = Board()

    func applicationWillFinishLaunching(_ notification: Notification) {
        Theme.registerFonts()
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Smoke.runIfAsked(board: board)
    }

    func applicationWillTerminate(_ notification: Notification) {
        board.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A card waiting on its shells is still working: quitting stops them too.
        let running = board.cards.filter { board.live.contains($0.id) && ($0.activity == .running || $0.activity == .waiting) }
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running.count == 1 ? "Claude is still working on a card" : "Claude is still working on \(running.count) cards"
        alert.informativeText = "Quitting stops them mid-turn. Each card picks its conversation up again next time."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Keys for the board, where a tabbed terminal would put them.
struct BoardCommands: Commands {
    @ObservedObject var board: Board

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Card…") { board.showingNewCard = true }
                .keyboardShortcut("n")
            Button("Ask Reeve…") {
                if board.selected != nil { board.dismissOpenCard() }
                board.commandBar.focus()
            }
            .keyboardShortcut("k")
        }
        // ⌘W closes a card, as it closes a tab; the window's own close button still closes the window.
        CommandGroup(replacing: .saveItem) {
            Button("Close Card") {
                if let card = board.selected { CloseCard.confirm(card: card, board: board) }
            }
            .keyboardShortcut("w")
            .disabled(board.selected == nil)
        }
        CommandMenu("Card") {
            Button("Next Card") { board.selectOffset(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Card") { board.selectOffset(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10) { n in
                Button("Card \(n)") { board.selectIndex(n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))))
            }
            Divider()
            if let card = board.selected {
                ForEach(Array(CardTab.allCases.enumerated()), id: \.element) { index, tab in
                    Button("Show \(tab.label)") { board.show(tab, for: card.id) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                }
                Divider()
                Menu("Move to") {
                    ForEach(Stage.allCases) { stage in
                        Button(stage.label) { board.move(card.id, to: stage) }
                            .disabled(stage == card.stage)
                    }
                }
                Button("Rename…") { Rename.ask(card: card, board: board) }
                Button("Sort Now") { board.classifyNow(card.id) }
                    .disabled(card.transcriptPath == nil)
                Button(board.live.contains(card.id) ? "Restart Session" : "Resume Session") { board.restart(card.id) }
            }
        }
        CommandMenu("Vibes") {
            Toggle("Vibes Mode", isOn: Binding(get: { board.vibes != nil }, set: { _ in board.toggleVibes() }))
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Toggle("Skip Planning", isOn: $board.vibesOptions.skipPlanning)
            Toggle("Skip Testing", isOn: $board.vibesOptions.skipTesting)
            Toggle("Merge to Main", isOn: $board.vibesOptions.autoMerge)
        }
        CommandGroup(after: .toolbar) {
            Button("Back to Board") { board.dismissOpenCard() }
                .keyboardShortcut("b")
                .disabled(board.selected == nil)
        }
    }
}
