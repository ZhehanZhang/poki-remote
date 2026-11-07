# Poki on the iPhone, standalone: where it stands (Nov 7 2026, 1:40 am ET)

A note for Joseph and anyone picking this up. Written by the app thread of ZhehanZ's fork
(ZhehanZhang/poki-remote); the work lives on the `dev/` branches named below.

## What this is

Poki running with no Mac and no server in the loop. The iPhone runs three pieces of ours:

- **Poki** (`native/ios-app`): SwiftUI app. Setup, on/off, Live Activity with Allow/Deny for
  sensitive actions, the MCP address for each client, a Debug tab with the log.
- **Poki Runner** (`native/ios-runner`): WebDriverAgent 16.15.3 as an XCTest runner, branded,
  plus `PokiRunnerHost` (an injected dylib) that draws its screen. Started by Poki through
  `PokiLauncher` (Rust, idevice, `native/launcher`) over the phone's own developer services at
  10.7.0.1, which the user's proxy app reflects back (Surge, Loon, Shadowrocket, sing-box modules in
  `deploy/proxy-modules`). No VPN slot taken, no Mac after the first pairing.
- **PokiCore** (`native/ios/PokiCore`, Swift): the MCP (`look`, `do`, `status`) over WDA at
  127.0.0.1:8100, reached from the cloud through a Cloudflare Worker relay (`deploy/cf-relay`,
  live at pokimcp.zheha.nz, stores nothing).

The model stays in the cloud (claude.ai, Claude Code) and talks to the phone through the relay.

## Branches (fork), newest work first

| Branch | What | State |
|---|---|---|
| `dev/ios-app` | The app; integrates everything below; CI builds the IPA and screenshots every screen | 0.2.3 (this note) |
| `dev/ios-core` | PokiCore + PokiLauncher | 1b94d1e merged into the app; round-7 fixes in progress |
| `dev/live-activity` | Live Activity views and controller | 421c214 merged |
| `dev/ios-runner` | WDA patch, PokiRunnerHost, runner CI | a3e80ea merged |
| `dev/cf-relay` | Workers relay | deployed |
| `dev/ios-gym` | Poki Gym: a simulator app with one screen per hard case for UI automation (animation that never idles, alerts, the paste prompt, long lists, sheets, late focus, dense and duplicated trees, a web view, a navigation stack); the ios-core simulator job runs look/do scenarios against it | new |
| `dev/upstream-ios-standalone`, `dev/upstream-mcp-agent-tools` | Copies staged for upstream | pushed to upstream Nov 6 |

Tags: none yet. Versions come from `native/ios-app/VERSION`; `release.yml` on a `vX.Y.Z` tag builds
both IPAs with that version.

## Phone-test rounds on an iPhone 17 Pro, iOS 27.3 (owner's own tests)

| Round | Build | Found | Fixed in |
|---|---|---|---|
| 5 | 0.2.0 | Live Activity clipped; scrolling stalled; approvals never showed (event stream died after the first Turn off); Stop slow; raw JSON | 0.2.1 |
| 6 | 0.2.1 | Taps near the top landed on the expanded Dynamic Island and opened Poki; iOS 27 container clipped the Live Activity; "Best Buy" read as a payment | 0.2.2 |
| 7 | 0.2.2 | Surge's tunnel dropped twice and took the runner with it (recovery 30-90 s); tree reads stalled behind autoplay and a paste alert; one WDA session per read; paste leaked the clipboard; stale element numbers | 0.2.3 (tunnel side), rest open on `dev/ios-core` |

Details per round: `native/ios-app/CHANGELOG-round.md`. What only the phone can confirm:
`native/ios/PokiCore/UNVERIFIED.md`, `docs/device-test-checklist.md`.

## The owner's rules for this layer (Nov 7 2026)

1. The runner never crashes or wedges by itself, whatever the task or its length; only the owner's
   Stop or the agent withdrawing ends it. It must never be unable to return up-to-date information.
2. The tree is readable at any moment, under unfinished or continuous animation, live, cheap on the
   device, and it must match the screenshot (no dangerous mismatch). The tree stays the primary source.
3. The MCP never stalls the agent. "The animation is not over, you cannot read the tree" is a forbidden
   answer. While the runner is up and a screenshot is possible, every call answers with the picture and
   something actionable. Success rate under complex situations is the metric.
4. The first runner start after a restart may need the owner's passcode: detected, shown on the Live
   Activity, and the agent reads a plain "starting" meanwhile (the launcher waits up to 5 min).
5. Owner hand-off is the agent's discretion (a verification, a password, a payment): the agent can hand
   a screen to the owner through the Live Activity ("Your turn", a Done button), inputs pause, reads
   keep working, and the agent keeps polling instead of ending its chat. We build the channel; when the
   model stands down is the model's call, except the sensitive-action approvals already built.
6. All of it must work both with the Poki agent system in this repo and with a raw agent such as Claude
   connected directly to the MCP.

## Open problems, in order of pain

1. **Tunnel drops.** The XCTest runner dies when the developer connection does, and that connection
   runs through the user's proxy tunnel. 0.2.3 notices a drop, names it to the agent with the time
   and restarts the runner the moment 10.7.0.1 answers; it cannot stop the drop. Ideas: a keepalive
   through the tunnel, Surge on-demand rules, checking whether Focus/Bedtime suspends the proxy.
2. **Tree reads under animation.** WDA's snapshot waits for the app to idle; JD's homepage and a
   system paste alert never idle. Fix in progress: `waitForIdleTimeout`/`animationCoolOffTimeout`
   near zero, a snapshot timeout shorter than ours, one session kept, alert detection before slow calls.
3. **`via: "paste"`** inserted the owner's clipboard instead of the text once. Must verify the
   pasteboard before pasting and restore it even on failure.
4. **Element numbers** persist across page changes; the agent tapped the wrong thing by number.
5. **Stop while the runner is stuck** in a long read waits for iOS's ~30 s watchdog; 0.2.3 retries.

## How this could unify with upstream's MCP

- `dev/upstream-mcp-agent-tools` already carries a WDA backend for the look/do profile in the Node
  daemon (`src/cua-wda.mjs`, `POKI_CUA_BACKEND=wda`), so `look` and `do` answer the same way whether
  the bridge or the runner is underneath. PokiCore's later lessons (timed-out requests end the WDA
  session so nothing runs late, XML tree, busy answers, covered-element taps, the island region,
  per-action clocks) are in Swift and would need porting into that backend (about a day).
- The runner path sidesteps the private RemoteXPC services behind upstream issues #1 (AX and touch
  unavailable on iOS 18.6) and #6 (usbmuxd empty on macOS 27.2), and needs no Mac after pairing.
  It still needs the personalized developer disk image (#18 applies as much to us).
- It cannot replace all upstream tools: no raw HID, no per-process tools, and the runner must be
  installed and signed (a free Apple ID gives 7 days and 3 apps).
- Suggested shape: the runner path as an optional backend behind the same tool names, chosen per
  device, with the on-phone app as the way to run it without a computer.

## Facts that cost us time (so you do not pay again)

- ActivityKit `AlertConfiguration.sound` is not optional; an alert always expands the island, and a
  tap on the expanded island opens the app. Never alert while automation may tap near the top.
- A Live Activity on iOS 27's Lock Screen sits in a container with a ~40 pt corner radius; keep
  content within 124 pt and 22/18 pt margins.
- Cancelling the Task that iterates an `AsyncStream` ends the stream for good: one pump per app life.
- WDA serves one request at a time except `GET /status`, `GET /screenshot`, `DELETE /session`;
  `DELETE /session` voids everything queued, which is the only clean "abandon".
- The JSON `/source` fetches custom actions per element (one accessibility round trip each); the
  XML `/source` does not and is 3 to 7 times faster.
- A merge once dropped the CI version stamp silently; the IPA check in `ios-app.yml` now fails
  if the IPA's version differs from `VERSION`.
