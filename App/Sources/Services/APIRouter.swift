import AppKit
import ReeveKit

/// `reeve`'s way in: `/api` requests, answered from the board. Cards are
/// named by their full id here; `reeve` works out which one a person meant.
@MainActor
enum APIRouter {
    private struct Failure: Error {
        let status: Int
        let error: APIError
    }

    static func handle(_ request: HTTPRequest, board: Board) async -> HTTPResponse {
        do {
            return try await route(request, board: board)
        } catch let failure as Failure {
            return .error(failure.status, failure.error)
        } catch let error as APIError {
            return .error(409, error)
        } catch {
            return .error(500, APIError("failed", detail: error.localizedDescription))
        }
    }

    private static func route(_ request: HTTPRequest, board: Board) async throws -> HTTPResponse {
        // /api/<resource>[/<id>[/<action>]]
        let parts = Array(request.path.split(separator: "/").map(String.init).dropFirst())
        guard parts.count <= 3 else {
            throw Failure(status: 404, error: APIError("not found", detail: "\(request.method) \(request.path)"))
        }
        func part(_ i: Int) -> String? { parts.indices.contains(i) ? parts[i] : nil }
        switch (request.method, part(0), part(1), part(2)) {
        case ("GET", "board"?, nil, nil):
            return .json(BoardResponse(cards: board.ordered.map(board.apiCard), lanes: board.lanes, selectedId: board.selectedId, vibes: board.vibes))

        case ("GET", "vibes"?, nil, nil):
            return .json(vibesState(board))

        case ("POST", "vibes"?, nil, nil):
            if try decode(VibesBody.self, request).on != (board.vibes != nil) { board.toggleVibes() }
            return .json(vibesState(board))

        case ("POST", "open"?, nil, nil):
            activate()
            return HTTPResponse(status: 204)

        case ("POST", "cards"?, nil, nil):
            let body = try decode(CreateCardBody.self, request)
            var isFolder: ObjCBool = false
            guard body.cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: body.cwd, isDirectory: &isFolder), isFolder.boolValue else {
                throw Failure(status: 400, error: APIError("no such folder", detail: body.cwd))
            }
            if let effort = body.effort, !Launch.efforts.contains(effort) {
                throw Failure(status: 400, error: APIError("unknown effort \(effort)", detail: "one of " + Launch.efforts.joined(separator: ", ")))
            }
            let lane = try body.lane.map { try findLane($0, board) }
            if body.open { activate() }
            let card: Card
            do {
                card = try await board.createCard(cwd: body.cwd, title: body.title, prompt: body.prompt, mode: body.backlog ? nil : body.mode,
                                                  model: body.model?.nilIfEmpty, effort: body.effort?.nilIfEmpty,
                                                  vibes: body.vibes, lane: lane?.id, open: body.open, inFolder: body.inFolder)
            } catch {
                throw Failure(status: 409, error: APIError("couldn't make a worktree for the card",
                                                           detail: error.localizedDescription + " (pass --in-folder to work in the folder itself)"))
            }
            return .json(board.apiCard(board.card(card.id) ?? card), status: 201)

        case let ("GET", "cards"?, id?, nil):
            return .json(board.apiCard(try card(id, board)))

        case let ("PATCH", "cards"?, id?, nil):
            let card = try card(id, board)
            let body = try decode(EditCardBody.self, request)
            if let title = body.title { board.rename(card.id, to: title) }
            if let vibes = body.vibes { board.setVibes(card.id, vibes) }
            return .json(board.apiCard(board.card(card.id) ?? card))

        case let ("DELETE", "cards"?, id?, nil):
            let card = try card(id, board)
            let force = ["1", "true", "yes"].contains(request.query["force"] ?? "")
            if !force, let losing = await board.closeWouldLose(card.id) {
                throw Failure(status: 409, error: APIError("not closed: \(losing.summary)",
                                                           detail: "closing deletes the worktree and its branch; pass --force to close it anyway"))
            }
            let closing = board.apiCard(board.card(card.id) ?? card)
            board.close(card.id)
            return .json(closing)

        case let ("GET", "cards"?, id?, "plan"?):
            let card = try card(id, board)
            let text = await board.loadPlan(card.id)
            return .json(PlanResponse(text: text, path: board.card(card.id)?.planPath))

        case let ("GET", "cards"?, id?, "diff"?):
            let card = try card(id, board)
            let found: Worktrees.Changes?
            do {
                found = try await Worktrees.changes(in: card.worktreePath ?? card.cwd, base: card.baseCommit, env: board.environment)
            } catch {
                throw Failure(status: 500, error: APIError("couldn't read the changes", detail: error.localizedDescription))
            }
            guard let changes = found else {
                throw Failure(status: 409, error: APIError("not a git repository", detail: card.cwd))
            }
            return .json(ChangesResponse(files: changes.files, base: changes.base,
                                         untrackedLeftOut: changes.untrackedLeftOut, truncated: changes.truncated))

        case let ("POST", "cards"?, id?, "move"?):
            let card = try card(id, board)
            let body = try decode(MoveBody.self, request)
            guard body.stage != nil || body.lane != nil else {
                throw Failure(status: 400, error: APIError("nowhere to move it", detail: "give a stage, a lane or both"))
            }
            let lane = try body.lane.map { try findLane($0, board) }
            board.move(card.id, to: body.stage, lane: lane?.id, launching: false)
            // Leaving the backlog starts it, here rather than in the app, so
            // a worktree git won't make is this request's error.
            if card.queued == true, let stage = body.stage, let mode = Card.launch(movingTo: stage) {
                do {
                    try await board.launch(card.id, mode: mode, inFolder: body.inFolder)
                } catch {
                    throw Failure(status: 409, error: APIError("couldn't make a worktree for the card",
                                                               detail: error.localizedDescription + " (pass --in-folder to work in the folder itself)"))
                }
            }
            return .json(board.apiCard(board.card(card.id) ?? card))

        case let ("POST", "cards"?, id?, "run"?):
            let card = try card(id, board)
            if card.queued == true { throw Board.queuedError }
            if try decode(RunBody.self, request).restart {
                board.restart(card.id)
            } else {
                board.startIfNeeded(card.id)
            }
            return .json(board.apiCard(board.card(card.id) ?? card))

        case let ("POST", "cards"?, id?, "reply"?):
            let card = try card(id, board)
            let body = try decode(ReplyBody.self, request)
            guard !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure(status: 400, error: APIError("nothing to send"))
            }
            let delivered = try board.reply(card.id, text: body.text, force: body.force)
            return .json(ReplyResponse(delivered: delivered, card: board.apiCard(board.card(card.id) ?? card)))

        case let ("POST", "cards"?, id?, "open"?):
            let card = try card(id, board)
            activate()
            board.select(card.id)
            return .json(board.apiCard(board.card(card.id) ?? card))

        case let ("POST", "cards"?, id?, "pull-request"?):
            let card = try card(id, board)
            await board.findPullRequest(card.id)
            return .json(board.apiCard(board.card(card.id) ?? card))

        case let ("POST", "cards"?, id?, "merge"?):
            let card = try card(id, board)
            // Looked up first: the board may not have seen this card's pull
            // request since Claude opened it.
            await board.findPullRequest(card.id)
            let state = try await board.mergePullRequest(card.id)
            return .json(MergeResponse(state: state, card: board.apiCard(board.card(card.id) ?? card)))

        default:
            throw Failure(status: 404, error: APIError("not found", detail: "\(request.method) \(request.path)"))
        }
    }

    private static func vibesState(_ board: Board) -> VibesResponse {
        VibesResponse(on: board.vibes != nil, arming: board.vibesArming, ledger: board.vibes, options: board.vibesOptions)
    }

    private static func card(_ id: String, _ board: Board) throws -> Card {
        guard let uuid = UUID(uuidString: id), let card = board.card(uuid) else {
            throw Failure(status: 404, error: APIError("no such card", detail: id))
        }
        return card
    }

    private static func findLane(_ ref: String, _ board: Board) throws -> Lane {
        guard let lane = board.lane(named: ref) else {
            throw Failure(status: 404, error: APIError("no such lane", detail: "\(ref); the lanes are " + board.lanes.map(\.name).joined(separator: ", ")))
        }
        return lane
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ request: HTTPRequest) throws -> T {
        do {
            return try API.decoder().decode(type, from: request.body.isEmpty ? Data("{}".utf8) : request.body)
        } catch {
            throw Failure(status: 400, error: APIError("bad request body", detail: String(describing: error)))
        }
    }

    private static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
