import AppKit
import ReeveKit
import SwiftUI

/// Where a new card is being named: a swimlane, and a column it can start in.
struct NewCardSpot: Equatable {
    var lane: UUID
    var stage: Stage

    /// The columns a card can be made in, and what each does with it.
    static let stages: [Stage] = [.backlog, .planning, .inProgress]

    var hint: String {
        switch stage {
        case .planning: "Claude plans it first"
        case .inProgress: "Claude starts on it right away"
        default: "Waits here until you move it"
        }
    }
}

/// A new card, named where it goes. The name is its title and what Claude is
/// first told. Return makes it and leaves the field open for the next one;
/// Esc, or Return with nothing typed, puts the field away. The repo, model
/// and effort are the last card's unless changed here.
struct NewCardField: View {
    @EnvironmentObject var board: Board
    let spot: NewCardSpot
    @State private var name = ""
    @FocusState private var focused: Bool
    /// The last card's choices, so a run of cards starts the same way. Empty
    /// means the person's own default.
    @AppStorage("newCardModel", store: Preferences.store) private var model = ""
    @AppStorage("newCardEffort", store: Preferences.store) private var effort = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $name, prompt: Text("Name it").foregroundStyle(Theme.muted.opacity(0.6)), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.geist(13, .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand { board.composing = nil }
            Text(spot.hint)
                .font(.geist(11))
                .foregroundStyle(Theme.muted)
            HStack(spacing: 6) {
                repoMenu
                optionsMenu
                Spacer(minLength: 0)
                Button {
                    board.composing = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
                .help("Cancel (Esc)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.sky600))
        .onAppear {
            focused = true
            if board.availableRepos.isEmpty { addRepo() }
        }
    }

    private var repo: Repo? { board.pickedRepo }

    private var repoMenu: some View {
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
            Text(repo?.name ?? "Add a repo…")
        }
        .modifier(MenuChip(muted: repo == nil))
        .help(repo?.path ?? "The repo the card works in")
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Model", selection: $model) {
                Text("Default").tag("")
                ForEach(Launch.models, id: \.self) { Text(Self.name($0)).tag($0) }
            }
            Picker("Effort", selection: $effort) {
                Text("Default").tag("")
                ForEach(Launch.efforts, id: \.self) { Text(Self.name($0)).tag($0) }
            }
        } label: {
            Text([model, effort].filter { !$0.isEmpty }.map(Self.name).joined(separator: " · ").nilIfEmpty ?? "Default model")
        }
        .modifier(MenuChip(muted: model.isEmpty && effort.isEmpty))
        .help("The model and effort the card's claude runs with")
    }

    private func submit() {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            board.composing = nil
            return
        }
        guard let repo else {
            addRepo()
            return
        }
        board.pickedRepoId = repo.id
        board.create(name: typed, in: spot, cwd: repo.path, model: model.isEmpty ? nil : model, effort: effort.isEmpty ? nil : effort)
        name = ""
        focused = true
    }

    private func addRepo() {
        if let path = RepoPicker.choose(from: repo?.path) {
            board.pickedRepoId = board.addRepo(path: path).id
        }
    }

    static func name(_ choice: String) -> String {
        choice == "xhigh" ? "Extra high" : choice.capitalized
    }
}

/// A small menu under the new card's name.
private struct MenuChip: ViewModifier {
    let muted: Bool

    func body(content: Content) -> some View {
        content
            .font(.geist(11))
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(muted ? Theme.muted : Theme.textSoft)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.edge))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
