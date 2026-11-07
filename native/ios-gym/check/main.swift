// Poki Gym scorecard: drives PokiCore's look/do (its MCP handler, as the agent calls it) against a real
// WebDriverAgent on the iOS Simulator, through every Poki Gym scenario and a few faults, and scores
// each against the owner's rules: every call answers in time with a picture, the tree is read under
// animation, an action moves the screen, a busy or dead runner never hangs the agent.
// Built in CI as an executable target of the PokiCore package (the gym workflow copies this file in).
import Foundation
#if os(macOS)
import PokiCore
import ImageIO
import UniformTypeIdentifiers

setvbuf(stdout, nil, _IOLBF, 0)

final class Host: CoreHost, @unchecked Sendable {
    struct NoKey: Error {}
    func signingKey() throws -> RelayKey { throw NoKey() }
    func accessHashes() -> [String] { [] }
    func jpeg(fromPNG png: Data, width: Int, quality: Double) throws -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: width * 3] as CFDictionary) else { throw NoKey() }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw NoKey() }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return out as Data
    }
    func runnerState() -> RunnerState { .running }
    /// The simulator's own screenshot, as the launcher's DVT screenshot on a phone: a path to a
    /// picture that a wedged app cannot block.
    func screenshotWithoutRunner() async -> Data? {
        let path = NSTemporaryDirectory() + "poki-gym-\(UUID().uuidString).png"
        sh(["xcrun", "simctl", "io", udid, "screenshot", path])
        defer { try? FileManager.default.removeItem(atPath: path) }
        return FileManager.default.contents(atPath: path)
    }
    /// As the app's launcher: PokiCore asks once the runner stops answering; the start script brings
    /// WebDriverAgent back (POKI_WDA_START), at most once every 20 s.
    private let lock = NSLock()
    private var lastRestart = Date.distantPast
    func restartRunner() {
        guard let script = ProcessInfo.processInfo.environment["POKI_WDA_START"] else { return }
        let due = lock.withLock { () -> Bool in
            guard Date().timeIntervalSince(lastRestart) > 20 else { return false }
            lastRestart = Date(); return true
        }
        guard due else { return }
        print("host: restarting the runner with \(script)")
        DispatchQueue.global().async { print(sh(["bash", script])) }
    }
}

let env = ProcessInfo.processInfo.environment
let url = URL(string: env["POKI_WDA_URL"] ?? "http://127.0.0.1:8100")!
let udid = env["UDID"] ?? "booted"
let gymBundle = "nz.zheha.poki.gym"
let core = PokiCore(config: CoreConfig(runnerURL: url), host: Host())
var session: String?

struct Row { var scenario: String; var step: String; var ms: Int; var ok: Bool; var note: String }
var rows: [Row] = []
var failures: [String] = []
var scenario = "setup"

/// Runs a shell command and returns its output (simctl, the WDA restart script).
@discardableResult func sh(_ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

@MainActor func rpc(_ method: String, _ params: JSON) async -> JSON? {
    let body: JSON = ["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params]
    let reply = await core.handle(RelayRequest(id: "1", method: "POST", headers: session.map { ["mcp-session-id": $0] } ?? [:], body: body.serialized()))
    if session == nil { session = reply.headers["mcp-session-id"] }
    return try? JSON.parse(reply.body)
}

/// One tool call, timed. A call that does not answer within `hang` seconds is the worst failure the
/// owner named (the agent stuck); it is recorded as HUNG and the run goes on.
@discardableResult @MainActor
func call(_ step: String, _ name: String, _ args: JSON = .object([:]), budget: Double = 20, hang: Double = 90) async -> String {
    let started = Date()
    let reply: JSON? = await withTaskGroup(of: JSON??.self) { group in
        group.addTask { @MainActor in await rpc("tools/call", ["name": .string(name), "arguments": args]) }
        group.addTask { try? await Task.sleep(nanoseconds: UInt64(hang * 1e9)); return .some(nil) }
        let first = await group.next()!
        group.cancelAll()
        return first ?? nil
    }
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    guard let reply else {
        print("=== \(scenario) / \(step): HUNG after \(ms) ms\n")
        rows.append(Row(scenario: scenario, step: step, ms: ms, ok: false, note: "HUNG: no answer in \(Int(hang)) s"))
        failures.append("\(scenario) / \(step): no answer in \(Int(hang)) s")
        return "HUNG"
    }
    let text = reply["result"]?["content"]?[0]?["text"]?.string ?? "no answer: \(reply.serialized())"
    let pictures = reply["result"]?["content"]?.array?.filter { $0["type"]?.string == "image" } ?? []
    if let folder = env["POKI_PICTURES"] {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let safe = "\(scenario)-\(step)".replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
        for (i, image) in pictures.enumerated() {
            if let b64 = image["data"]?.string, let data = Data(base64Encoded: b64) {
                try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(String(format: "%02d-%@%@.jpg", rows.count + 1, safe, i == 0 ? "" : "-\(i + 1)")))
            }
        }
    }
    let first = text.split(separator: "\n").first.map(String.init) ?? ""
    var notes: [String] = []
    if Double(ms) / 1000 > budget { notes.append("slow: over \(Int(budget)) s") }
    if pictures.isEmpty { notes.append("no picture") }
    print("=== \(scenario) / \(step): \(ms) ms, \(pictures.count) image(s)\n\(text)\n")
    rows.append(Row(scenario: scenario, step: step, ms: ms, ok: notes.isEmpty, note: notes.isEmpty ? first.prefix(70).description : notes.joined(separator: "; ")))
    for n in notes { failures.append("\(scenario) / \(step): \(n)") }
    return text
}

@MainActor func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS \(scenario): \(what)" : "FAIL \(scenario): \(what)")
    rows.append(Row(scenario: scenario, step: what, ms: 0, ok: ok, note: ok ? "pass" : "FAIL"))
    if !ok { failures.append("\(scenario): \(what)") }
}

/// The number of the first (or last) listed element whose line holds `text`, optionally of a type.
func ref(in answer: String, _ text: String, type: String? = nil, last: Bool = false) -> Int? {
    let candidates = answer.split(separator: "\n").filter { line in
        line.contains("\"") && line.contains(text) && (type.map { line.contains(" \($0) ") } ?? true)
    }
    // An element whose whole label is the text comes before one that only contains it (a tap on
    // "Open" must not land on the alert "Open in Poki Gym?").
    let exact = candidates.filter { $0.contains(" \"\(text)\" ") || $0.contains(" \"\(text) = ") }
    let lines = exact.isEmpty ? candidates : exact
    guard let line = last ? lines.last : lines.first else { return nil }
    let head = line.split(separator: " ").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "+~ ")) } ?? ""
    return Int(head)
}

/// Opens a Gym scenario the way an agent would: back to the menu (the Menu button, or a fresh
/// launch), tap the scenario's row, and read; the title "Gym: <name>" must be on screen. (simctl
/// openurl is not used: from outside the app it raises an "Open in Poki Gym?" system alert.)
@MainActor func open(_ name: String) async -> String {
    scenario = name
    var answer = await call("look", "look")
    if !answer.contains("Gym: menu") {
        if let menu = ref(in: answer, "\"Menu\"", type: "Button") {
            answer = await call("tap Menu", "do", ["actions": [["tap": .number(Double(menu))]]])
        } else {
            answer = await call("launch Poki Gym fresh", "do", ["actions": [["launch": ["bundle": .string(gymBundle), "fresh": true]]]])
        }
    }
    if ref(in: answer, "\"\(name)", type: "Button") == nil { answer = await call("look at the menu", "look") }
    guard let row = ref(in: answer, "\"\(name)", type: "Button") else {
        check(false, "the \(name) row is on the menu"); return answer
    }
    answer = await call("open \(name)", "do", ["actions": [["tap": .number(Double(row))]]])
    for i in 1...2 where !answer.contains("Gym: \(name)") { answer = await call("look at \(name)\(i == 1 ? "" : " (again)")", "look") }
    check(answer.contains("Gym: \(name)"), "the \(name) screen is in front")
    return answer
}

/// scroll_to as an agent uses it: PokiCore stops when an action's time runs out and says to call
/// again to go on; the agent calls again until the text is found or the list is through.
@MainActor func scrollTo(_ text: String, step: String, budget: Double = 30, max: Int = 8) async -> String {
    var answer = ""
    for i in 1...max {
        answer = await call(i == 1 ? step : "\(step) (again, \(i))", "do", ["actions": [["scroll_to": .string(text)]]], budget: budget)
        if answer.contains("found at") { break }
        if !(answer.contains("call scroll_to again") || answer.contains("may have been delivered")) { break }
    }
    return answer
}

/// Taps the element with `text` and reads; `state` must then be on screen.
@MainActor func tap(_ text: String, in answer: String, type: String? = nil, last: Bool = false, expect state: String, then: [JSON] = []) async -> String {
    var answer = answer
    // A do's answer lists only what changed; an element that stayed keeps its number but is not
    // repeated, so the full list is read when the target is not in the answer (as an agent would).
    if ref(in: answer, text, type: type, last: last) == nil {
        answer = await call("look (full) for \(text)", "look", ["full": true])
    }
    guard let r = ref(in: answer, text, type: type, last: last) else {
        check(false, "\"\(text)\" is listed in the tree"); return answer
    }
    answer = await call("tap \(text)", "do", ["actions": .array([["tap": .number(Double(r))]] + then)])
    if !answer.contains(state) { answer = await call("look after tap \(text)", "look") }
    check(answer.contains(state), "tapping \"\(text)\" gives state \"\(state)\"")
    return answer
}

_ = await rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": .object([:]), "clientInfo": ["name": "poki-gym-check", "version": "1"]])
await call("look (cold)", "look")
let launched = await call("launch Poki Gym fresh", "do", ["actions": [["launch": ["bundle": .string(gymBundle), "fresh": true]]]], budget: 25)
var menu = launched.contains("Gym: menu") ? launched : await call("look (menu)", "look")
check(menu.contains("Gym: menu"), "Poki Gym is in front after launch")

// 1. Animation that never idles: the tree must still come, and the Next button must work, in time.
var a = await open("animation")
var treeReads = 0
for i in 1...3 {
    let read = await call("look under animation \(i)", "look", budget: 8)
    if !read.contains("read from the picture because") { treeReads += 1 }
}
check(treeReads >= 2, "the element tree is read under animation (\(treeReads)/3 reads were tree reads)")
a = await call("look for Next", "look")
a = await tap("Next", in: a, type: "Button", expect: "Next tapped 1")
a = await tap("Next", in: a, type: "Button", expect: "Next tapped 2")
let settled = await call("wait_until settled (never settles)", "do", ["actions": [["wait_until": ["settled": true, "ms": 3000]]]], budget: 12)
check(settled.contains("wait_until"), "wait_until on a screen that never settles answers instead of waiting forever")

// 2. A system alert on top of the screen.
a = await open("alert")
a = await tap("Show alert", in: a, type: "Button", expect: "alert shown")
a = await call("look at the alert", "look")
check(a.contains("Gym alert") && ref(in: a, "OK", type: "Button") != nil, "the alert and its OK button are in the tree")
a = await tap("OK", in: a, type: "Button", expect: "OK tapped")

// 3. Typing into an empty field (direct typing; the paste prompt never comes up).
a = await open("paste")
if let field = ref(in: a, "Paste here") {
    let typed = await call("type into the field", "do", ["actions": [["type": "hello gym 123", "ref": .number(Double(field))]]])
    let shown = typed.contains("hello gym 123") ? typed : await call("look at the field", "look")
    check(shown.contains("hello gym 123"), "typed text is read back from the field")
    check(!shown.lowercased().contains("paste prompt") || shown.contains("hello gym 123"), "no paste prompt stops the typing")
} else { check(false, "the text field is listed") }

// A fresh simulator shows the keyboard's slide-to-type introduction over the keys after the first
// typing; a phone in use never does. Dismissed here so it does not sit over later screens.
scenario = "keyboard intro"
let intro = await call("look for the keyboard intro", "look")
if let cont = ref(in: intro, "Continue", type: "Button") {
    _ = await call("tap Continue on the keyboard intro", "do", ["actions": [["tap": .number(Double(cont))]]])
}

// 4. A long list: scroll_to by text, then tap.
a = await open("list")
let found = await scrollTo("Row 250", step: "scroll_to Row 250")
check(found.contains("found at") || found.contains("Row 250"), "scroll_to finds Row 250")
a = found.contains("Row 250") ? found : await call("look for Row 250", "look")
a = await tap("Row 250", in: a, expect: "Row 250 tapped")
let missing = await call("scroll_to a row that does not exist", "do", ["actions": [["scroll_to": ["text": "Row 9999", "max_swipes": 2]]]], budget: 30)
check(!missing.contains("HUNG"), "scroll_to for a missing text answers")

// 5. A half sheet.
a = await open("sheet")
a = await tap("Open sheet", in: a, type: "Button", expect: "sheet open")
a = await call("look at the sheet", "look")
a = await tap("Done", in: a, type: "Button", expect: "Done tapped")

// 6. Focus that arrives late: type with no target once the field has focus.
a = await open("focus")
a = await tap("Start", in: a, type: "Button", expect: "Gym: focus")
let late = await call("wait 2 s then type", "do", ["actions": [["wait": 2200], ["type": "late focus"]]])
let lateShown = late.contains("late focus") ? late : await call("look at the late field", "look")
check(lateShown.contains("late focus"), "typing lands in the field that took focus late")

// 7. A dense tree: 3,000 elements. Reads must stay in budget and the button must be reachable.
a = await open("dense")
let dense = await call("look at 1,500 elements", "look", budget: 15)
check(!dense.contains("HUNG"), "a dense tree is read")
let foundButton = await scrollTo("Found", step: "scroll_to Found", budget: 40)
a = foundButton.contains("Found") ? foundButton : await call("look for Found", "look", budget: 15)
a = await tap("Found", in: a, type: "Button", expect: "Found tapped")

// 8. Two decoys with the button's label and frame: the real button must still be tapped.
a = await open("dup")
a = await tap("Twin", in: a, type: "Button", last: true, expect: "Twin tapped")

// 9. A web view filling the screen with one link.
a = await open("fullscreen")
// Diagnostic: WDA's raw XML for this screen, to see whether the web view's parts are there at all.
if let raw = try? await URLSession.shared.data(from: url.appendingPathComponent("source").appending(queryItems: [URLQueryItem(name: "format", value: "xml")])).0,
   let xml = (try? JSON.parse(raw))?["value"]?.string {
    func count(_ needle: String) -> Int { xml.components(separatedBy: needle).count - 1 }
    print("diag: raw XML has \(xml.count) characters; WebView nodes \(count("<XCUIElementTypeWebView")), Link nodes \(count("<XCUIElementTypeLink")), StaticText nodes \(count("<XCUIElementTypeStaticText")), 'A web page' \(count("A web page")), 'Open' \(count("\"Open\""))")
    if let r = xml.range(of: "<XCUIElementTypeWebView") { print("diag: web view node: " + xml[r.lowerBound...].prefix(600) + "\n") }
}
// The web view's parts reach the tree a few seconds after the page loads; PokiCore says so and
// the agent reads again, as here (up to four times, a second apart).
for i in 1...8 where ref(in: a, "Open") == nil {
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    a = await call("look again at the web view (\(i))", "look")
}
a = await tap("Open", in: a, expect: "Opened")

// 10. A navigation push and the system back button.
a = await open("nav")
a = await tap("Push", in: a, expect: "Pushed page")
a = await call("look at the pushed page", "look")
if let back = ref(in: a, "Gym: nav\"", type: "Button") ?? ref(in: a, "Back", type: "Button") {
    let popped = await call("tap back", "do", ["actions": [["tap": .number(Double(back))]]])
    let home = popped.contains("Gym: nav\n") || popped.contains("Gym: nav\"") && !popped.contains("Pushed page") ? popped : await call("look after back", "look")
    check(!home.contains("Pushed page"), "the system back button pops the page")
} else { check(false, "a back button is listed on the pushed page") }

// Faults. A. A look while the runner is busy with a long action: it must answer, not queue forever.
scenario = "busy runner"
_ = await open("animation")
scenario = "busy runner"
async let long: String = call("do with a 4 s wait", "do", ["actions": [["wait": 4000]]], budget: 12)
try? await Task.sleep(nanoseconds: 500_000_000)
let during = await call("look while the do runs", "look", budget: 12)
_ = await long
check(!during.contains("HUNG"), "a look during a long do answers")

// B. The runner dies (as after a tunnel drop): every call still answers, says so, and recovers when
// the runner is back.
scenario = "runner killed"
let runnerBundle = env["WDA_BUNDLE"] ?? "com.facebook.WebDriverAgentRunner.xctrunner"
print(sh(["xcrun", "simctl", "terminate", udid, runnerBundle]))
try? await Task.sleep(nanoseconds: 1_500_000_000)
let dead = await call("look with the runner dead", "look", budget: 30)
check(!dead.contains("HUNG"), "a look with a dead runner answers")
let deadDo = await call("do with the runner dead", "do", ["actions": [["swipe": "up"]]], budget: 30)
check(!deadDo.contains("HUNG") && !deadDo.contains("did: swipe"), "a do with a dead runner answers and sends nothing")
if env["POKI_WDA_START"] != nil {
    // PokiCore asked the host to restart the runner; the look must come back by itself.
    // A tree read ("app: Poki Gym"), not the picture-only reading the fallback screenshot gives
    // while the runner is still down.
    var back = ""
    for i in 1...25 {
        back = await call("look after the runner restart (\(i))", "look", budget: 30)
        if back.contains("app: Poki Gym") { break }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }
    check(back.contains("app: Poki Gym"), "look reads the tree again once the runner is back")
    let afterDo = await call("do after the runner restart", "do", ["actions": [["swipe": "up"]]])
    check(afterDo.contains("did: swipe"), "do works again once the runner is back")
}

// Scorecard.
print("\n| scenario | step | ms | ok | note |\n|---|---|---:|---|---|")
for r in rows { print("| \(r.scenario) | \(r.step) | \(r.ms == 0 ? "" : String(r.ms)) | \(r.ok ? "yes" : "NO") | \(r.note.replacingOccurrences(of: "|", with: "/")) |") }
let calls = rows.filter { $0.ms > 0 }
let worst = calls.max { $0.ms < $1.ms }
print("\ncalls: \(calls.count), slowest: \(worst.map { "\($0.scenario) / \($0.step) \($0.ms) ms" } ?? "none"), failures: \(failures.count)")
for f in failures { print("  - \(f)") }
exit(failures.isEmpty ? 0 : 1)
#else
print("poki-gym-check runs on macOS against the iOS Simulator")
#endif
