import AppKit
import SwiftUI

/// A new card: a folder to work in, and optionally a name and a first prompt.
/// Nothing else, since everything else happens in the terminal.
struct NewCardSheet: View {
    @EnvironmentObject var board: Board
    @Environment(\.dismiss) private var dismiss
    @State private var folder: String = RecentFolders.all.first ?? ""
    @State private var title = ""
    @State private var prompt = ""

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

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    let first = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    board.create(cwd: folder, title: title, prompt: first.isEmpty ? nil : first)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(folder.isEmpty)
                .opacity(folder.isEmpty ? 0.4 : 1)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.panel)
        .onAppear { if folder.isEmpty { choose() } }
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
