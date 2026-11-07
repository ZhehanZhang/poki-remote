import Foundation

public struct CoreConfig: Sendable {
    public var relayURL: URL
    public var runnerURL: URL
    public var sensitive: SensitivityRules
    /// How long `do` holds for an approval before answering approval_required.
    public var approvalWait: Double
    /// The hard cap for one tool call, everything included.
    public var toolDeadline: Double
    /// The device time one `do` may spend on its actions.
    public var actionCap: Double
    /// The cap for one screen read (tree and screenshot together).
    public var readTimeout: Double
    /// How long a second tool call waits for the first before answering busy.
    public var busyWait: Double
    /// How long a call waits for a runner that is starting (the app wakes it when a call comes in).
    public var runnerWait: Double
    /// The form the element tree is asked for: "xml" (the default) or "json". WDA's JSON tree fetches
    /// each element's custom actions from the accessibility server, one round trip per element,
    /// whatever is excluded; its XML tree leaves them out unless asked. On the CI simulator the XML
    /// read of Settings took 0.2 to 0.4 s against 0.6 to 0.7 s, and 0.3 s against 2.0 s with the
    /// keyboard up.
    public var treeFormat: String
    /// WDA's `accessibilityDeadline`: how long the app's main loop may take to answer before a tree
    /// read is refused (0 turns the check off). 2 s on the phone; the gym compares both.
    public var accessibilityDeadline: Double
    /// Poki's own bundle id: a tap that lands on its Live Activity (the Dynamic Island) brings it to the
    /// front; `do` brings the app it was working in back and says so, rather than act inside Poki.
    public var ownBundleID: String

    public init(relayURL: URL = URL(string: "wss://pokimcp.zheha.nz/v1")!, runnerURL: URL = URL(string: "http://127.0.0.1:8100")!, sensitive: SensitivityRules = SensitivityRules(), approvalWait: Double = 20, toolDeadline: Double = 25, actionCap: Double = 6, readTimeout: Double = 4, busyWait: Double = 2, runnerWait: Double = 15, treeFormat: String = "xml", ownBundleID: String = "nz.zheha.poki", accessibilityDeadline: Double = 2) {
        self.accessibilityDeadline = accessibilityDeadline
        self.relayURL = relayURL
        self.runnerURL = runnerURL
        self.sensitive = sensitive
        self.approvalWait = approvalWait
        self.toolDeadline = toolDeadline
        self.actionCap = actionCap
        self.readTimeout = readTimeout
        self.busyWait = busyWait
        self.runnerWait = runnerWait
        self.treeFormat = treeFormat
        self.ownBundleID = ownBundleID
    }
}

/// The launcher's view of the runner, as the app shell reports it (from PokiLauncher's events).
public enum RunnerState: Sendable, Equatable {
    case running
    case starting(String)
    case failed(String, fix: String?)

    public var isRunning: Bool { self == .running }
    public var describe: String {
        switch self {
        case .running: return "running"
        case .starting(let detail): return "starting (\(detail))"
        case .failed(let detail, let fix): return "failed: \(detail)" + (fix.map { ". Fix on the phone: \($0)" } ?? "")
        }
    }
}

/// The relay's signing key: Ed25519, kept in the keychain on the phone.
public protocol RelayKey: Sendable {
    /// The raw 32-byte public key.
    var publicKey: Data { get }
    func sign(_ message: Data) throws -> Data
}

public protocol CoreHost: AnyObject, Sendable {
    func signingKey() throws -> RelayKey
    /// sha256 (hex) of each connector secret.
    func accessHashes() -> [String]
    /// A JPEG of the PNG screenshot, `width` pixels wide.
    func jpeg(fromPNG png: Data, width: Int, quality: Double) throws -> Data
    func runnerState() -> RunnerState
    func restartRunner()
    /// Text read from a PNG screenshot, used for elements an app collapsed. PokiCore answers it with
    /// Vision by default, so a host need not implement it.
    func recognizeText(inPNG png: Data) async -> [RecognizedText]?
    /// A screenshot (PNG, one pixel per screen point is not required) that does not go through the
    /// runner: the launcher's own path to the device (the DVT screenshot service over its tunnel, or
    /// simctl on the simulator). Asked for only when the runner gives none (wedged, or restarting),
    /// so a hung app never blinds the model. Nil (the default) means there is no such path.
    func screenshotWithoutRunner() async -> Data?
}

extension CoreHost {
    public func screenshotWithoutRunner() async -> Data? { nil }
}

public enum RelayState: Sendable, Equatable {
    case connecting
    case ready(url: String)
    case offline(String)
}

public struct ToolActivity: Sendable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var started: Date
}

public enum ToolOutcome: Sendable, Equatable {
    case done(String)
    case failed(String)
}

/// What the Live Activity shows after a call: the app in front and a small JPEG of the screen
/// (about 96 pixels wide, a few kB; store it in the app group, since ActivityKit's state is 4 kB).
public struct ToolFacts: Sendable, Equatable {
    public var app: String?
    public var thumbnail: Data?
}

public enum CoreEvent: Sendable, Equatable {
    case relay(RelayState)
    case toolStarted(ToolActivity)
    case toolFinished(ToolActivity, ToolOutcome, ToolFacts)
    case approvalRequested(Approval)
    case approvalEnded(id: String, approved: Bool?)
    /// The model handed a step to the owner (`{handoff: {kind, text}}`: a passcode, a password, a
    /// verification, a payment it will not make). `kind` is one of passcode, password, verification,
    /// payment, other (the app adds runnerPasscode itself). The Live Activity shows it with a Done
    /// button; no input is sent until `handoffDone(id:)` (Done) or the model takes it back
    /// (`{handoff: false}`), while every look is served and the model keeps polling.
    case handoffRequested(id: String, kind: String, text: String?, app: String?)
    /// `how` is "done" (the owner tapped Done) or "takenBack" (the model sent `{handoff: false}`).
    case handoffEnded(id: String, how: String)
}

/// A step handed to the owner by the model, shown in the Live Activity until the owner taps Done
/// or the model takes it back.
public struct Handoff: Sendable, Equatable {
    public var id: String
    public var kind: String
    public var text: String
    public var requested: Date
    public var done: Date?
    public init(id: String, kind: String, text: String, requested: Date, done: Date? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.requested = requested
        self.done = done
    }
}

public struct RelayRequest: Sendable {
    public var id: String
    public var method: String
    public var headers: [String: String]
    public var body: String
    public init(id: String, method: String, headers: [String: String], body: String) {
        self.id = id
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct RelayResponse: Sendable, Equatable {
    public var id: String
    public var status: Int
    public var headers: [String: String]
    public var body: String
}

/// Poki on the phone: the MCP server behind the relay.
public final class PokiCore: @unchecked Sendable {
    public let config: CoreConfig
    weak var host: CoreHost?
    let runner: Runner
    let computer: Computer
    let approvals: Approvals
    private let continuation: AsyncStream<CoreEvent>.Continuation
    public let events: AsyncStream<CoreEvent>
    private let gate = Gate()
    private let sessions = LockedBox<Set<String>>([])
    var relay: RelayClient?

    public init(config: CoreConfig, host: CoreHost, transport: HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.host = host
        var c: AsyncStream<CoreEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        continuation = c
        runner = Runner(url: config.runnerURL, transport: transport)
        runner.accessibilityDeadline = config.accessibilityDeadline
        runner.screenshotFallback = { [weak host] in await host?.screenshotWithoutRunner() }
        let emit: @Sendable (CoreEvent) -> Void = { [c] event in c!.yield(event) }
        approvals = Approvals(emit: emit)
        computer = Computer(runner: runner, host: host, config: config, approvals: approvals, emit: emit)
        // Two silent runner requests in a row: the runner is gone or stuck, so the launcher starts it again.
        runner.onUnhealthy = { [weak host, runner] in
            runner.forgetRunner()
            host?.restartRunner()
        }
    }

    func emit(_ event: CoreEvent) { continuation.yield(event) }

    public func start(socketFactory: WebSocketFactory = URLSessionWebSocketFactory()) {
        guard relay == nil, let host else { return }
        let client = RelayClient(baseURL: config.relayURL, host: host, factory: socketFactory, handler: { [weak self] request in
            await self?.handle(request) ?? RelayResponse(id: request.id, status: 503, headers: [:], body: "")
        }, emit: { [weak self] in self?.emit(.relay($0)) })
        client.undelivered = { [weak self] request, response in self?.keepLost(request, response) }
        relay = client
        client.start()
    }

    public func stop() {
        relay?.stop()
        relay = nil
    }

    /// Answers whose connection dropped before they could be sent; the next call carries them.
    let lost = LockedBox<[String]>([])
    func keepLost(_ request: RelayRequest, _ response: RelayResponse) {
        guard let body = try? JSON.parse(response.body), let text = body["result"]?["content"]?[0]?["text"]?.string else { return }
        let name = (try? JSON.parse(request.body))?["params"]?["name"]?.string ?? "call"
        let stamp = clock.string(from: Date())
        lost.update { $0 = Array(($0 + ["the \(name) call whose connection dropped (finished at \(stamp)): " + text]).suffix(3)) }
    }
    private let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    /// The connector secrets changed: tell the relay the new list.
    public func accessChanged() { relay?.sendAccess() }

    public func resolveApproval(id: String, approved: Bool) { approvals.resolve(id: id, approved: approved) }

    /// The owner tapped Done on a step the model handed to them (the Live Activity).
    public func handoffDone(id: String) { computer.handoffDone(id: id) }
    /// The step the model handed to the owner that is still waiting, if any.
    public var handoff: Handoff? { computer.handoff.value.flatMap { $0.done == nil ? $0 : nil } }

    public var pendingApproval: Approval? { approvals.pending }

    // MARK: MCP over HTTP (Streamable HTTP, JSON answers only)

    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public func handle(_ request: RelayRequest) async -> RelayResponse {
        func answer(_ status: Int, _ body: JSON?, session: String? = nil) -> RelayResponse {
            var headers = ["content-type": "application/json"]
            if let session { headers["mcp-session-id"] = session }
            return RelayResponse(id: request.id, status: status, headers: headers, body: body?.serialized() ?? "")
        }
        switch request.method {
        case "GET": return RelayResponse(id: request.id, status: 405, headers: ["allow": "POST, DELETE"], body: "")
        case "DELETE":
            if let s = request.headers["mcp-session-id"] { _ = sessions.update { $0.remove(s) } }
            return RelayResponse(id: request.id, status: 200, headers: [:], body: "")
        case "POST": break
        default: return RelayResponse(id: request.id, status: 405, headers: ["allow": "POST, DELETE"], body: "")
        }
        guard let message = try? JSON.parse(request.body) else {
            return answer(400, rpcError(nil, -32700, "Parse error"))
        }
        let session = request.headers["mcp-session-id"]
        if let batch = message.array {
            var replies: [JSON] = []
            for item in batch { if let r = await rpc(item, session: session).reply { replies.append(r) } }
            return replies.isEmpty ? RelayResponse(id: request.id, status: 202, headers: [:], body: "") : answer(200, .array(replies), session: session)
        }
        let (reply, newSession) = await rpc(message, session: session)
        guard let reply else { return RelayResponse(id: request.id, status: 202, headers: [:], body: "") }
        return answer(200, reply, session: newSession ?? session)
    }

    func rpcError(_ id: JSON?, _ code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    func rpc(_ message: JSON, session: String?) async -> (reply: JSON?, session: String?) {
        let id = message["id"]
        guard let method = message["method"]?.string else { return (id == nil ? nil : rpcError(id, -32600, "Invalid Request"), nil) }
        let isNotification = id == nil
        func result(_ value: JSON) -> JSON { ["jsonrpc": "2.0", "id": id ?? .null, "result": value] }
        switch method {
        case "initialize":
            let asked = message["params"]?["protocolVersion"]?.string ?? Self.protocolVersions[0]
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            let newSession = UUID().uuidString.lowercased()
            sessions.update { _ = $0.insert(newSession) }
            return (result([
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "poki", "version": "1.0"],
                "instructions": .string(Self.instructions),
            ]), newSession)
        case "notifications/initialized", "notifications/cancelled": return (nil, nil)
        case "ping": return (isNotification ? nil : result(.object([:])), nil)
        case "tools/list": return (result(["tools": .array(Self.tools)]), nil)
        case "tools/call":
            let name = message["params"]?["name"]?.string ?? ""
            let args = message["params"]?["arguments"] ?? .object([:])
            let output = await call(name, args)
            var content: [JSON] = [["type": "text", "text": .string(output.text)]]
            if let jpeg = output.jpeg { content.append(["type": "image", "data": .string(jpeg.base64EncodedString()), "mimeType": "image/jpeg"]) }
            return (result(["content": .array(content), "isError": .bool(output.isError)]), nil)
        default:
            if isNotification { return (nil, nil) }
            return (rpcError(id, -32601, "Method not found: \(method)"), nil)
        }
    }

    // MARK: Tools

    static let instructions = "look reads the iPhone's screen; do runs actions and then reads it. Both return the app in front, numbered elements and a screenshot whose pixels are screen points. Use the numbers from the latest answer; an element that stays on screen keeps its number, and do lists only what changed. Decide what happened from the elements, the screen_changed line and the picture. To reach something further down a list, use scroll_to with its text before trying swipes. Some actions (payments, deleting, sending messages, passwords) need the owner's approval on the phone; do says so instead of sending them. When the tree is late the elements come from the picture and a tap on a point of the picture always works: there is always a way on. A step that is the owner's to do (a password, a verification, a checkout you will not make) is handed to them with {handoff: {kind, text}}; keep polling look while they do it, then go on."

    static let tools: [JSON] = [
        ["name": "look", "description": "Read the screen now: the app in front, the numbered elements (role, \"label = value\", [x,y,w,h] in screen points; + marks elements new since the last read, ~ moved ones) and a screenshot that is one pixel per screen point, so a point on the picture is a point to tap. Repeated text, scroll bars and empty containers are left out and long labels are cut; full=true lists every element as the tree has it and adds the text read from the picture inside [collapsed] elements (an app showed a whole cell, buttons and all, as one element). Numbers stay the same while an element stays on screen.",
         "inputSchema": ["type": "object", "properties": ["full": ["type": "boolean"]], "additionalProperties": false],
         "annotations": ["readOnlyHint": true]],
        ["name": "do", "description": "Run actions in order, then read the screen once. The answer says what each action did, screen_changed (true or false: whether the elements or the picture differ from the read before), and only the elements that are new (+) or moved (~); the others keep their numbers (full=true lists all). Actions: {tap: n} or {tap: [x, y]} (a numbered element is tapped at its centre, or at the nearest free point when the tree puts something over its centre, and the answer says so; only an element with no part on the screen is refused as not_hittable); {type: \"text\", ref?: n, clear?: true, via?: \"paste\"} (taps n first, then types the text as key presses and says what the field holds afterwards; via paste is the backup when typing comes out wrong: it pastes through the field's menu and puts the owner's clipboard back); {key: \"return\"|\"delete\"|\"tab\"|\"space\"|\"escape\"}; {scroll_to: \"text\"} or {scroll_to: {text or ref, in?: n, direction?: \"down\", max_swipes?: 12}} (the best way to bring something into view: it scrolls until the text is fully on screen and says where, up to 12 s; when it stops short it says so and a second call goes on from there); {swipe: \"up\"|\"down\"|\"left\"|\"right\"} or {swipe: {direction, in?: n, distance?: \"short\"|\"long\"}} (a quick flick inside the biggest list on screen, or inside n, clear of bars; direction is where the finger moves, so up shows what is further down); {drag: {from: n or [x, y], to: n or [x, y], ms?: 400, hold_ms?: 0}} or {drag: [x1, y1, x2, y2]} (the content follows the finger and stops where it stops; hold_ms first to pick something up); {long_press: n or [x, y] or {ref, ms?}}; {pinch: {ref or x, y, scale}}; {button: \"home\"|\"lock\"|\"volume_up\"|\"volume_down\"}; {launch: \"bundle id\"} or {launch: {bundle, fresh: true}}; {wait_until: \"text\"} or {wait_until: {text, gone?: true, ms?: 3000}} or {wait_until: {settled: true, ms?}} (reads the screen until the text appears or goes, or the screen holds still; use it instead of fixed waits); {wait: ms}; {back: true} (the top-left back button if one is listed, else an edge swipe from the left); {handoff: {kind: \"passcode\"|\"password\"|\"verification\"|\"payment\"|\"other\", text: \"what the owner must do\"}} (when a step is the owner's to do, by your own judgement: it is shown on the phone with a Done button, no input is sent until they tap Done or you send {handoff: false}, and you keep polling with look or {wait_until: {handoff_done: true, ms?: 10000}} rather than ending your work). Points are screen points, like the frames and the screenshot's pixels. A locked phone takes nothing but buttons and says screen: locked. Each action is reported as sent, not_sent or unknown; it stops at the first action that fails and never re-sends one that may have been delivered. Payments, deleting, sending messages and passwords need the owner's approval on the phone: the plain actions before the first such action are sent, the rest are not, and the answer says approval_required and which actions to send again, on their own, after they approve. A runner still finishing an earlier request answers not_sent and busy; call look again then.",
         "inputSchema": ["type": "object", "properties": ["actions": ["type": "array", "items": ["type": "object"], "minItems": 0, "maxItems": 20], "full": ["type": "boolean"]], "required": ["actions"], "additionalProperties": false]],
        ["name": "status", "description": "Poki's state without touching the phone: the runner, the relay, and any approval waiting on the phone.",
         "inputSchema": ["type": "object", "properties": .object([:]), "additionalProperties": false],
         "annotations": ["readOnlyHint": true]],
    ]

    func call(_ name: String, _ args: JSON) async -> ToolResult {
        if name == "status" { return status() }
        guard name == "look" || name == "do" else { return ToolResult(text: "unknown tool \(name); the tools are look, do and status", jpeg: nil, isError: true) }
        let activity = ToolActivity(id: UUID().uuidString, name: name, summary: name == "do" ? computer.labels(args["actions"]?.array ?? []) : "Look at the screen", started: Date())
        // One tool call at a time per phone; a second waits briefly, then says what the first is doing.
        guard await gate.enter(waiting: config.busyWait) else {
            // The screenshot is served apart from the runner's queue, so a busy answer still shows
            // the screen (the owner's rule: every answer carries the picture while the runner is up).
            return await computer.withPicture("busy: another call is still running (\(gate.current ?? "a tool")); nothing was sent. Call again in a moment.", timeout: 3, remember: false, isErrorWithoutPicture: false)
        }
        gate.current = "\(name): \(activity.summary)"
        emit(.toolStarted(activity))
        // The owner's time on an approval comes on top of the tool's own time.
        // The owner's time on an approval, and the runner's start, come on top of the tool's own time.
        let deadline = config.toolDeadline + (name == "do" ? config.approvalWait : 0) + config.runnerWait + 1
        var output: ToolResult
        do {
            output = try await withDeadline(deadline, name) { [computer] in
                name == "look" ? await computer.look(full: args["full"]?.bool ?? false) : await computer.act(actions: args["actions"]?.array ?? [], full: args["full"]?.bool ?? false)
            }
        } catch {
            // Never reached in practice (every step has its own deadline), but a call always answers.
            output = ToolResult(text: "error: \(error); what was sent is unknown. Call look to see the screen.", jpeg: nil, isError: true)
        }
        gate.current = nil
        gate.leave()
        let earlier = lost.update { l -> [String] in defer { l = [] }; return l }
        if !earlier.isEmpty {
            output.text = "earlier, never delivered to you: " + earlier.joined(separator: "\n\n") + "\n\nnow:\n" + output.text
        }
        let line = output.text.split(separator: "\n").first.map(String.init) ?? ""
        let thumbnail = computer.lastPNG.flatMap { try? host?.jpeg(fromPNG: $0, width: 96, quality: 0.5) }
        emit(.toolFinished(activity, output.isError ? .failed(line) : .done(line), ToolFacts(app: computer.lastForeground?.describe, thumbnail: thumbnail)))
        return output
    }

    func status() -> ToolResult {
        var lines = ["runner: \(host?.runnerState().describe ?? "unknown")"]
        if let relay { lines.append("relay: \(relay.stateDescription)") }
        if let p = approvals.pending { lines.append("approval waiting on the phone: \(p.summary) (\(p.reason), id \(p.id))") }
        if let line = computer.handoffLine(clear: false) { lines.append(line) }
        if let current = gate.current { lines.append("running: \(current)") }
        return ToolResult(text: lines.joined(separator: "\n"), jpeg: nil)
    }
}

/// One holder at a time, with a bounded wait to get in.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var _current: String?
    var current: String? {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); _current = newValue; lock.unlock() }
    }
    func tryEnter() -> Bool { lock.lock(); defer { lock.unlock() }; if held { return false }; held = true; return true }
    func enter(waiting seconds: Double) async -> Bool {
        let until = now() + seconds
        while true {
            if tryEnter() { return true }
            if now() >= until { return false }
            await sleep(seconds: 0.05)
        }
    }
    func leave() { lock.lock(); held = false; lock.unlock() }
}
