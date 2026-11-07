# Poki iPhone app: changes per round

What changed in each round, and what still needs the phone. Newest first.

## Round 8 (2026-11-07, unattended gym round, 1:30-5:00 am ET), version 0.2.4

Changed:
- Live Activity: a tap on it never opens Poki (a no-op intent under every surface, no links); the island stays compact during steps.
- Hand-off: the agent can hand a screen to you (passcode, password, verification, payment, other) with its own words; the Live Activity shows "Your turn" with Done; inputs pause, reads go on, the agent keeps polling. The runner's own passcode prompt after a restart uses the same card (the launcher waits up to 5 min).
- PokiCore (dev/ios-core 1b3505a) after twelve gym runs on the simulator: a wedged app no longer blocks the runner for good (15 s watchdog, restart, "this is the new runner" note); a picture from outside the runner when the runner gives none; busy answers carry the picture and are not errors; a timed-out tree is read again in the same call (fewer children, then shallower); scroll_to reports progress and continues on the next call, never "unknown"; taps on containers name the buttons inside; no more GET /element/active (the keyboard in the tree is the focus signal); web views say to read again while their parts load.
- App unit tests run on the simulator in CI (fake launcher: loopback drops, pairing, the agent's view of the runner, the passcode card).
- Poki Gym (native/ios-gym, dev/ios-gym): ten hard screens and three faults scored per commit; all pass on 9e06c49.

Needs the phone:
- The hand-off card and Done on the Lock Screen and the island; a tap on the island that does not open Poki.
- JD.com / WeChat again: tree reads under their animations, scroll_to across long feeds, the watchdog's restart if an app wedges.
- The passcode card after a restart.

## Round 6 (2026-11-07, after the 10:32 pm ET Mail test), version 0.2.2

Changed:
- Poki stays out of the agent's way: no Dynamic Island pop-up per step, at start or on an app switch (approval, problem, pairing and finish only); the island area is never listed in the tree; if a tap lands in Poki, PokiCore brings the previous app back; Allow from the Live Activity reaches PokiCore 1.5 s after the tap.
- Live Activity margins for iOS 27's container (22 pt sides, 18 pt top/bottom; expanded island 24/18/22 pt).
- PokiCore: the action clock starts once the runner answers; per-action budgets in a batch; "buy" inside "Best Buy" is not a payment.
- The app logs when Poki came to the front during a step.

Needs the phone:
- No Poki in front after taps near the top of Mail or X; the action after Allow runs in the right app.
- Lock Screen and expanded island without clipped text.

## Round 5 (2026-11-07, after the 00:20Z phone test)

Changed:
- Events reach the screen for the app's whole life. After the first Turn off, no steps or approvals reached Home or the Live Activity (the event stream ended with the task that read it). One pump now lives in AppModel for the app's life.
- Stop really ends the runner: Poki ends the WDA session, asks the runner to shut down, the launcher ends its process, and Poki watches for up to 30 s. The "still running" notice only appears after 10 s and clears by itself once the runner is gone. The launcher reports what happened to the process.
- Live Activity (Live Activity thread): fits inside the system's height on every surface, 16 pt insets, no clipped corners; a silent small pop-up for each step; the large card for approvals; no gradients.
- Pairing is a real file check. Re-pair is always offered in Setup, a refused pairing is shown with "Pair again", the Agent tile and Setup agree, and a passcode hint shows while the runner takes long to start.
- Design: no gradients anywhere (Home, runner screens, Live Activity); rounded type on Home to match Poki Runner; the Agent tile says Idle or Working instead of Off; Copy log has an icon; the Live Activity preview link is gone from Debug.
- Runner opened by hand stays on its own screen with an Open Poki button (no automatic switch). Started by Poki it shows the in-use screen.
- Version 0.2.1 shows in Settings and the log header (was 1.0 (1)).
- Launcher: disk image mount capped at 120 s, failures named by cause (network, image refused, image bad, timeout) with the right fix; a bad image is downloaded again.

Needs the phone:
- Stop ends the runner within seconds and the notice clears.
- Each step pops up in the island and approvals show the large card with Allow and Deny.
- Scrolling and the element tree while an agent works (MCP thread's fixes land next).
- Re-pair from Setup and the passcode hint after a force quit.

## Round 4 (2026-11-06, after the 11:51Z phone test)

Changed:
- Steps are plain words everywhere (PokiCore StepLabels.swift), e.g. Tap “Send”, then type “hi”. No JSON on Home, the Live Activity or in approvals.
- Home redesigned: a hero card with live tiles for Agents, Runner and Loopback, an approval card with a countdown, a Now card (current step, latest screen, Stop), setup progress, a step timeline, runner settings, and Issue cards that each name one fix (runner stopped, loopback off, offline, location denied, approval ran out, Live Activity off).
- Approvals: the Live Activity pops up by itself (Live Activity thread). If it isn't running, a notification says to open Poki.
- Runner: the idle stop default is now 2 min, so long tasks keep the banner. Every restart request is logged with whether the runner answered. Stop checks 8 s later that the runner really ended, and says so if not.
- Runner screens: PokiRunnerHost draws a designed screen as soon as the scene is up, both in use and opened by hand, so it is never black. Opened by hand, it opens Poki after 1.2 s.
- Scrolling: the loopback check no longer redraws the screens every 3 s.
- Debug: Copy log and Share log (AppLog; it never holds what is typed into password fields).
- Merged dev/ios-core db52fe9 (WeChat Send hit-test; approval time no longer eats the actions' time).

Needs the phone:
- No flicker of the automation banner during a long task, and Stop ends it within a few seconds.
- The approval pop-up and its notification; Allow and Deny from the Lock Screen.
- Opening Poki Runner by hand shows its screen, then Poki.
- Scrolling on Home stays smooth while Poki is on.
