import AppKit
import ReeveKit
import SwiftUI

/// Where a new card is being named: a swimlane, and a column it can start in.
struct NewCardSpot: Equatable {
    var lane: UUID
    var stage: Stage

    /// The columns a card can be made in, and what each does with it.
    static let stages: [Stage] = [.backlog, .design, .planning, .inProgress]

    var hint: String {
        switch stage {
        case .design: "Claude designs it first, with /design"
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
    @State private var showingOptions = false

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
            Text(repo?.name ?? "Add a repo…").font(.geist(11))
        }
        .modifier(MenuChip(muted: repo == nil))
        .help(repo?.path ?? "The repo the card works in")
    }

    private var optionsMenu: some View {
        Button { showingOptions.toggle() } label: {
            Text([model, effort].filter { !$0.isEmpty }.map(Self.name).joined(separator: " · ").nilIfEmpty ?? "Default model")
        }
        .buttonStyle(.plain)
        .modifier(MenuChip(muted: model.isEmpty && effort.isEmpty))
        .help("The model and effort the card's claude runs with")
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                StopSlider(title: "Model", stops: [""] + Launch.models.reversed(), selection: $model, label: Self.name, tint: { _ in Theme.sky400 })
                StopSlider(title: "Effort", stops: [""] + Launch.efforts, selection: $effort, label: Self.name, tint: Self.effortTint)
            }
            .padding(12)
            .frame(width: 240)
            .background(Theme.ink)
        }
    }

    /// The same heat ramp the web card's effort slider uses: cool at Low,
    /// hottest at Max.
    static func effortTint(_ effort: String) -> Color {
        switch effort {
        case "low": Color(hex: 0x38BDF8)
        case "medium": Color(hex: 0x2DD4BF)
        case "high": Color(hex: 0xFACC15)
        case "xhigh": Color(hex: 0xFB923C)
        case "max": Color(hex: 0xF87171)
        default: Theme.muted
        }
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
        choice.isEmpty ? "Default" : choice == "xhigh" ? "Extra high" : choice.capitalized
    }
}

/// A small menu under the new card's name.
struct MenuChip: ViewModifier {
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

/// A slider over a few named stops, the first of which ("" — the person's own
/// default) means nothing is pinned. Click or drag anywhere on the track.
struct StopSlider: View {
    let title: String
    let stops: [String]
    @Binding var selection: String
    let label: (String) -> String
    let tint: (String) -> Color

    private var index: Int { stops.firstIndex(of: selection) ?? 0 }

    var body: some View {
        let tone = tint(stops[index])
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).foregroundStyle(Theme.muted)
                Spacer()
                Text(label(stops[index])).foregroundStyle(index == 0 ? Theme.muted : tone)
            }
            .font(.geist(11))
            GeometryReader { geo in
                let last = CGFloat(max(stops.count - 1, 1))
                let x = geo.size.width * CGFloat(index) / last
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 4)
                    Capsule().fill(tone).frame(width: x, height: 4)
                    ForEach(stops.indices, id: \.self) { i in
                        Circle()
                            .fill(i <= index ? Color.clear : Color.white.opacity(0.18))
                            .frame(width: 6, height: 6)
                            .position(x: geo.size.width * CGFloat(i) / last, y: geo.size.height / 2)
                    }
                    Circle()
                        .fill(tone)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.3)))
                        .frame(width: 12, height: 12)
                        .position(x: x, y: geo.size.height / 2)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let fraction = min(1, max(0, value.location.x / max(geo.size.width, 1)))
                    selection = stops[Int((fraction * last).rounded())]
                })
            }
            .frame(height: 16)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue(label(stops[index]))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: selection = stops[min(index + 1, stops.count - 1)]
                case .decrement: selection = stops[max(index - 1, 0)]
                @unknown default: break
                }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
