# Note for Joseph's agent: the phone-side MCP (PokiCore look/do) and how it could unify with Poki's MCP

Written Nov 7 2026, 1:30 am ET, after three rounds of owner tests on an iPhone 17 Pro (iOS 27.3 beta,
Mail, X, JD, WeChat). Zhehan is away and cannot test further builds; everything here is on the
branches so you can pick it up.

## What this is

`native/ios/PokiCore` is a Swift package that turns an on-phone XCTest runner (a Poki-branded
WebDriverAgent 16.15.3, `dev/wda-runner`) into two MCP tools, served by the Poki iOS app itself over a
relay (Cloudflare Workers, `dev/cf-relay`; the relay stores nothing and only forwards):

- `look` reads the screen: the app in front, numbered interactive elements (from the accessibility
  tree, XML), and a screenshot whose pixels are screen points.
- `do` runs a batch of actions (tap by number, text or point; type; swipe; scroll_to; button; launch;
  wait_until) and then reads the screen again, listing only what changed and a `screen_changed` line.

No model runs on the phone. The calling agent decides what happened from the elements, the picture and
the facts in the answer; PokiCore never returns a verdict. Sensitive actions (pay, delete, send, a
password field) are held for the owner's approval in a Live Activity.

Full behaviour: `docs/ios-core.md` (this repo root). Things proven only on the simulator:
`native/ios/PokiCore/UNVERIFIED.md`.

## Where the branches stand

- `dev/ios-core`: PokiCore (this package, tests, CI `ios-core.yml`: unit tests on Linux, a simulator
  check on a macOS runner that drives Settings and the keyboard through the real runner).
- `dev/ios-app`: the Poki app (pairing, Live Activity, approvals, runner wake), merges `dev/ios-core`.
- `dev/wda-runner`: the runner. `dev/cf-relay`: the Workers relay. `dev/cua-agent`: the look/do
  profile and the agent-side instructions.

## What the owner's tests found, and what this round fixed (MCP side)

Round 3 (JD and WeChat, Nov 7 12:21 to 12:45 am ET) was the first real multi-app run. Fixed on
`dev/ios-core` in this round, each with a unit test:

1. The owner's own clipboard was pasted into JD's search box: iOS's "Allow Paste" prompt was still up
   when PokiCore put the owner's clipboard back. Now the clipboard is verified after the write and put
   back only once the field shows the text (or after 45 s).
2. Tree reads came back as the Home screen while an app was in front: a banner sat on WDA's "active
   app detection point" (top left). The point is now the middle of the screen.
3. Every failed `look` in WeChat opened a new session that queued behind the slow read before it. A
   read that times out now keeps the session; only an action that times out ends it (so nothing
   queued runs late).
4. A three-action `do` was answered "unknown" when the relay reset mid-call. The call now runs to the
   end and its answer is delivered in front of the next call's answer.
5. The tree and the picture could be from different moments. The picture is retaken when the tree
   came over 0.6 s later.
6. A tap on a full-screen container went to its centre silently; the answer now says so. A new
   screen says its numbers start from 1 again.

Not done (out of scope or not yet): a `back` action, a `collect` or `expect` field, a health line
in every answer, a `recover` action, de-duplicating repeated elements, `clear: true` verification,
waiting for focus before typing, and redaction of sensitive text (Zhehan: out of scope for now).

## How the two MCPs could unify

Poki upstream's MCP (Node, `src/`) and this one serve the same agents with different reach: yours
drives the phone from a Mac through the developer connection; this one drives it from the phone and
needs no computer. The agent-facing contract can be one:

- **Adopt look/do as the two tools**, with the answer shape PokiCore uses: `app:` line, numbered
  elements that keep their numbers across reads, `screen_changed`, per-action `sent | not_sent |
  unknown` with a time, a note line for anything odd, and the picture at one pixel per point. Agents
  trained on one would then work on both. The exact strings are in `docs/ios-core.md`, and the tests
  in `Tests/PokiCoreTests` pin them; a Node implementation can be checked against the same fixtures.
- **Keep the facts-only rule**: no verdicts, no task-specific heuristics, the model decides. That is
  what let a first-time agent do a Mail task in 9 s on the phone.
- **Phone-only pieces** stay in the app: approvals through the Live Activity, the runner's wake and
  loopback, the relay, the "Poki was in front; app brought back" rule. A Mac-side MCP has the dev
  connection and so can also offer what the phone cannot (installs, logs, a fresh runner).
- **Shared pieces** worth lifting into one module (Swift here, portable logic): element numbering and
  matching across reads, the picture-change grid, the sensitivity rules (payment and deletion words
  in 12 languages), paste with clipboard restore, and the deadline rules (per-action cap, read
  timeout, session handling around WDA's single-threaded queue).

Open questions for you: whether upstream wants the XML tree (what PokiCore reads; faster than JSON on
WDA) or keeps JSON; whether the relay should be the one entry point for both (an agent on the Mac
could also go through it); and the `back` action, which needs a per-app answer (navigation bar
button, edge swipe, Android-style key does not exist on iOS).
