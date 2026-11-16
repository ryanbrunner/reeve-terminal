import AppKit
import ReeveKit
import SwiftUI

/// A new card: a repo to work in, and whether to plan first or start right
/// away. The model, effort, a name and a first prompt are there if you want
/// them; everything else happens in the terminal.
struct NewCardSheet: View {
    @EnvironmentObject var board: Board
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var showingDetails = false
    /// The last card's choices, so a run of cards starts the same way. Empty
    /// means the person's own default.
    @AppStorage("newCardModel", store: Preferences.store) private var model = ""
    @AppStorage("newCardEffort", store: Preferences.store) private var effort = ""
    @State private var vibes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New card").font(.geist(16, .semibold)).foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Repo")
                Menu {
                    ForEach(board.availableRepos) { repo in
                        Button { board.pickedRepoId = repo.id } label: {
                            Text(repo.name)
                            Text(repo.path)
                        }
                    }
                    if !board.availableRepos.isEmpty { Divider() }
                    Button("Add Repo…", action: addRepo)
                } label: {
                    // A menu's label is drawn as plain text, so the path goes below.
                    Text(repo?.name ?? "Add a repo…")
                        .font(.geist(13))
                        .foregroundStyle(repo == nil ? Theme.muted : Theme.text)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.edge))
                if let repo {
                    Text(repo.path)
                        .font(.mono(11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            HStack(spacing: 12) {
                OptionMenu(label: "Model", choices: Launch.models, selection: $model)
                OptionMenu(label: "Effort", choices: Launch.efforts, selection: $effort)
            }

            HStack(spacing: 12) {
                VibesSwitch(on: vibes || board.vibes != nil, help: board.vibes != nil ? "The whole board is in VIBES MODE" : nil) { vibes.toggle() }
                    .disabled(board.vibes != nil)
                Text(board.vibes != nil
                     ? "The board is in VIBES MODE, so this card is too."
                     : vibes ? "Claude approves its own plan, answers its own questions and ships this card without you."
                     : "Off: Claude waits for you, as usual.")
                    .font(.geist(12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
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
                .disabled(repo == nil)
                .opacity(repo == nil ? 0.4 : 1)
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
        .onAppear { if board.availableRepos.isEmpty { addRepo() } }
    }

    private var repo: Repo? { board.pickedRepo }

    private func start(_ mode: StartMode) {
        guard let repo else { return }
        board.pickedRepoId = repo.id
        let first = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        board.create(
            cwd: repo.path,
            title: title,
            prompt: first.isEmpty ? nil : first,
            mode: mode,
            model: model.isEmpty ? nil : model,
            effort: effort.isEmpty ? nil : effort,
            vibes: vibes
        )
        dismiss()
    }

    private func addRepo() {
        if let path = RepoPicker.choose(from: repo?.path) {
            board.pickedRepoId = board.addRepo(path: path).id
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

/// A labelled menu of `claude` options, led by "Default", which passes nothing
/// and leaves the choice to the person's own settings.
private struct OptionMenu: View {
    let label: String
    let choices: [String]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
            Menu {
                Button("Default") { selection = "" }
                Divider()
                ForEach(choices, id: \.self) { choice in
                    Button(name(choice)) { selection = choice }
                }
            } label: {
                Text(selection.isEmpty ? "Default" : name(selection))
                    .font(.geist(13))
                    .foregroundStyle(selection.isEmpty ? Theme.muted : Theme.text)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.edge))
        }
    }

    private func name(_ choice: String) -> String {
        choice == "xhigh" ? "Extra high" : choice.capitalized
    }
}
