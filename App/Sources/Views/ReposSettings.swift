import AppKit
import ReeveKit
import SwiftUI

/// Settings (⌘,): the repos a new card can start in.
struct ReposSettings: View {
    @EnvironmentObject var board: Board

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Repos")
            if board.repos.isEmpty {
                Text("No repos yet. Add the folders you start cards in, and the new card sheet offers them.")
                    .font(.geist(12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(board.repos) { repo in
                        if repo.id != board.repos.first?.id { Divider().overlay(Theme.edge) }
                        RepoRow(repo: repo) { board.removeRepo(repo.id) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.edge))
            }
            HStack {
                Spacer()
                Button("Add Repo…") {
                    if let path = RepoPicker.choose() { board.addRepo(path: path) }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.panel)
    }
}

private struct RepoRow: View {
    let repo: Repo
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.name).font(.geist(13, .medium)).foregroundStyle(Theme.text)
                    if !FileManager.default.fileExists(atPath: repo.path) {
                        Chip(text: "missing", color: Theme.muted)
                    }
                }
                Text(repo.path)
                    .font(.mono(11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .help("Remove \(repo.name). Its cards keep working.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// The folder panel, for adding a repo.
enum RepoPicker {
    static func choose(from start: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "A folder Claude works in"
        if let start { panel.directoryURL = URL(fileURLWithPath: start) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
