import SwiftUI

/// One screen per scenario, picked from the menu or with `pokigym://<scenario>`. Every screen has a
/// static title "Gym: <scenario>" and a bottom label "state: <last event>" so an automation agent can
/// confirm where it is and what its last action did without a picture.
@main
struct GymApp: App {
    @State private var scenario: Scenario? = nil
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if let scenario {
                    ScenarioScreen(scenario: scenario)
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Menu") { self.scenario = nil } } }
                } else {
                    MenuScreen(pick: { scenario = $0 })
                }
            }
            .onOpenURL { url in
                if let s = Scenario(rawValue: url.host ?? url.lastPathComponent) { scenario = s }
            }
        }
    }
}

enum Scenario: String, CaseIterable, Identifiable {
    case animation, alert, paste, list, sheet, focus, dense, dup, fullscreen, nav
    var id: String { rawValue }
    var blurb: String {
        switch self {
        case .animation: "A view that never idles, and a Next button"
        case .alert: "A system alert with Cancel and OK"
        case .paste: "An empty text field for the paste prompt"
        case .list: "300 rows; Row 250 sets the state"
        case .sheet: "A half sheet with a Done button"
        case .focus: "A field that takes focus 1.5 s after Start"
        case .dense: "1,500 small elements, a slow tree"
        case .dup: "Two elements with one label and frame over a Twin button"
        case .fullscreen: "A web view filling the screen with one link"
        case .nav: "Push a page with a system back button"
        }
    }
}

/// The last thing that happened on the current screen, shown at the bottom of every screen.
final class GymState: ObservableObject {
    @Published var last = "ready"
    func set(_ s: String) { last = s }
}

struct MenuScreen: View {
    var pick: (Scenario) -> Void
    var body: some View {
        List(Scenario.allCases) { s in
            Button { pick(s) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.rawValue).font(.headline)
                    Text(s.blurb).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("menu-\(s.rawValue)")
        }
        .navigationTitle("Gym: menu")
    }
}

struct ScenarioScreen: View {
    let scenario: Scenario
    @StateObject private var state = GymState()
    var body: some View {
        VStack(spacing: 0) {
            Text("Gym: \(scenario.rawValue)").font(.title2.bold()).padding(.top, 8).accessibilityIdentifier("title")
            Group {
                switch scenario {
                case .animation: AnimationScreen()
                case .alert: AlertScreen()
                case .paste: PasteScreen()
                case .list: ListScreen()
                case .sheet: SheetScreen()
                case .focus: FocusScreen()
                case .dense: DenseScreen()
                case .dup: DupScreen()
                case .fullscreen: FullscreenScreen()
                case .nav: NavScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("state: \(state.last)").font(.footnote.monospaced()).padding(8).frame(maxWidth: .infinity).background(.thinMaterial).accessibilityIdentifier("state")
        }
        .environmentObject(state)
        .navigationBarTitleDisplayMode(.inline)
    }
}
