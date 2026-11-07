# Poki Gym

A small iPhone app for the iOS Simulator with one screen per case that trips UI automation. The
look/do scenarios in `native/ios/PokiCore` run against it (bundle id `nz.zheha.poki.gym`).

Open a scenario with `xcrun simctl openurl <udid> pokigym://<scenario>`, or from the menu:

| Scenario | Screen |
|---|---|
| animation | A spinner, pulsing dots and a timer that redraw every frame (the app never idles); Next changes "Taps: n" |
| alert | Show alert raises a system alert with Cancel and OK; OK sets "state: OK tapped" |
| paste | An empty text field; pasting raises iOS's paste prompt |
| list | 300 rows "Row n"; tapping Row 250 sets the state |
| sheet | Open sheet shows a half sheet with Done |
| focus | Start arms a field that takes focus 1.5 s later |
| dense | 1,500 labelled cells, so the tree is large and slow; a Found button below |
| dup | Two elements labelled Twin with the same frame over the real Twin button |
| fullscreen | A WKWebView filling the screen with one link, Open, that sets its title to Opened |
| nav | Push opens a page with the system back button; back sets "state: popped" |

Every screen shows "Gym: <scenario>" at the top and "state: <last event>" at the bottom, so an agent
can tell where it is and what its last action did from the tree alone.

`.github/workflows/ios-gym.yml` builds the simulator app (artifact `PokiGym-simulator`) and opens
each screen once.

## Scorecard

`check/main.swift` is the gym driver: in CI (`.github/workflows/ios-gym.yml`, job `scorecard`) it is
built as one more executable of the PokiCore package from `dev/ios-core` and drives look/do through
every scenario and three faults (a look during a long action, the runner killed and restarted, a
scroll_to for text that is not there). A run fails on any call that hangs, answers without a
picture, misses its budget, or does not move the screen. The table lands in the job summary and in
the `gym-scorecard` artifact with every picture the agent would have seen.
