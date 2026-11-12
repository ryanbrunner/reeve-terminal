import AppKit
import ReeveKit
import SwiftUI

/// A new card: a folder to work in, and whether to plan first or start right
/// away. A name and a first prompt are there if you want them; everything
/// else happens in the terminal.
struct NewCardSheet: View {
    @EnvironmentObject var board: Board
    @Environment(\.dismiss) private var dismiss
    @State private var folder: String = RecentFolders.all.first ?? ""
    @State private var title = ""
    @State private var prompt = ""
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New card").font(.geist(16, .semibold)).foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Folder")
                HStack(spacing: 8) {
                    Menu {
                        ForEach(RecentFolders.all, id: \.self) { path in
                            Button(path) { folder = path }
                        }
                        if !RecentFolders.all.isEmpty { Divider() }
                        Button("Choose…", action: choose)
                    } label: {
                        Text(folder.isEmpty ? "Choose a folder…" : folder)
                            .font(.mono(12))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.edge))
                    Button("Choose…", action: choose).buttonStyle(SecondaryButtonStyle(height: 32))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "How to start")
                HStack(spacing: 10) {
                    StartChoice(
                        title: "Plan",
                        detail: "Claude starts in plan mode and works out an approach with you first.",
                        shortcut: "⇧⌘↩"
                    ) { start(.plan) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    StartChoice(
                        title: "Start right away",
                        detail: "Claude starts in auto mode and the card goes straight to In Progress.",
                        shortcut: "⌘↩"
                    ) { start(.build) }
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .disabled(folder.isEmpty)
                .opacity(folder.isEmpty ? 0.4 : 1)
            }

            Button {
                withAnimation(.easeOut(duration: 0.15)) { showingDetails.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showingDetails ? 90 : 0))
                    Text("Title and first prompt")
                        .font(.geist(12))
                }
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingDetails {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Title")
                    TextField("", text: $title, prompt: Text("Optional — Claude names it after the first turn").foregroundStyle(Theme.muted.opacity(0.6)))
                        .textFieldStyle(.plain)
                        .font(.geist(13))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.edge))
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "First prompt")
                    TextEditor(text: $prompt)
                        .font(.geist(13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 110)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.edge))
                    Text("Optional. Leave it empty to start talking in the terminal.")
                        .font(.geist(11))
                        .foregroundStyle(Theme.muted)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.panel)
        .onAppear { if folder.isEmpty { choose() } }
    }

    private func start(_ mode: StartMode) {
        let first = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        board.create(cwd: folder, title: title, prompt: first.isEmpty ? nil : first, mode: mode)
        dismiss()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The folder Claude works in"
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
        }
    }
}

/// One of the two ways to start a card, as a large button.
private struct StartChoice: View {
    let title: String
    let detail: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.geist(14, .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(shortcut).font(.mono(11)).foregroundStyle(Theme.muted)
                }
                Text(detail)
                    .font(.geist(12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(StartChoiceStyle(hovering: hovering))
        .onHover { hovering = $0 }
    }
}

private struct StartChoiceStyle: ButtonStyle {
    var hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? Theme.edge : Theme.ink))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovering ? Theme.sky600 : Theme.edge))
            .contentShape(Rectangle())
    }
}
