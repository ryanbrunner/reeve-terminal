import ReeveKit
import SwiftUI

/// The field in the header: ask Reeve for something in plain words. ⌘K puts
/// the cursor in it.
struct CommandBarField: View {
    @EnvironmentObject var board: Board
    @EnvironmentObject var bar: CommandBarRunner
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if bar.isRunning {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            } else {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(focused ? Theme.sky300 : Theme.muted)
                    .frame(width: 14)
            }
            TextField("", text: $text, prompt: Text("Ask Reeve — add a card, what's in testing?, move a card…").foregroundStyle(Theme.muted.opacity(0.7)))
                .textFieldStyle(.plain)
                .font(.geist(13))
                .focused($focused)
                .disabled(bar.isRunning)
                .onSubmit {
                    bar.run(text, board: board)
                    if bar.isRunning { text = "" }
                }
                .onExitCommand { focused = false }
            if !focused && text.isEmpty && !bar.isRunning {
                Text("⌘K").font(.mono(10)).foregroundStyle(Theme.muted.opacity(0.8))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ink.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.sky600 : Theme.edge))
        .frame(minWidth: 220, maxWidth: 520)
        .onChange(of: bar.focusTick) { focused = true }
    }
}

/// What came back, under the header until it's dismissed.
struct CommandBarAnswerView: View {
    @EnvironmentObject var bar: CommandBarRunner

    var body: some View {
        if let content {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(content.prompt)
                        .font(.geist(11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(content.body)
                        .font(.geist(13))
                        .foregroundStyle(content.failed ? Theme.amber100 : Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(content.refused, id: \.self) { command in
                        Text("Not allowed from here: \(command)")
                            .font(.mono(11))
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 0)
                if !bar.isRunning {
                    Button { bar.dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                    .help("Dismiss")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(content.failed ? Theme.amber100.opacity(0.35) : Theme.edge))
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .transition(.opacity)
        }
    }

    private var content: (prompt: String, body: String, refused: [String], failed: Bool)? {
        switch bar.state {
        case .idle: nil
        case .running(let prompt): (prompt, "Working on it…", [], false)
        case .answered(let prompt, let reply, let refused): (prompt, reply, refused, false)
        case .failed(let prompt, let message): (prompt, message, [], true)
        }
    }
}
