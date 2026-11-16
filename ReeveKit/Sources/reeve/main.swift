import Foundation
import ReeveKit

/// `reeve`: Reeve Terminal's board from a shell. Every command but `models`
/// and `doctor` asks the running app, which holds the board.

let usage = CLIUsage.text

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
