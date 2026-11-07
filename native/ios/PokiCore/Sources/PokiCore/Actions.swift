import Foundation

// The actions of `do`, as WebDriverAgent requests. Gestures are named verbs with defaults: the model
// names a direction or a target, never a path.
//
//   {tap: n | [x, y]}                          {type: "text", ref?, clear?}
//   {key: "return" | "delete" | ...}           {swipe: dir | {direction, in?, distance?}}
//   {scroll_to: "text" | {text | ref, in?, direction?, max_swipes?}}
//   {long_press: n | [x, y] | {ref | x, y, ms?}}   {drag: {from, to, ms?} | [x1, y1, x2, y2]}
//   {pinch: {ref | x, y, scale}}               {button: "home" | "lock" | "volume_up" | "volume_down"}
//   {launch: "bundle" | {bundle, fresh?}}      {wait: ms}       {back: true}
//   {handoff: {kind, text}} hands a step to the owner on the phone (no input until Done, or {handoff: false})
//   {wait_until: "text" | {text, gone?, ms?} | {settled: true, ms?}}
extension Computer {
    static let keyText: [String: String] = ["return": "\n", "enter": "\n", "delete": "\u{8}", "backspace": "\u{8}", "tab": "\t", "space": " ", "escape": "\u{1b}"]
    static let buttons: [String: String] = ["volume_up": "volumeUp", "volume-up": "volumeUp", "volume_down": "volumeDown", "volume-down": "volumeDown"]

    /// The point to touch for a target. A numbered element is touched where a tap reaches it: its
    /// centre, or the nearest part of it that is on screen and not under a bar or another element.
    /// None: not_hittable, and nothing is sent.
    func point(_ spec: JSON?) throws -> (x: Double, y: Double) {
        guard let spec else { throw ActionFailure(message: "no target given", delivery: .notSent) }
        if let a = spec.array, a.count >= 2, let x = a[0].double, let y = a[1].double { return try onScreen((x, y)) }
        if case .object = spec {
            if let ref = spec["ref"]?.int { return try reachable(ref) }
            if let x = spec["x"]?.double, let y = spec["y"]?.double { return try onScreen((x, y)) }
            throw ActionFailure(message: "a target is a number, [x, y], {ref} or {x, y}", delivery: .notSent)
        }
        guard let ref = spec.int else { throw ActionFailure(message: "a target is a number, [x, y], {ref} or {x, y}", delivery: .notSent) }
        return try reachable(ref)
    }

    func onScreen(_ p: (x: Double, y: Double)) throws -> (x: Double, y: Double) {
        if let size, p.x < 0 || p.y < 0 || p.x > size.width || p.y > size.height {
            throw ActionFailure(message: "not_hittable: [\(Int(p.x)), \(Int(p.y))] is off the screen (\(Int(size.width))x\(Int(size.height)) points); nothing was sent", delivery: .notSent)
        }
        return p
    }

    /// Only an element with no part on the screen is refused. One that looks covered in the tree is
    /// still touched (at a free point of it when there is one, else at its centre) and the answer
    /// says what lay over it: the tree's order is not what is drawn on top (a Select button over a
    /// photo grid came after the photos in the tree), and the model sees from the read whether the
    /// touch landed.
    func reachable(_ ref: Int) throws -> (x: Double, y: Double) {
        let e = try element(ref)
        if e.fromPicture || size == nil { return e.frame.centre }
        let layout = self.layout
        guard let hit = layout.touchPoint(e) else {
            throw ActionFailure(message: "not_hittable: element \(ref) \(e.type) \"\(e.text.prefix(40))\": \(layout.unreachable(e)); nothing was sent. Bring it into view first ({scroll_to: {ref: \(ref)}}) or touch a point you can see on the screenshot", delivery: .notSent)
        }
        return hit.point
    }

    /// " at [x, y] (…)" when the point touched is not the element's centre, or something in the tree
    /// lies over it.
    /// A container the size of the screen (a toolbar wrapper, a sheet's full-screen close control)
    /// has no centre worth tapping; the answer says where the tap went (seen on the phone: taps on a
    /// 402 by 874 "toolbar" element in a shop app).
    /// Types that hold other elements and take no tap of their own.
    static let containers: Set<String> = ["Alert", "Sheet", "Window", "Other", "Group", "Table", "CollectionView", "ScrollView", "NavigationBar", "Toolbar", "TabBar", "Application", "Dialog", "Popover", "WebView", "List"]

    /// A tap on a container (an alert, a sheet, a toolbar) does nothing by itself: name the listed
    /// elements inside it, so the model taps one of those next.
    func container(_ spec: JSON?) -> String {
        guard let spec, let ref = spec.int ?? spec["ref"]?.int, let e = refs[ref], !e.fromPicture, Self.containers.contains(e.type) else { return "" }
        let inside = listed.filter { $0.ref != ref && e.contains($0.element) }
        guard !inside.isEmpty else { return "" }
        let names = inside.prefix(8).map { "\($0.ref) \"\($0.element.text.prefix(30))\"" }.joined(separator: ", ")
        return " (this element is a \(e.type), a container; the elements inside it are \(names)\(inside.count > 8 ? ", …" : ""); tap one of those)"
    }

    func fillsScreen(_ spec: JSON?, _ p: (x: Double, y: Double)) -> String {
        guard let spec, let ref = spec.int ?? spec["ref"]?.int, let e = refs[ref], let size else { return "" }
        guard e.frame.width * e.frame.height >= 0.8 * size.width * size.height else { return "" }
        return " (this element fills the screen, so the tap went to its centre at [\(Int(p.x.rounded())), \(Int(p.y.rounded()))], whatever is drawn there; tap a smaller element, or a point on the picture)"
    }

    func offCentre(_ spec: JSON?, _ p: (x: Double, y: Double)) -> String {
        guard let spec, let ref = spec.int ?? spec["ref"]?.int, let e = refs[ref], !e.fromPicture, size != nil else { return "" }
        guard let hit = layout.touchPoint(e) else { return "" }
        let c = e.frame.centre
        let moved = abs(c.x - p.x) >= 0.5 || abs(c.y - p.y) >= 0.5
        let at = " at [\(Int(p.x.rounded())), \(Int(p.y.rounded()))]"
        guard hit.free else { return "\(at) (\(hit.over ?? "something") lies over all of its visible part in the tree; touched anyway: see whether it took)" }
        guard moved else { return "" }
        return hit.over.map { "\(at) (its centre is under \($0) in the tree)" } ?? "\(at) (its centre is off the screen)"
    }

    func element(_ ref: Int) throws -> Element {
        guard let e = refs[ref] else { throw ActionFailure(message: "no element \(ref) in the latest read", delivery: .notSent) }
        return e
    }

    /// Where a swipe goes: inside the element named, or the biggest list on screen, less the bars
    /// and anything drawn over it (a reply bar), so the finger lands on what scrolls.
    func area(_ ref: JSON?, _ screen: ScreenSize) throws -> Rect {
        let named = try ref.flatMap { r -> Element? in try (r.int ?? r["ref"]?.int).map(element) }
        return Layout(all: lastAll, screen: screen).swipeArea(named)
    }

    func swipePath(_ area: Rect, _ direction: String, _ distance: String = "long") throws -> (Double, Double, Double, Double) {
        let d: (Double, Double)
        switch direction {
        case "up": d = (0, -1)
        case "down": d = (0, 1)
        case "left": d = (-1, 0)
        case "right": d = (1, 0)
        default: throw ActionFailure(message: "swipe must be up, down, left or right", delivery: .notSent)
        }
        let half = (d.0 != 0 ? area.width : area.height) * (distance == "short" ? 0.2 : 0.35)
        let (cx, cy) = area.centre
        return (cx - d.0 * half, cy - d.1 * half, cx + d.0 * half, cy + d.1 * half)
    }

    /// One touch from a point to another: down, `hold` seconds still, moving at a steady speed for
    /// `seconds`, then `rest` seconds still before lifting (no rest = a flick that keeps a list
    /// moving; a rest = the list stops where the finger stopped). XCTest's own press-drag through
    /// WDA's pressAndDragWithVelocity; its time limit is the gesture's own and a slow answer is not
    /// taken as the runner being gone.
    func gesture(_ path: (Double, Double, Double, Double), seconds: Double, hold: Double = 0, rest: Double = 0, until: Double) async throws {
        let distance = max(1, hypot(path.2 - path.0, path.3 - path.1))
        let velocity = distance / max(0.05, seconds)
        let expected = hold + distance / velocity + rest
        let timeout = max(1, min(expected + 5, until - now() - 0.2))
        do {
            _ = try await runner.call("POST", "/wda/pressAndDragWithVelocity", ["fromX": .number(path.0), "fromY": .number(path.1), "toX": .number(path.2), "toY": .number(path.3), "pressDuration": .number(hold), "holdDuration": .number(rest), "velocity": .number(velocity.rounded())], timeout: timeout, countsAsMiss: false)
        } catch let e as RunnerError where e.code == "unknown command" || e.code == "unknown method" {
            // A runner older than pressAndDragWithVelocity.
            _ = try await runner.call("POST", "/wda/dragfromtoforduration", ["fromX": .number(path.0), "fromY": .number(path.1), "toX": .number(path.2), "toY": .number(path.3), "duration": .number(max(0.05, hold))], timeout: timeout, countsAsMiss: false)
        }
    }

    func tap(_ p: (x: Double, y: Double)) async throws {
        _ = try await runner.call("POST", "/wda/tap", ["x": .number(p.x), "y": .number(p.y)], timeout: 3)
    }

    /// Returns the action's kind (for the settle pause) and what it did.
    func perform(_ action: JSON, until: Double) async throws -> (String, String) {
        if let spec = action["tap"] {
            let p = try point(spec)
            try await tap(p)
            return ("tap", "tap \(describe(action))\(offCentre(spec, p))\(fillsScreen(spec, p))\(container(spec))")
        }
        if let text = action["type"]?.text {
            let target: Element? = try action["ref"]?.int.map(element)
            if let ref = action["ref"] {
                try await tap(try point(ref))
            }
            // Keys go to the focused field; a tap takes a moment to focus one (seen on the phone:
            // text typed right after the tap went nowhere). Wait for a field to be focused, up to
            // 2 s, then type anyway and say when none was.
            let focusWait = min(2, max(0.2, until - now() - 1))
            let focused = await waitForFocus(seconds: focusWait, target: target)
            let focusNote = focused ? "" : "; no field was focused when the text went (no keyboard came up in \(Int((focusWait * 1000).rounded())) ms), so it may have gone nowhere"
            let hidden = describe(action).hasSuffix("(hidden)")
            let via = action["via"]?.string == "paste" ? "pasted" : "typed"
            let clear = action["clear"]?.bool ?? false
            var note = ""
            if via == "pasted" {
                note = try await paste(text, clear: clear, until: until, target: target)
            } else {
                note = try await type(text, clear: clear, hidden: hidden, target: target, until: until)
            }
            // What the field holds now, so the model sees at once whether the text arrived whole.
            let reads = await fieldValue(target: target, holding: text, timeout: min(1.5, max(0.3, until - now() - 0.2)))
            let readBack = reads.map { hidden ? "; the field now holds \($0.count) characters" : "; the field now reads \"\($0.count > 200 ? String($0.prefix(190)) + "…" : $0)\"" }
                ?? "; the field could not be read back (no focused field answered in time), so check the elements or the picture"
            return ("type", "\(describe(action)) (\(via))\(readBack)\(focusNote)\(note)")
        }
        if action["back"] != nil {
            return ("back", try await back(until: until))
        }
        if let spec = action["handoff"] {
            if case .bool(false) = spec {
                guard let current = handoff.value, current.done == nil else { return ("handoff", "handoff: nothing is handed to the owner") }
                handoff.value = nil
                emit(.handoffEnded(id: current.id, how: "takenBack"))
                return ("handoff", "handoff: taken back (\(current.kind): \"\(current.text.prefix(60))\"); inputs are sent again")
            }
            let kind = (spec["kind"]?.string ?? "other").lowercased()
            let kinds = ["passcode", "password", "verification", "payment", "other"]
            guard kinds.contains(kind) else { throw ActionFailure(message: "handoff kind is one of \(kinds.joined(separator: ", "))", delivery: .notSent) }
            guard let text = spec.text ?? spec["text"]?.text, !text.isEmpty else { throw ActionFailure(message: "handoff takes {kind, text}: what the owner must do themselves on the phone; or false to take the step back", delivery: .notSent) }
            let h = Handoff(id: UUID().uuidString, kind: kind, text: String(text.prefix(300)), requested: Date())
            handoff.value = h
            emit(.handoffRequested(id: h.id, kind: kind, text: h.text, app: lastForeground?.describe))
            return ("handoff", "handed to the owner (\(kind)): \"\(h.text.prefix(80))\", shown on the phone with a Done button. Keep calling look every few seconds, or {wait_until: {handoff_done: true, ms: 10000}}; no input is sent until the owner taps Done or you send {handoff: false}; status shows handoff: waiting|done")
        }
        if let key = action["key"]?.text {
            let k = key.lowercased()
            guard let text = Self.keyText[k] ?? (key.count == 1 ? key : nil) else {
                throw ActionFailure(message: "key \(key) has no equivalent; use return, delete, tab, space, escape or one character", delivery: .notSent)
            }
            _ = try await runner.call("POST", "/wda/keys", ["value": [.string(text)]], timeout: 3)
            return ("key", "key \(key)")
        }
        if let spec = action["swipe"] {
            let direction = spec.string ?? spec["direction"]?.string ?? ""
            let screen = try await screenSize(until: until)
            let path = try swipePath(try area(spec["in"] ?? action["in"], screen), direction, spec["distance"]?.string ?? "long")
            try await gesture(path, seconds: 0.25, until: until)
            return ("swipe", "swipe \(direction) from [\(Int(path.0)), \(Int(path.1))] to [\(Int(path.2)), \(Int(path.3))]")
        }
        if let spec = action["scroll_to"] {
            return ("scroll_to", "scroll_to \(spec.serialized()): \(try await scrollTo(spec, until: until))")
        }
        if let spec = action["long_press"] {
            let p = try point(spec)
            let ms = min(5000, max(100, spec["ms"]?.double ?? action["ms"]?.double ?? 600))
            _ = try await runner.call("POST", "/wda/touchAndHold", ["x": .number(p.x), "y": .number(p.y), "duration": .number(ms / 1000)], timeout: 3 + ms / 1000)
            return ("long_press", "long_press \(spec.serialized()) \(Int(ms)) ms")
        }
        if let spec = action["drag"] {
            let from: (x: Double, y: Double), to: (x: Double, y: Double)
            if let a = spec.array, a.count == 4, let v = Optional(a.compactMap(\.double)), v.count == 4 {
                from = (v[0], v[1]); to = (v[2], v[3])
            } else {
                from = try point(spec["from"]); to = try point(spec["to"])
            }
            let ms = min(3000, max(100, spec["ms"]?.double ?? 400))
            let hold = min(3000, max(0, spec["hold_ms"]?.double ?? 0))
            try await gesture((from.x, from.y, to.x, to.y), seconds: ms / 1000, hold: hold / 1000, rest: 0.15, until: until)
            return ("drag", "drag from [\(Int(from.x)), \(Int(from.y))] to [\(Int(to.x)), \(Int(to.y))] in \(Int(ms)) ms\(hold > 0 ? " after holding \(Int(hold)) ms" : "")")
        }
        if let spec = action["pinch"] {
            let p = try point(spec)
            let screen = try await screenSize(until: until)
            let scale = min(4, max(0.25, spec["scale"]?.double ?? action["scale"]?.double ?? 2))
            let start = min(screen.width, screen.height) * (scale > 1 ? 0.12 : 0.3)
            let a = start / 2, b = start * scale / 2, ms = 500.0
            func finger(_ id: String, _ sign: Double) -> JSON {
                ["type": "pointer", "id": .string(id), "parameters": ["pointerType": "touch"], "actions": [
                    ["type": "pointerMove", "duration": 0, "x": .number((p.x + sign * a).rounded()), "y": .number(p.y.rounded())],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pointerMove", "duration": .number(ms), "x": .number((p.x + sign * b).rounded()), "y": .number(p.y.rounded())],
                    ["type": "pointerUp", "button": 0],
                ]]
            }
            _ = try await runner.call("POST", "/actions", ["actions": [finger("f1", -1), finger("f2", 1)]], timeout: 4)
            return ("pinch", "pinch \(spec.serialized()) x\(scale)")
        }
        if let name = action["button"]?.text {
            let n = name.lowercased()
            switch n {
            // WDA waits for SpringBoard after a button (about 3 s on the simulator): these get the time a
            // gesture gets, and a slow answer is not taken as a sign that the runner is gone.
            case "lock", "power": _ = try await runner.call("POST", "/wda/lock", [:], timeout: 8, countsAsMiss: false)
            // WDA serves the Home button only outside a session ("Unhandled endpoint" inside one).
            case "home": _ = try await runner.raw("POST", "/wda/homescreen", [:], timeout: 8, countsAsMiss: false)
            default:
                guard let wda = Self.buttons[n] else { throw ActionFailure(message: "button \(name) has no equivalent; use home, lock, volume_up or volume_down", delivery: .notSent) }
                _ = try await runner.call("POST", "/wda/pressButton", ["name": .string(wda)], timeout: 8, countsAsMiss: false)
            }
            return ("button", "button \(name)")
        }
        if let spec = action["launch"] {
            guard let bundle = spec.string ?? spec["bundle"]?.string, !bundle.isEmpty else { throw ActionFailure(message: "launch takes a bundle id", delivery: .notSent) }
            let fresh = spec["fresh"]?.bool ?? false
            // A fresh launch ends the app first, so a page it was left on cannot answer for it, and
            // starts it through XCTest's launch. Otherwise the app is activated: brought to the front
            // as it is, or started if it is not running. XCTest's launch always ends a running app
            // and starts it again, with a handshake that takes several seconds on the phone.
            var note = ""
            if fresh {
                // Ending a running app through XCTest can take over 4 s on the simulator (seen in
                // CI: a fresh launch gave up at the terminate and Settings never came). A slow end
                // is not a miss, and the launch goes anyway: it queues behind the end and runs
                // after it, within the launch's own time.
                do { _ = try await runner.call("POST", "/wda/apps/terminate", ["bundleId": .string(bundle)], timeout: 6, countsAsMiss: false) }
                catch let e as RunnerError where e.delivery == .notSent {}
                catch let e as RunnerError { note = "; ending the app first did not answer in time (\(e.message)); the launch was sent anyway" }
                _ = try await runner.call("POST", "/wda/apps/launch", ["bundleId": .string(bundle)], timeout: max(3, min(8, until - now() - 0.3)))
            } else {
                _ = try await runner.call("POST", "/wda/apps/activate", ["bundleId": .string(bundle)], timeout: 8)
            }
            return ("launch", "launch \(bundle)\(fresh ? " (fresh)" : "")\(note)")
        }
        if let spec = action["wait_until"] {
            return ("wait_until", try await waitUntil(spec, until: until))
        }
        if let ms = action["wait"]?.double {
            let seconds = min(ms / 1000, 3, max(0, until - now()))
            await sleep(seconds: seconds)
            return ("wait", "wait \(Int(seconds * 1000)) ms")
        }
        throw ActionFailure(message: "unknown action \(action.serialized())", delivery: .notSent)
    }

    /// The whole text as key presses in one request. Clearing deletes what the focused field holds
    /// with Delete keys in the same request: WDA's element clear retries until the value is empty,
    /// which a field like Safari's address bar never reports (that took 25 s).
    /// `clear` is checked: when the field still holds something besides the text afterwards (the
    /// cursor was not at the end, or a field reports a placeholder as its value), the field is
    /// cleared through WDA's element clear once (bounded at 3 s) and the text typed again; the
    /// answer says what happened. Returns a note for the answer.
    @discardableResult
    func type(_ text: String, clear: Bool, hidden: Bool = false, target: Element? = nil, until: Double = .infinity) async throws -> String {
        var deletes = 0
        var before: String?
        if clear {
            before = await fieldValue(target: target, timeout: 1.5)
            if let s = before { deletes = min(400, s.count) }
        }
        let keys = Array(repeating: "\u{8}", count: deletes) + text.map(String.init)
        guard keys.count <= 2000 else { throw ActionFailure(message: "at most 2000 characters at a time", delivery: .notSent) }
        // The keys queue behind whatever the runner is still serving: the focus reads this side gave
        // up on while the keyboard came up (the CI simulator's runner stood still for seconds at the
        // keyboard's first use, and the keys sent behind those reads were "unknown"). A busy runner
        // is waited for within the action's time; when it is not through, nothing is typed, so the
        // text can be sent again safely.
        if runner.busyWith != nil, await !runner.waitUntilFree(timeout: max(0.3, min(3, until - now() - 1))), let busy = runner.busyWith {
            throw ActionFailure(message: "nothing was typed: the runner is still finishing an earlier \(busy). Send the type again (with ref, so the field is tapped again) once it is through.", delivery: .notSent)
        }
        _ = try await runner.call("POST", "/wda/keys", ["value": .array(keys.map(JSON.string))], timeout: 3 + 0.06 * Double(keys.count))
        guard clear, before != nil else { return "" }
        guard let after = await fieldValue(target: target, holding: text, timeout: 1), after != text, !after.isEmpty, after != before else { return "" }
        // Something is left that the deletes did not remove (the cursor was not at the end): as many
        // deletes as the field holds now, and the text again. No element clear: WDA's retries until
        // the value is empty, which some fields never report (Safari's address bar took 25 s).
        let again = Array(repeating: "\u{8}", count: min(400, after.count)) + text.map(String.init)
        _ = try await runner.call("POST", "/wda/keys", ["value": .array(again.map(JSON.string))], timeout: 3 + 0.06 * Double(again.count))
        return "; clear: the field still held \(hidden ? "\(after.count) characters" : "\"\(after.prefix(60))\"") after \(deletes) deletes, so \(min(400, after.count)) more deletes and the text were sent again"
    }

    static let fieldTypes: Set<String> = ["TextField", "SecureTextField", "SearchField", "TextView"]

    /// Whether a field took the focus (the keyboard is up), waiting up to `seconds` (a tree read
    /// every 150 ms). Focus is read from the tree, never asked of the runner: WDA's focus query
    /// (GET /element/active) is an XCTest query that hung the CI simulator's runner for 19 s on
    /// the keyboard's first-use intro, and everything queued behind it with it; a tree read is
    /// sessionless and bounded by the accessibility deadline.
    func waitForFocus(seconds: Double, target: Element?) async -> Bool {
        let deadline = now() + seconds
        while true {
            let seen = await fieldOnScreen(target: target, timeout: max(0.5, min(1.5, deadline - now() + 0.5)))
            if seen.keyboard { return true }
            if now() >= deadline || (!seen.came && runner.busyWith != nil) { return false }
            await sleep(seconds: 0.15)
        }
    }

    /// The field the text goes to, from one tree read: the field under or around the tapped target,
    /// else the field holding `holding`, else the only field on screen. `keyboard`: the keyboard is
    /// up; `came`: the tree was read.
    func fieldOnScreen(target: Element?, holding: String? = nil, timeout: Double) async -> (field: Element?, keyboard: Bool, came: Bool) {
        guard let seen = try? await runner.tree(timeout: timeout, format: config.treeFormat) else { return (nil, false, false) }
        let all = seen.elements
        let keyboard = all.contains { $0.type == "Keyboard" }
        let fields = all.filter { Self.fieldTypes.contains($0.type) }
        var field: Element?
        if let target {
            field = fields.first { $0.frame.contains(target.frame.centre) || target.frame.contains($0.frame.centre) }
        }
        if field == nil, let holding, !holding.isEmpty { field = fields.first { ($0.value ?? "").contains(holding) } }
        if field == nil, fields.count == 1 { field = fields[0] }
        return (field, keyboard, true)
    }

    /// `{back: true}`: the navigation bar's back button when the last read listed one (a button in
    /// the top left corner), else an edge swipe from the left, which most apps take as back. The
    /// answer says which, and the model sees the result in the read. No app-specific rule.
    func back(until: Double) async throws -> String {
        let screen = try await screenSize(until: until)
        let top = lastAll.filter { e in
            e.type == "Button" && e.frame.x < 70 && e.frame.y < 130 && e.frame.y + e.frame.height > 20 && e.frame.width < 180 && e.frame.height < 70 && !e.fromPicture
        }.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
        if let button = top.first {
            let p = (x: button.frame.x + button.frame.width / 2, y: button.frame.y + button.frame.height / 2)
            try await tap(p)
            return "back: tapped the top-left button \(button.text.isEmpty ? "" : "\"\(button.text)\" ")at [\(Int(p.x)), \(Int(p.y))]"
        }
        let y = screen.height / 2
        try await gesture((2, y, screen.width * 0.6, y), seconds: 0.3, until: until)
        return "back: no back button was listed in the top left, so an edge swipe from the left was sent (what most apps take as back)"
    }

    /// What the field holds now (its value from the tree), or nil when no field is found or read.
    func fieldValue(target: Element?, holding: String? = nil, timeout: Double) async -> String? {
        let seen = await fieldOnScreen(target: target, holding: holding, timeout: timeout)
        guard let field = seen.field else { return nil }
        return field.value ?? ""
    }

    /// Words of the edit menu's Paste item in the languages iOS ships most.
    static let pasteWords = ["paste", "粘贴", "貼上", "貼り付け", "ペースト", "붙여넣기", "coller", "einfügen", "pegar", "incolla", "colar", "вставить"]

    /// The backup to typing (`via: "paste"`): the text goes through the clipboard and the field's edit
    /// menu. The owner's clipboard is read first and put back afterwards, whatever happens; if it
    /// cannot be read, nothing is pasted (it would be lost). The clipboard is checked to hold the
    /// text before Paste is tapped, and the owner's is put back only once the field shows the text:
    /// iOS asks the owner "Allow Paste?" for an app's first paste from the runner, and putting the
    /// owner's clipboard back before they answer pastes that instead (seen on the phone: the owner's
    /// own text went into a shop's search box). Returns a note for the answer.
    @discardableResult
    func paste(_ text: String, clear: Bool, until: Double, target: Element? = nil) async throws -> String {
        let saved: JSON
        do { saved = try await runner.call("POST", "/wda/getPasteboard", ["contentType": "plaintext"], timeout: 2, countsAsMiss: false) }
        catch { throw ActionFailure(message: "the clipboard could not be read, so it was not used (the owner's clipboard would be lost); type the text instead", delivery: .notSent) }
        guard let field = await fieldOnScreen(target: target, timeout: 1.5).field else {
            throw ActionFailure(message: "no field to paste into is listed (tap the field first, or name it with ref)", delivery: .notSent)
        }
        let (x, y, w, h) = (field.frame.x, field.frame.y, field.frame.width, field.frame.height)
        var restored = false
        func restore() async {
            guard !restored else { return }
            restored = true
            _ = try? await runner.call("POST", "/wda/setPasteboard", ["content": .string(saved.string ?? ""), "contentType": "plaintext"], timeout: 2, countsAsMiss: false)
        }
        do {
            if clear, let value = field.value, !value.isEmpty {
                _ = try await runner.call("POST", "/wda/keys", ["value": .array(Array(repeating: JSON.string("\u{8}"), count: min(400, value.count)))], timeout: 3 + 0.06 * Double(min(400, value.count)))
            }
            _ = try await runner.call("POST", "/wda/setPasteboard", ["content": .string(Data(text.utf8).base64EncodedString()), "contentType": "plaintext"], timeout: 2, countsAsMiss: false)
            let holds = (try? await runner.call("POST", "/wda/getPasteboard", ["contentType": "plaintext"], timeout: 2, countsAsMiss: false))?.string
                .flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }.map { String(decoding: $0, as: UTF8.self) }
            guard holds == text else {
                await restore()
                throw ActionFailure(message: "the clipboard could not be set to the text (the runner's write did not take), so nothing was pasted; type the text instead", delivery: .notSent)
            }
            _ = try await runner.call("POST", "/wda/touchAndHold", ["x": .number(x + w / 2), "y": .number(y + h / 2), "duration": .number(0.7)], timeout: 4)
            var item: Element?
            let menuBy = min(until - 0.3, now() + 2)
            while item == nil, now() < menuBy {
                await sleep(seconds: 0.2)
                if let seen = try? await runner.tree(timeout: max(0.3, min(1.2, menuBy - now())), format: config.treeFormat) {
                    item = seen.elements.first { e in Self.pasteWords.contains { e.text.lowercased() == $0 } }
                }
            }
            guard let item else {
                await restore()
                throw ActionFailure(message: "the field's menu showed no Paste item; the text was not pasted (a long press was sent)", delivery: .sent)
            }
            try await tap(item.frame.centre)
            // The paste has landed when the field shows the text; until then the clipboard stays.
            let landedBy = min(until - 0.3, now() + 2.5)
            var landed = false
            while !landed, now() < landedBy {
                await sleep(seconds: 0.25)
                landed = await fieldValue(target: target, holding: text, timeout: 0.8)?.contains(text) == true
            }
            if landed {
                await restore()
                return ""
            }
            // iOS may be asking the owner to allow the paste: the owner's clipboard goes back once
            // the text is in the field, or after 45 s, from a task of its own.
            Task { [self] in
                let giveUp = now() + 45
                while now() < giveUp {
                    await sleep(seconds: 1)
                    if await fieldValue(target: target, holding: text, timeout: 1)?.contains(text) == true { break }
                }
                await restore()
            }
            return "; the field did not show the text within \(Int(((now() - (landedBy - 2.5)) * 1000).rounded())) ms: iOS may be asking the owner to allow the paste (the owner's clipboard is put back once the text lands, or after 45 s)"
        } catch {
            await restore()
            throw error
        }
    }

    /// Swipes until the target is fully on screen and not under a bar, with a tree read after each
    /// swipe. The finger stops before lifting, so the list does not coast past the target. Stops at
    /// the end of the list, at max_swipes, or when the action time runs out.
    func scrollTo(_ spec: JSON, until: Double) async throws -> String {
        let screen = try await screenSize(until: until)
        let wantedElement: Element? = try spec["ref"]?.int.map(element)
        let wantedKey = wantedElement?.key
        let wantedText = spec.string ?? spec["text"]?.string ?? wantedElement.flatMap { $0.text.isEmpty ? nil : $0.text }
        guard wantedKey != nil || wantedText != nil else { throw ActionFailure(message: "scroll_to takes text or ref", delivery: .notSent) }
        let region = try area(spec["in"], screen)
        let fingerGoes = ["down": "up", "up": "down", "right": "left", "left": "right"][spec["direction"]?.string ?? "down"] ?? "up"
        let max = min(15, spec["max_swipes"]?.int ?? 12)
        func hit(_ all: [Element]) -> Element? {
            let layout = Layout(all: all, screen: screen)
            return all.first { e in
                guard wantedKey.map({ e.key == $0 }) ?? (!e.text.isEmpty && e.text.lowercased().contains(wantedText!.lowercased())) else { return false }
                let f = e.frame
                guard f.x >= 0, f.y >= 0, f.maxX <= screen.width, f.maxY <= screen.height else { return false }
                let c = f.centre
                return !layout.covers(e).contains { $0.frame.contains(c) }
            }
        }
        let wanted = wantedText.map { "\"\($0.prefix(40))\"" } ?? "element \(spec["ref"]!.int!)"
        // One read after each swipe: a swipe without a read can carry the target past the screen,
        // and an element search on the runner is a full snapshot too (seen in the gym: no faster
        // than the read). The gesture itself is most of a swipe's time, so the action has 12 s;
        // when under 1.6 s is left the scroll stops where it is and says so, so the model calls it
        // again rather than being told that something unknown may have happened.
        var all = lastAll, swipes = 0, last: String?
        func found(_ e: Element) -> String { "\(swipes) swipes, found at \(e.frame.described)" }
        func notYet(_ why: String) -> String { "\(swipes) swipes, \(wanted) not seen yet; \(why): call scroll_to again to go on from here" }
        while hit(all) == nil, swipes < max {
            guard until - now() > 1.6 else { return notYet("the action's time ran out before the list was through (\(Int(Self.scrollCap)) s)") }
            // A swipe sent while the runner is still serving the read after the last one would only
            // queue behind it and time out, and the whole scroll would come back unknown (seen in
            // the gym on 300 rows): the runner is waited for, and a swipe the runner did not confirm
            // ends the scroll with its progress, never with an unknown.
            if runner.busyWith != nil, await !runner.waitUntilFree(timeout: Swift.max(0.3, Swift.min(2, until - now() - 1.6))) {
                return notYet("the runner is still finishing the read after the last swipe")
            }
            do {
                try await gesture(try swipePath(region, fingerGoes), seconds: 0.25, rest: 0.05, until: until - 0.8)
            } catch let e as RunnerError where e.delivery == .unknown {
                return notYet("the runner did not confirm the last swipe in time (\(e.message)), so it may still land")
            }
            swipes += 1
            await sleep(seconds: 0.1)
            guard let seen = try? await runner.tree(timeout: Swift.max(0.3, Swift.min(1.5, until - now() - 0.2)), format: config.treeFormat) else { continue }
            let signature = seen.elements.map { "\($0.key)@\(Int($0.frame.y))" }.joined(separator: ";")
            if signature == last { return "\(swipes) swipes, \(wanted) not found: the list stopped moving (its end, or the text is not in it)" }
            last = signature
            all = seen.elements
        }
        if let e = hit(all) { return found(e) }
        return notYet("that is \(max) swipes (max_swipes takes up to 15)")
    }

    /// The time one scroll_to may take: more than an action, since it reports where it got to.
    static let scrollCap: Double = 12

    /// Reads the tree every quarter second until the text is there (or gone), or the screen holds still
    /// for two reads in a row. Not finding it is a fact, not a failure: the model decides.
    func waitUntil(_ spec: JSON, until: Double) async throws -> String {
        if spec["handoff_done"]?.bool == true {
            let started = now()
            let limit = Swift.min(started + Swift.min(10, Swift.max(0.2, (spec["ms"]?.double ?? 5000) / 1000)), until)
            while now() < limit {
                if !handoffWaiting { return "wait_until: the owner is done after \(Int(((now() - started) * 1000).rounded())) ms" }
                await sleep(seconds: Swift.min(0.25, Swift.max(0, limit - now())))
            }
            return "wait_until: the owner is not done yet after \(Int(((limit - started) * 1000).rounded())) ms; call it again, or look"
        }
        let settled = spec["settled"]?.bool ?? (spec.string == "settled")
        let text = settled && spec.string == "settled" ? nil : (spec.string ?? spec["text"]?.string)
        let gone = spec["gone"]?.bool ?? false
        guard settled || (text != nil && !text!.isEmpty) else { throw ActionFailure(message: "wait_until takes text, {text, gone?: true, ms?} or {settled: true, ms?}", delivery: .notSent) }
        let started = now()
        let limit = Swift.min(started + Swift.min(10, Swift.max(0.2, (spec["ms"]?.double ?? 3000) / 1000)), until)
        let screen = size ?? ScreenSize(width: 10_000, height: 10_000)
        let what = settled && text == nil ? "the screen held still" : "\"\(text!.prefix(40))\" \(gone ? "was gone" : "appeared")"
        func signature(_ elements: [Element]) -> String { elements.map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";") }
        // "Settled" compares two reads. The latest read, when it is fresh (the call before ended
        // within 5 s), is the first: on a slow runner (the CI simulator read in 4.5 s) two reads
        // do not fit an action's time, and the screen that matches the read before held still.
        var last: String? = settled && text == nil && lastTreeAt.map({ now() - $0 < 5 }) == true ? signature(lastElements) : nil
        var reads = 0
        // A read takes as long as the runner needs (up to readTimeout, within the action's time),
        // not the window: a phone that reads in 2.5 s still gets its answer. "Settled" gets a second
        // read past the window when the time leaves room for one. The request's own margin (0.5 s
        // past its timeout) stays inside the action's time, so the action answers for itself and
        // never runs out as "unknown".
        while now() < limit || (settled && text == nil && reads == 1 && until - now() > 1.5) {
            let room = until - now() - 0.9
            guard room >= 0.3 else { break }
            if let seen = try? await runner.tree(timeout: Swift.min(config.readTimeout, room), format: config.treeFormat) {
                reads += 1
                let elements = listable(seen.elements, screen)
                let ms = Int(((now() - started) * 1000).rounded())
                if settled && text == nil {
                    let sig = signature(elements)
                    if sig == last { return "wait_until: \(what) after \(ms) ms" }
                    last = sig
                } else if let text {
                    let present = elements.contains { $0.text.lowercased().contains(text.lowercased()) }
                    if present != gone { return "wait_until: \(what) after \(ms) ms" }
                }
            }
            if now() < limit { await sleep(seconds: Swift.min(0.25, Swift.max(0, limit - now()))) }
        }
        return "wait_until: not seen within \(Int(((limit - started) * 1000).rounded())) ms that \(what) (\(reads) reads)"
    }
}
