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
| dense | 3,000 labelled cells, so the tree is large and slow; a Found button below |
| dup | Two elements labelled Twin with the same frame over the real Twin button |
| fullscreen | A WKWebView filling the screen with one link, Open, that sets its title to Opened |
| nav | Push opens a page with the system back button; back sets "state: popped" |

Every screen shows "Gym: <scenario>" at the top and "state: <last event>" at the bottom, so an agent
can tell where it is and what its last action did from the tree alone.

`.github/workflows/ios-gym.yml` builds the simulator app (artifact `PokiGym-simulator`) and opens
each screen once.
