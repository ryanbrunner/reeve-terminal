import Foundation
import ReeveKit

/// `reeve`: Reeve Terminal's board from a shell. Every command but `models`
/// and `doctor` asks the running app, which holds the board.

let usage = """
reeve — Reeve Terminal's board from a shell

Reading
  reeve board [--stage S] [--repo PATH]       every card, column by column
  reeve card show [<card>]                    a card: where it is, what it's doing, its plan
  reeve card plan [<card>]                    the card's plan, as Markdown
  reeve card diff [<card>] [--stat]           what the card has changed since it started
  reeve card worktree [<card>]                the card's worktree path
  reeve card pr [<card>]                      the URL of the card's pull request
  reeve status                                is the app running? (exit 0 or 1)
  reeve models                                models and efforts a card can start with
  reeve doctor                                check git, claude and gh

Driving
  reeve card add [<title…>] [--prompt TEXT] [--mode plan|build] [--cwd DIR] …
  reeve card edit <card> [--title TITLE | --no-title] [--vibes | --no-vibes]
  reeve card move <card> <stage>
  reeve card run <card> [--restart]
  reeve card reply <card> <text…> [--file PATH|-]
  reeve card wait [<card>] [--timeout SECONDS]
  reeve card close <card> [--force]
  reeve open [<card>]
  reeve vibes [on | off]                      the board's VIBES MODE switch

<card> is a card's id or its first characters (as in its branch, reeve/<id>),
or its title. Left out, it is the card whose terminal or worktree you're in.
Stages: \(StageName.accepted).
--json prints the API's answer and nothing else. `reeve card <command> --help`
says more.

Exit codes: 0 ok, 1 error, 2 bad command line. `card wait`: 0 ready for
review, 3 waiting on you, 4 failed, 5 nothing running, 6 timed out.
"""

func run(_ argv: [String]) async -> ExitCode {
    guard let first = argv.first, !["help", "--help", "-h"].contains(first) else {
        out(usage)
        return .ok
    }
    let verb: Verb
    var rest: [String]
    if first == "card" {
        guard argv.count > 1, !["help", "--help", "-h"].contains(argv[1]) else {
            out("reeve card <command>\n\n" + cardVerbs.map { "  " + $0.usage.split(separator: "\n")[0] }.joined(separator: "\n"))
            return .ok
        }
        guard let found = cardVerbs.first(where: { $0.name == argv[1] }) else {
            note("reeve: unknown command “card \(argv[1])”\n\n" + usage)
            return .usage
        }
        verb = found
        rest = Array(argv.dropFirst(2))
    } else {
        guard let found = topVerbs.first(where: { $0.name == first }) else {
            note("reeve: unknown command “\(first)”\n\n" + usage)
            return .usage
        }
        verb = found
        rest = Array(argv.dropFirst())
    }
    if rest.contains("--help") || rest.contains("-h") {
        out(verb.usage)
        return .ok
    }
    do {
        let args = try Arguments(rest, valued: verb.valued, flags: verb.flags, short: verb.short)
        return try await verb.run(args)
    } catch let error as UsageError {
        note("reeve: \(error.message)\n\n" + verb.usage)
        return .usage
    } catch let error as CLIError {
        note("reeve: \(error.message)")
        return error.code
    } catch {
        note("reeve: \(error.localizedDescription)")
        return .error
    }
}

exit(await run(Array(CommandLine.arguments.dropFirst())).rawValue)
