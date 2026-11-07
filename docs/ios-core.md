# Poki on the phone: interfaces

Poki runs entirely on the iPhone. Nothing at runtime depends on a server of ours except a relay that
carries MCP requests to the phone and stores nothing.

```
MCP client ──HTTPS──▶ Cloudflare Worker (relay) ──WebSocket (phone dialed out)──▶ Poki app
                                                                                   ├─ PokiCore (Swift): MCP, look/do, approvals
                                                                                   ├─ PokiLauncher (Rust): runner launch and keepalive
                                                                                   └─ app shell (SwiftUI): setup, Live Activity, approvals
Poki app ──TCP 10.7.0.1:* (loopback tunnel)──▶ the phone's own developer services ──▶ WebDriverAgent runner (127.0.0.1:8100)
```

Three interfaces, each owned by one side:

| Interface | Defined here, implemented by |
|---|---|
| 1. Relay frames (Worker ⇄ phone) | dev/cf-relay (Worker), PokiCore (phone) |
| 2. PokiCore Swift API | PokiCore; used by dev/ios-app |
| 3. PokiLauncher C ABI | PokiLauncher; used by PokiCore and dev/ios-app |
| 4. What the launcher needs from the loopback | dev/ios-app's packet tunnel, or the user's proxy module |

Version: 1.1 (2026-11-06: on-device pairing in §3, ToolFacts on toolFinished in §2, tunnel facts in §4, keep-alive). Every change to a section below bumps its version and is announced to the other threads.

## 1. Relay frames, v1

### Identity

- The phone makes an Ed25519 key pair once and keeps the private key in the keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- `label` = RFC 4648 base32 of the raw 32-byte public key, lowercase, no padding (52 characters).
  The same label scheme as dev/relay, so either relay can serve a phone.
- The phone makes a **connector secret**: 32 random bytes, base64url without padding (43 characters).
  Several may exist (one per MCP client); each can be revoked on the phone.
- The MCP client's URL is
  `https://pokimcp.zheha.nz/v1/<label>/<secret>/mcp`.
  The Worker never stores the secret. The phone sends only `sha256(secret)` (hex), and only on a live
  connection, so when the phone is offline the Worker knows nothing about it.

### Phone ⇄ Worker (WebSocket)

The phone opens `wss://pokimcp.zheha.nz/v1/<label>/connect`. All frames are UTF-8 JSON text frames
except the keepalive.

1. Worker → `{"t":"challenge","nonce":"<base64 32 bytes>"}` immediately after the upgrade.
2. Phone → `{"t":"hello","v":1,"key":"<base64 raw public key>","sig":"<base64 signature>","access":["<hex sha256 of secret>", ...],"app":"<app version>"}`.
   `sig` signs the bytes of `poki-relay-v1:<label>:` followed by the raw nonce bytes.
   The Worker checks that base32(key) == label and that the signature verifies; otherwise it closes
   with 4401. `access` has at most 8 entries.
3. Worker → `{"t":"ready","max_body":4194304,"req_timeout_ms":60000}`.
4. A newer connection for the same label replaces the older one (close 4000, "replaced").
5. The phone may send `{"t":"access","access":[...]}` at any time to replace the list (a secret was
   added or revoked); the Worker answers `{"t":"ready",...}` again.

Requests (Worker → phone), one per HTTP request from the MCP client:

```json
{"t":"req","id":"<opaque, unique per connection>","method":"POST","headers":{"content-type":"application/json","accept":"application/json, text/event-stream","mcp-session-id":"...","mcp-protocol-version":"2025-06-18"},"body":"<the request body as a UTF-8 string>"}
```

- Only these headers are forwarded, lowercased, when present: `content-type`, `accept`,
  `mcp-session-id`, `mcp-protocol-version`, `last-event-id`. Never `authorization` or cookies, and
  never the client's IP.
- Methods: `POST`, `GET`, `DELETE`.

Responses (phone → Worker):

```json
{"t":"res","id":"<same id>","status":200,"headers":{"content-type":"application/json","mcp-session-id":"..."},"body":"<UTF-8 string>"}
```

- The phone answers every request exactly once. PokiCore answers MCP POSTs with
  `application/json` (no SSE), `GET` with 405, and `DELETE` with 200 after ending the session.
- Bodies are at most `max_body` bytes either way; the Worker answers 413 to a larger request, and the
  phone never sends a larger response (screenshots are JPEG, about 20 to 60 kB).
- `{"t":"cancel","id":"..."}` (Worker → phone) when the client went away; the phone may stop the work
  and must not send a `res` for it afterwards.

Keepalive: the phone sends the text frame `ping` (the bare word, not JSON) every 25 s; the Worker
answers `pong` with `setWebSocketAutoResponse`, so a hibernated Durable Object is not woken. The phone
reconnects with backoff (1, 2, 4 … 30 s, jittered) when no `pong` arrives for 60 s.

### What the Worker answers the MCP client itself

| Case | HTTP |
|---|---|
| Unknown label, or secret hash not in `access` (indistinguishable) | 404 `{"error":"not found"}` |
| Phone not connected | 503 with a JSON-RPC error body: `{"jsonrpc":"2.0","id":<request id or null>,"error":{"code":-32001,"message":"The phone is offline: open Poki on the phone, or check its network."}}` |
| No `res` within `req_timeout_ms` | 504 with the same JSON-RPC shape, code -32002 |
| Rate limit | 429 with the JSON-RPC shape, code -32003 |
| Body over `max_body` | 413 |

### Limits (cost)

The account is on Workers Paid, so overage can bill. The Worker keeps hard caps (exact numbers are
dev/cf-relay's): requests per label per minute, concurrent requests per label (PokiCore handles one tool
call at a time; 4 in flight is plenty), body size, and connections per label (one). The Worker stores
nothing: no KV, no D1, no Durable Object storage writes, and no logs of headers, bodies or IPs. The
Durable Object keeps only the hello's `access` list and label in the WebSocket attachment.

## 2. PokiCore Swift API, v1

A Swift package (`native/ios/PokiCore`) with no UIKit or SwiftUI dependency. It builds and tests on
Linux; iOS-only parts (JPEG encoding, keychain) come from the host protocol.

```swift
public struct CoreConfig: Sendable {
    public var relayURL: URL                 // wss://pokimcp.zheha.nz/v1
    public var runnerURL: URL                // http://127.0.0.1:8100
    public var sensitive: SensitivityRules   // what needs approval; see below
    public var approvalWait: Duration        // how long do() holds for an approval before answering (default 20 s)
    public var toolDeadline: Duration        // hard cap per tool call (default 25 s)
}

public protocol CoreHost: AnyObject, Sendable {
    /// Signs relay challenges with the device key (keychain on iOS).
    func signingKey() throws -> RelayKey
    /// The connector secrets' sha256 hashes, hex.
    func accessHashes() -> [String]
    /// A JPEG of the PNG screenshot scaled to `width` points (ImageIO on iOS).
    func jpeg(fromPNG png: Data, width: Int, quality: Double) throws -> Data
    /// The runner launcher's state; PokiCore asks for a restart when the runner stops answering.
    func runnerState() -> RunnerState
    func restartRunner()
    /// Text read from the screenshot, for elements an app collapsed. Optional: PokiCore's default
    /// answers it with Vision (VNRecognizeTextRequest), so the app need not implement it.
    func recognizeText(inPNG png: Data) async -> [RecognizedText]?
    /// A screenshot apart from the runner (the launcher's tunnel: the DVT screenshot service, or
    /// simctl on the simulator), asked for only when the runner gives none. Default nil.
    func screenshotWithoutRunner() async -> Data?
}

public final class PokiCore: Sendable {
    public init(config: CoreConfig, host: CoreHost)
    public func start()                       // connect to the relay, keep it connected
    public func stop()
    public var events: AsyncStream<CoreEvent> { get }
    public func resolveApproval(id: String, approved: Bool)
    public func handoffDone(id: String)       // the owner tapped Done on a step the model handed to them
    public var handoff: Handoff? { get }      // the step still waiting, if any (id, kind, text, requested)
    public func handle(_ request: RelayRequest) async -> RelayResponse   // also for local tests
}

public enum CoreEvent: Sendable {
    case relay(RelayState)                    // connecting, ready, offline(reason)
    case toolStarted(ToolActivity)            // name, summary ("tap 'Send'"), started
    case toolFinished(ToolActivity, ToolOutcome, ToolFacts)   // ToolFacts: app name, ~96 px JPEG thumbnail
    case approvalRequested(Approval)          // id, app, summary, expires
    case approvalEnded(id: String, approved: Bool?)  // nil: expired
    case handoffRequested(id: String, kind: String, text: String?, app: String?)  // kind: passcode | password | verification | payment | other
    case handoffEnded(id: String, how: String)       // "done" (the owner tapped Done) or "takenBack" ({handoff: false})
}
```

`CoreConfig.accessibilityDeadline` (2 s) is WDA's check that the app's main loop answers before a
tree is read; 0 turns it off (`POKI_AX_DEADLINE` in the simulator check compares both).

`ToolFacts.thumbnail` is a JPEG about 96 pixels wide (a few kB). ActivityKit's content state is
limited to 4 kB, so the app writes the thumbnail to its app group and the Live Activity reads it from
there.

The app shell maps `events` to the Live Activity and resolves approvals from the Live Activity's
buttons (App Intents). The automation can never grant an approval. A `do` with other actions first
withdraws the pending request, before anything of it is sent, so a tap on the Live Activity's Approve
button lands on a request that is already gone. Only the same actions, sent again, wait for the
decision.

### Tools

The computer-use profile, ported from `src/cua.mjs` and `src/cua-wda.mjs`:

- `look {full?}`: read the screen now.
- `do {actions: [...], full?}`: run actions in order, then read the screen.
- `status`: the relay, the runner and pending approvals, without touching the device.

Each answer is facts only: the app in front, numbered elements, what each action did (`sent`,
`not_sent`, `unknown`), timings and a JPEG screenshot. No verdicts.

- **Numbers stay.** An element still on screen in the next read keeps its number (same text and frame
  first, then same text); a new screen (another app, or under 30% of the elements kept) numbers from
  1 again, and its heading says so (`a new screen: numbered from 1 again, the numbers of the read
  before no longer apply`). `do` lists only the new (`+`) and moved (`~`) elements and says how many others kept their
  numbers; `look` and `full=true` list everything.
- **`screen_changed`** in every `do`: whether the elements, or only the picture, differ from the read
  before, so a no-op action is visible at once. The picture is compared as a 32 by 64 grid of grey
  levels, and counts as changed when over 1 % of the cells move by more than 12 of 255: a cursor
  blinking or the clock ticking is not a change; a sheet, a photo or a page coming in is. A
  picture-only change says how much and where (`in 3 % of it, within [372, 110, 13, 690]`), so the
  long scroll indicator iOS draws beside a two-page list fading out (seen on the simulator after a
  drag: 2-3 % in a strip at the right edge) reads as what it is without a look at the picture.
- **The picture and the tree are of the same moment.** The screenshot is taken first (served apart
  from WDA's queue) and the tree after it; when the tree came over 0.6 s later and time is left, the
  picture is taken again after it (`note: the picture was taken again after the tree, which came
  1,400 ms later than the first picture`), so a list and the chat opened from it are never shown as
  one screen (seen on the phone in WeChat).
- **An element that fills the screen** (80 % of it or more: a web view, a feed's container) is tapped
  at its centre, and the answer says so (`this element fills the screen, so the tap went to its
  centre at [201, 437], whatever is drawn there; tap a smaller element, or a point on the picture`).
- **The home screen is named**: a read with SpringBoard in front says `app: Home screen
  (SpringBoard: the home screen, the App Switcher, a banner or a system alert)`. WDA takes the app
  under its "active app detection point" as the one in front; the default is near the top left
  corner, under every banner and the Dynamic Island, so a banner made WDA dump SpringBoard's tree
  instead of the app's (seen on the phone in JD). Each session moves the point to (200, 420), the
  middle of the screen.
- **The screenshot is one pixel per screen point** (402 px wide on a 402-point iPhone 17 Pro), and the
  answer says so: a point on the picture is a point to tap.
- **Lean lists.** Text an element around it already says (a post's text and then each of its lines),
  scroll bars, and holders that say what the button inside them says are left out; labels over 160
  characters are cut. `full=true` lists the tree as it is.
- **Collapsed elements.** An element with a long label and nothing listed inside it (X shows a reply,
  its buttons included, as one cell) is marked `[collapsed]`. `full=true` adds the text Vision reads
  inside it as numbered `Text` elements (`(read from the picture)`), which can be tapped.
- **No tree in time.** When the runner's tree misses the read's time (a cold app, a keyboard coming
  up: over 4 s on the CI simulator) but the screenshot came, the text Vision reads in the whole picture
  is listed instead, numbered and tappable at its centre, under a heading that says so. When that
  yields nothing, the read's note says why: no text found, the text could not be read, or the reading
  did not finish in time (with its milliseconds).
- **Taps are hit-tested, never held back.** A numbered element is touched at its centre, or, when
  the centre is off screen or under a bar or a later element in the tree (a reply bar), at the nearest
  point of it that is free, and the answer says where and what the tree puts over it. When no point of
  it is free it is still touched, at the centre of its visible part, with a note to see whether it
  took: the tree's order is not the drawing order (seen on the phone: Photos' Select button came after
  the photo grid in the tree and was refused). What scrolls inside a list never counts as covering
  what is outside the list. Only an element with no part on the screen, or a point off it, is
  `not_hittable`, and nothing is sent then.
- **Gestures.** `swipe` is a quick flick inside the biggest list on screen (or `in: n`), clear of bars
  and anything drawn across it, away from the screen's system edges. `drag` moves at its own speed
  (`ms`, default 400) and rests 150 ms before lifting, so the list stops where the finger stops
  (`hold_ms` first to pick something up). `scroll_to` uses resting drags and counts a target under a
  bar as not there yet. All three use WDA's `pressAndDragWithVelocity` (a runner without it gets
  `dragfromtoforduration`), with a gesture's own time limit that is not counted as a runner miss.
- **WDA's waits are off.** Each new session sets `animationCoolOffTimeout` 0 and `waitForIdleTimeout`
  0.5 s. WDA otherwise waited up to 2 s after every gesture for the app to hold still, and up to 10 s
  before events for it to be idle, which an app that never stops animating used in full (2.3 to 4.3 s
  drags in X). Poki's own short pause before the read stays.
- **Typing** is key presses first (`/wda/keys`, the whole text in one request; CJK, kana, Hangul and
  digits are read back exactly in the tests), and every `type` says what the focused field holds
  afterwards (`the field now reads "…"`, or only its length for a password). `via: "paste"` is the
  backup the model may choose: PokiCore reads the owner's clipboard first (unreadable: nothing is
  pasted), puts the text on it, reads it back (a write that did not take answers `not_sent`, with
  "type the text instead"), opens the field's edit menu with a long press, taps Paste (the word in
  12 languages) and watches the field for the text. The owner's clipboard goes back once the text
  has landed, or after 45 s: an app's first paste from the runner makes iOS ask the owner to allow
  it, and putting the clipboard back before the owner answers pastes the owner's own text (seen on
  the phone, Nov 7 2026 12:30 am ET: the owner's clipboard went into JD's search box). While the
  field has not shown the text the answer says `iOS may be asking the owner to allow the paste`.
- **`clear: true` is checked**: when the field still holds something besides the text afterwards
  (the cursor was not at the end; a field that reports its placeholder as its value), the element is
  cleared through WDA once (3 s) and the text typed again; the answer says so.
- **Typing waits for a field to be focused** (polled every 150 ms, up to 2 s): a tap takes a moment
  to focus a field, and a search field that animates in focuses late. None focused: the text is
  typed anyway and the answer says `no field was focused when the text went`.
- **`{back: true}`**: the top-left button of the last read (a navigation bar's back button) is
  tapped, else an edge swipe from the left is sent; the answer says which. No app-specific rule.
- **The same element twice** (same type, text and frame, as an app that mirrors a control into a
  second accessibility element) is listed once.
- **Hand-off to the owner, by the model's judgement** (`{handoff: {kind, text}}`, kind one of
  passcode, password, verification, payment, other): a step the model will not do itself (a password,
  a human verification, a checkout it was told to leave) is shown on the phone in the Live Activity
  with a Done button (`handoffRequested`). Until the owner taps Done (`handoffDone(id:)`) or the model
  sends `{handoff: false}`, no input is sent (`not_sent`, with the picture, so the model is never
  blind), every `look` works, `status` shows `handoff: waiting (kind) since …`, and `{wait_until:
  {handoff_done: true, ms?}}` waits up to 10 s. The model is told to keep polling and go on with the
  task rather than end its work; the `handoff: done at …` line is reported once. When the model
  stands down is its own call (the owner, Nov 7 2026); PokiCore decides nothing but the sensitive
  actions above.
- **Never an answer that halts the model** (the owner's rule, Nov 7 2026): while the runner is up
  and a screenshot comes, every `look` and `do` answers with the picture and something to go on, and
  `isError` is set only when nothing could be read or nothing at all was sent. A failed action with a
  read, a stale number, a busy runner (the picture comes with `not_sent`), a runner that is starting
  (the first start after a restart can wait for the owner's passcode; the answer says to call again
  every few seconds) are plain answers. With no tree, the text read from the picture is listed and
  tappable, and the note says to tap points on the picture or call look again.
- **Locked phone**: `do` checks `/wda/locked` first and sends nothing but buttons while locked
  (`screen: locked`); `look` says so too. Unknown counts as unlocked.
- **Approvals**: the owner's time on an approval does not count against the actions or the read;
  a `do` that waited for one may take up to `toolDeadline + approvalWait` (about 46 s), and one
  that had to wait for the runner to start adds that wait too (at most `runnerWait`, 15 s).
- **Poki's own screen is never worked in by mistake**: a tap near the top of the screen can land on
  Poki's Live Activity in the Dynamic Island, and the owner's answer to an approval can open Poki
  (seen on the phone, Nov 6 2026 10:35 pm ET: `Tap "Back"` and `Tap "All Inboxes"` answered
  `app: Poki`). The Dynamic Island (the top 64 points, middle half of the width) is never listed.
  After an approval, and after the read that follows the actions, Poki in front where another app
  was being worked in means that app is activated again (`note: Poki was in front …; Mail was
  brought back`) and the read is made again; the model never sees Poki's screen as the result of
  a tap. Working in Poki on purpose (the last read showed Poki) is left alone. The app's bundle id
  is `CoreConfig.ownBundleID`.
- **`wait_until`**: `{wait_until: "text"}`, `{wait_until: {text, gone: true, ms}}` or
  `{wait_until: {settled: true, ms}}` reads the tree every 250 ms until the text appears or goes, or
  two reads match (default 3 s, at most 10 s, within the action time). Not seeing it is reported, not
  an error. There is no "paused" line after a wait.

### Deadlines (no hangs)

- Every runner HTTP call has its own timeout (reads 4 s, taps 3 s, typing 3 s plus 60 ms per
  character, launches 8 s), every action has its own action time (`actionCap`, 6 s, from when it
  starts; a launch 9 s), and the whole tool call has `toolDeadline` (25 s, the actions and the read
  together). The action time starts when the actions do, after the runner's start and the lock
  check (seen on the phone: a launch sent while the runner was starting had its time used up
  before it went, and a batch of Home, tap and drag had 6 s for all three).
- At the deadline the tool answers anyway, saying which step did not finish and whether it may
  have been delivered, plus the last good read if any. A late runner answer is dropped.
- Two refused or broken runner requests in a row mark the runner unhealthy: PokiCore calls
  `host.restartRunner()`. Two timeouts in a row only start a `GET /status` probe in the background
  (up to 15 s): WDA serves every request on its main thread, so one slow read (a cold app's first
  tree, a keyboard coming up) makes the requests queued behind it time out too. A runner that answers
  the probe is busy, keeps its session and is not restarted; one that answers nothing is restarted.
  (Found on the CI simulator, where the first tree after a launch or a keyboard took over 4 s.)
- Each session sets WDA's `accessibilityDeadline` to 2 s: a tree read of an app whose event loop does
  not answer in that time fails at once instead of holding WDA's main thread (and every request queued
  behind it, screenshots and Home included) for half a minute. Seen on the simulator with the
  keyboard's looping slide-to-type introduction. A call that finds the runner `.starting` (restarting, or woken from idle by
  the app) waits for it, checking every 250 ms for up to `runnerWait` (15 s) within its deadline, then
  goes on; a `.failed` runner is answered at once with its fix.
- **Reads need no session.** `/source` and `/wda/activeAppInfo` are served outside a session (queued
  on WDA's main thread all the same), so a `look` never waits on a session open, and a session ended
  after a slow action costs the next read nothing. WDA's settings (the deadline, the detection
  point, the depth) live in its process: the first session of the runner's life sets them, and a
  restarted runner gets them again. Actions still run in the one session.
- **A huge tree backs off in depth.** `snapshotMaxDepth` starts at WDA's 50; after a read that timed
  out the next read asks for half the depth (never under 12, set through the session's settings) and
  says so (`the tree was read to depth 25 …`); a read that came within 1.5 s restores the depth for
  the one after it. A refused snapshot (the app's main loop busy for the moment) is asked for once
  more within the read's time.
- **A moving screen is marked.** When the tree came over 0.6 s after the picture, the picture is
  taken again and compared with the first; if they differ the note says `screen: moving (N % of it)`
  and tells the model to prefer scroll_to, wait_until and element numbers over [x, y] taps.
- **An action this side gives up on ends the session; a read keeps it.** WDA serves every request
  but a few (status, screenshot, ending a session) one after another on its main thread, and goes on
  serving a request after the client has stopped waiting. Seen on the phone: a feed's tree took
  longer than a read, and the swipes and taps sent after it waited their turn behind it and landed
  long after the agent had reported them failed. So when an action (or a session open) times out or
  is cut off by its action time, PokiCore sends `DELETE /session` at once (answered apart from the
  queue): WDA answers everything still queued for that session with "session does not exist" instead
  of running it, and the request it is serving is the last thing it does for it. A read (`GET`) that
  times out keeps the session: nothing behind a read can act, and ending the session only put the
  next session open behind the same slow read (seen on the phone, Nov 7 2026 12:35 am ET: every look
  in WeChat opened a session that queued behind the read before it, and the session count climbed
  while the reads kept failing). Before the next action PokiCore checks that the runner is through
  (a cheap queued request answered in time); a `do` whose turn does not come within the action time
  answers `not_sent: the runner is still finishing an earlier GET /source from 9 s ago` without
  sending anything, and a `look` says the same in its note and shows the picture (screenshots are
  served apart from the queue). The next queued request that is answered clears the note. An action
  cut off after it reached the runner is `unknown`; one cut off while the session was still being
  opened is `not_sent`.
- **A wedged runner is restarted on its own.** An app whose main loop hangs holds WDA's queue, and
  every read, action and screenshot behind it, while WDA's own `GET /status` still answers, so the
  health probe sees nothing wrong (seen in the CI gym, Nov 7 2026 2:30 am ET: a 3,000-element
  screen held one `GET /wda/activeAppInfo` for 75 s; every call answered "still finishing an
  earlier" and the screenshot timed out too). A stall older than 15 s (`Runner.wedgedAfter`) with a
  cheap queued probe (3 s) unanswered is a wedge: PokiCore forgets the runner and asks the host to
  restart it, and the first call that goes through starts with `runner: the runner wedged on GET
  /wda/activeAppInfo (unanswered for 18 s), so it was restarted at 02:31:05; this is the new runner`
  (reported once; a call while it is still starting says the same above `runner: starting`). The
  busy note says so ahead of time: `… from 7 s ago (the runner is restarted on its own if it is not
  through in 15 s)`. A stall never outlives the runner process: a refused connection, a restart
  PokiCore asked for, or a runner the host reports as starting clears it (seen in the gym: the first
  `do` after a restart still waited on the old runner's request). A busy, hand-off or
  "another call is running" answer that says what to do next is not an error even when the runner
  gives no picture.
- **Focus is read from the tree, never asked of the runner.** WDA's focus query (`GET
  /element/active`, an XCTest query for the element with keyboard focus) hung the CI simulator's
  runner for 19 s on the keyboard's first-use intro, and every request queued behind it went down
  with the runner (Nov 7 2026, 3:40-4:05 am ET, three runs). Typing now waits for the keyboard to
  be listed in the tree (a sessionless read every 150 ms, up to 2 s), reads the field back from
  the tree (the field under the tapped element, else the one holding the text, else the only one),
  and `clear: true` re-clears with deletes, never WDA's element clear. The note when no keyboard
  came: `no field was focused when the text went (no keyboard came up in 2000 ms), so it may have
  gone nowhere`. Paste finds the field's frame the same way.
- **The screenshot is asked for again when the tree came late.** A read whose tree came on its
  second try (a runner that was busy, or restarted) but whose picture, taken beside the first
  try, did not, asks the runner for the picture again (1.5 s) before the host's own path.
- **A tree that times out is read again shallower within the same call.** A full-depth read that
  times out (4 s) is followed, once the runner is through with it (a queued probe answered), by a
  read with smaller snapshot limits within the call's remaining time: first at most 150 children
  per element (WDA's `snapshotMaxChildren`; a dense screen is wide, not deep: the gym's 1,500
  cells are siblings, so depth alone did not help), then half the depth (never under 12) with half
  the children (never under 60): `the full tree timed out (…), so it was read again with at most
  150 children per element within this call; a long list shows its first 150 rows only (scroll_to
  finds the rest)` (seen in the gym, Nov 7 2026 3:05 am ET: the 1,500-cell screen timed out twice
  and the look answered nothing, 8-9 s per call). The next read starts at those limits and a fast
  read doubles them back toward the full tree.
- **A web view with nothing of its page in the tree is listed all the same.** WebKit's parts reach
  the tree late or not at all under a reduced depth (seen in the gym: three looks at a WKWebView
  listed the nav bar and nothing of the page). A WebView element is listed even with no text, as
  `WebView "web page (its parts are not in the tree yet: read again in a second)" [collapsed]`, and
  the picture's text inside it is listed in every look, not only `full=true` (the gym showed the
  parts arrive 3-4 s after the page loads).
- **A scroll that outruns its time says how far it got.** `scroll_to` has 12 s (not an action's
  6 s: with the progress answer it cannot stall the model) and reads the tree after every swipe (a
  blind swipe can carry the target past the screen; an element search on the runner is a full
  snapshot too, no faster: seen in the gym, where the gesture itself is most of a swipe's 2.5-3 s).
  Up to 12 swipes per call (`max_swipes` up to 15). When under 1.6 s is left it stops where it is: `4 swipes, "Row 250" not
  seen yet; the action's time ran out before the list was through (12 s): call scroll_to again to
  go on from here` (seen in the gym: 200 rows answered "(unknown) … may have been delivered"). A list
  that stops moving says "its end, or the text is not in it"; the swipe limit reached says to call
  again (`max_swipes` up to 12).
- **An answer is never lost to a relay drop.** A call keeps running when the relay connection
  resets under it (seen on the phone: a three-action `do` answered "what was sent is unknown" when
  the tunnel reset mid-call, though the actions had gone). Its answer cannot go to the connection
  that is gone, so it is kept (the last three) and put in front of the next call's answer: `earlier,
  never delivered to you: the do call whose connection dropped (finished at 00:31:12): …` then
  `now:` and the new answer.
- A plain `launch` activates the app (to the front as it is, or started if not running); only `fresh:
  true` ends it and starts it through XCTest's launch, whose handshake takes several seconds on the
  phone (a Photos launch hit the 6 s action time there). A launch action gets 9 s of action time,
  from when it starts.
- Buttons (Home, lock, volume) get 8 s and a slow answer does not count as a runner miss. WDA's
  `/wda/homescreen` waits for SpringBoard to come up and go idle before it answers: about 3 s on the CI
  simulator (a 3 s timeout failed there), and it holds WDA's main thread the same way on a phone, where
  SpringBoard's transition animation runs at full length. 8 s is a ceiling, not a wait: on the
  simulator Home answered in 0.6 to 2.9 s.

- One tool call runs at a time per phone. A second one waits at most 2 s, then answers `busy` with what
  the first is doing.

### The element tree's form

`treeFormat` picks `GET /source?format=xml` (the default) or `format=json`, both with
`visible, accessible, enabled, index` excluded. WDA's JSON tree adds every element's custom actions
(`customActions`), fetched from the accessibility server one round trip per element whatever is
excluded, so a big tree (a feed, a keyboard) costs hundreds of round trips; its XML tree leaves them
out unless asked (`includeCustomActionsInPageSource`). The XML is parsed with Foundation's XMLParser
into the same elements. The CI simulator job runs the checks with both and prints both tables. Run
42320256495 (Settings, read time of the tree and screenshot together): warm look 0.26 to 0.44 s XML
against 0.63 to 0.71 s JSON; with the keyboard up 0.28 s against 2.0 s; the first read after a fresh
launch 1.1 s against 5.9 s; after typing 0.46 s against 3.1 s. The phone has not been measured with
XML yet.

### Measured on the CI simulator (run 42258166342)

iOS simulator on a GitHub macos-15 runner, WebDriverAgent 16.15.3, Settings. One run, every check
passing; numbers are milliseconds for the whole MCP call. The phone is expected to be faster (no
virtualisation, Neural Engine for Vision) but has not been measured with these builds.

| call | ms | of which |
|---|---:|---|
| look, warm | 833 to 1308 (tool 1218 to 1446) | tree + screenshot read |
| swipe / drag | 2745 to 3016 | gesture sent 1.0 to 1.4 s, 350 ms pause, read 0.9 to 1.1 s |
| scroll_to Privacy | 1285 | |
| no-op wait (300 ms) | 1033 | |
| wait_until settled | 2803 | at least two reads |
| Home | 4247 | sent 648 ms, 700 ms pause, read 2.5 s (SpringBoard) |
| type "Wi-Fi 你好 123" | 17044 | typed and read back in 4.5 s; the read after it hit the keyboard's slow first tree (4.6 s) and Vision ran out of time (3.9 s) |
| launch Settings fresh | 14946 | cold app: no tree within 4 s |
| Vision on a whole screenshot | 4069 | 18 texts, no Neural Engine on the runner |

Floor against the budget (look under 1.5 s; a do step under 1 s plus settle): a warm look meets it
(0.8 to 1.3 s read). A gesture step does not on the simulator: WDA takes 1.0 to 1.4 s to send a
swipe or drag (its synthesised touch runs its full duration on the main thread), before the settle
pause and the read. The first read after a keyboard or a cold launch is over 4 s on the simulator
and falls back to the picture.

### Sensitive actions

`SensitivityRules` (user-editable in the app, sensible defaults):

| Rule | Default |
|---|---|
| Typing into a secure text field | approval |
| Tapping an element whose label starts with a payment word, or is a short label (four words or fewer) holding one (Pay, Buy, Purchase, Subscribe, Transfer, Send money, 支付, 付款, 购买, 转账, …); a name inside a longer text is not an action (`Contact photo for Best Buy`) | approval |
| Deleting (Delete, Remove, Erase, Reset, 删除, 移除, 抹掉, …) | approval |
| Sending a message or mail (Send, 发送 in Messages, Mail, WeChat, WhatsApp, Telegram, …) | approval |
| Apps on a list (banking, wallets; by bundle id) | approval for every input |

When an action matches, the plain actions before it in that `do` are sent first (seen on the phone:
a last selection tap held back with the Delete after it meant the Delete, once approved, would have
missed a photo), and from the first matching action on nothing is sent. PokiCore emits
`approvalRequested` for those and holds up to `approvalWait`. If approved in time, they run and the
answer says `approved on the phone`. If not, it answers `not_sent from action k: approval_required (id
…)` after the read, saying which actions were sent, and those from k on, sent again on their own in a
later `do` within 2 minutes, run once that approval is granted. Denied: `not_sent … the owner
declined`.

## 3. PokiLauncher C ABI, v1

A Rust static library (`native/launcher`, crate `poki-launcher`, `staticlib`) on idevice. It gets
the runner up and keeps it up. Header `poki_launcher.h`:

```c
typedef struct PokiLauncher PokiLauncher;
typedef void (*poki_launcher_event_cb)(void *context, const char *event_json);

// config_json: {
//   "device_address": "10.7.0.1",
//   "pairing_file": "/path/in/app/container",    // RPPairing (remote pairing) or lockdown pairing plist
//   "host_name": "Poki",                        // optional; the name the pairing was made with
//   "ddi_dir": "/path/to/ddi",                  // Image.dmg, BuildManifest.plist, Image.dmg.trustcache
//   "runner_bundle": null,                      // null: the installed app whose id contains WebDriverAgentRunner and xctrunner
//   "wda_port": 8100
// }
PokiLauncher *poki_launcher_new(const char *config_json, poki_launcher_event_cb cb, void *context);
int  poki_launcher_start(PokiLauncher *launcher);     // 0 = started; runs on its own threads
void poki_launcher_restart(PokiLauncher *launcher);   // drop the session and launch again
void poki_launcher_stop(PokiLauncher *launcher);
char *poki_launcher_status(PokiLauncher *launcher);   // JSON, free with poki_string_free
void poki_string_free(char *s);
void poki_launcher_free(PokiLauncher *launcher);
```

On-device pairing (iOS 27, like StikPair). Poki plays the "pairable host":

```c
typedef struct PokiPairing PokiPairing;
// config_json: {"host_name": "Poki", "out_path": "<app container>/pairing.plist", "identity_path": "<app container>/pairing-host.key"}
PokiPairing *poki_pair_start(const char *config_json, poki_launcher_event_cb cb, void *context);
void poki_pair_cancel(PokiPairing *pairing);   // stops it if running, and frees it
```

Events, in order:
- `{"event":"advertise","service_type":"_remotepairing-pairable-host._tcp","instance":"<id>","port":n,"txt":{"name","identifier","authTag","model","flags","ver","minVer"}}`.
  The launcher listens on that TCP port; the app publishes the service with Bonjour (NetService or
  NWListener's service, with `instance` as the name and the TXT record). It needs
  `NSBonjourServices` = `_remotepairing-pairable-host._tcp` and `NSLocalNetworkUsageDescription`.
- `{"event":"pin","pin":"123456"}`: show it (Live Activity). The person types it on the phone.
- `{"event":"paired","path":"…"}`: the RPPairing file is saved; give it to `poki_launcher_new` as
  `pairing_file`.
- `{"event":"failed","detail":"…"}`.
`identity_path` keeps the host's 16-byte identity, so the phone recognizes Poki next time. One
pairing per call.

Events (and `status`) are JSON:
`{"state":"…","detail":"…","attempt":n,"since_ms":…,"ios":"26.1","pairing":"remote|lockdown"}`, with
state one of `idle`, `connecting`, `pairing`, `tunnel`, `mounting_ddi`, `launching`, `running`,
`waiting_network`, `failed`. `failed` carries a `fix` the app can show (for example "Turn on the
loopback in Shadowrocket: Settings → Other → Include route 10.7.0.1/32").

What it does:

1. Connects to `device_address`: RemotePairing on 49152 (RPPairing file), or lockdown on 62078
   (lockdown pairing plist) and then CoreDeviceProxy. The pairing file decides which.
2. Opens the CDTunnel in-process (userspace TCP/IP), then RSD.
3. Mounts the personalized DDI from `ddi_dir` if it is not mounted (needs internet once per boot for
   Apple's TSS signature).
4. Launches the runner via testmanagerd and dtservicehub, and holds those connections.
5. Watches the runner (`GET /status` on 127.0.0.1:`wda_port` every 5 s); after 2 misses, or when the
   session drops, it relaunches with backoff. It never exits by itself.

The launcher's process must stay alive for the runner to stay alive (the runner dies 23 to 32 s after
the session's connections close). Keeping the app alive in the background is the app shell's job
(a silent `AVAudioEngine` with `mixWithOthers`, plus the Live Activity); see `docs/single-bundle.md`
for one IPA vs two. The supervisor runs on its own thread with a single-threaded runtime;
callbacks arrive on that thread.

## 4. What the launcher needs from the loopback

Only this: TCP from the app to `10.7.0.1` on any port comes back to the phone itself, with source and
destination swapped. The phone needs nothing else from it: no UDP, no IPv6, no DNS, no default route,
no other addresses. The ports used are 49152 or 62078, plus one dynamic tunnel port per session that
the phone picks.

- The built-in packet tunnel (dev/ios-app): interface address 10.7.0.2/24, includedRoutes 10.7.0.1/32
  only, IPv4 only, no DNS settings, no IPv6, MTU 1500. Every packet to 10.7.0.1 goes back with source
  and destination swapped.
- Surge / Loon: `10.7.0.1 = reflect` with the route included and IPv6 VIF off. sing-box:
  `loopback_address: ["10.7.0.1"]`. Shadowrocket: "Include route 10.7.0.1/32".
