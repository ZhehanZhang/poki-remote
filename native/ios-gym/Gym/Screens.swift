import SwiftUI
import WebKit

/// A spinner that never stops and a display link that redraws every frame: XCTest's "wait for idle"
/// never ends here, as on JD's homepage or a live stream.
struct AnimationScreen: View {
    @EnvironmentObject var state: GymState
    @State private var taps = 0
    var body: some View {
        VStack(spacing: 24) {
            ProgressView().controlSize(.large)
            PulsingDots()
            TimelineView(.animation) { context in
                Text(String(format: "%.2f", context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000)))
                    .font(.system(.largeTitle, design: .monospaced))
            }
            Text("Taps: \(taps)").accessibilityIdentifier("count")
            Button("Next") { taps += 1; state.set("Next tapped \(taps)") }.buttonStyle(.borderedProminent)
        }
    }
}

struct PulsingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<5, id: \.self) { i in
                Circle().fill(.blue).frame(width: 14, height: 14).scaleEffect(on ? 1.4 : 0.6)
                    .animation(.easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.08), value: on)
            }
        }
        .onAppear { on = true }
        .accessibilityHidden(true)
    }
}

struct AlertScreen: View {
    @EnvironmentObject var state: GymState
    @State private var showing = false
    var body: some View {
        VStack(spacing: 20) {
            Button("Show alert") { showing = true; state.set("alert shown") }.buttonStyle(.borderedProminent)
            Text("Tap OK in the alert.").foregroundStyle(.secondary)
        }
        .alert("Gym alert", isPresented: $showing) {
            Button("Cancel", role: .cancel) { state.set("Cancel tapped") }
            Button("OK") { state.set("OK tapped") }
        } message: { Text("An alert on top of the screen.") }
    }
}

struct PasteScreen: View {
    @EnvironmentObject var state: GymState
    @State private var text = ""
    var body: some View {
        VStack(spacing: 20) {
            TextField("Paste here", text: $text).textFieldStyle(.roundedBorder).padding(.horizontal, 24)
                .accessibilityIdentifier("field")
                .onChange(of: text) { _, new in state.set("field: \(new)") }
            Text("The field is empty. Pasting raises the iOS paste prompt.").foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
        }
    }
}

struct ListScreen: View {
    @EnvironmentObject var state: GymState
    var body: some View {
        List(1...300, id: \.self) { n in
            Button("Row \(n)") { state.set("Row \(n) tapped") }.accessibilityIdentifier("row-\(n)")
        }
    }
}

struct SheetScreen: View {
    @EnvironmentObject var state: GymState
    @State private var open = false
    var body: some View {
        VStack(spacing: 20) {
            Button("Open sheet") { open = true; state.set("sheet open") }.buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $open) {
            VStack(spacing: 20) {
                Text("A half sheet").font(.title3)
                Button("Done") { open = false; state.set("Done tapped") }.buttonStyle(.borderedProminent)
            }
            .presentationDetents([.medium])
        }
    }
}

/// The field only becomes first responder 1.5 s after Start, as a search field that animates in.
struct FocusScreen: View {
    @EnvironmentObject var state: GymState
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var armed = false
    var body: some View {
        VStack(spacing: 20) {
            Button("Start") {
                armed = true; state.set("started; focus in 1.5 s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { focused = true; state.set("field focused") }
            }.buttonStyle(.borderedProminent)
            if armed {
                TextField("Type after focus", text: $text).textFieldStyle(.roundedBorder).padding(.horizontal, 24).focused($focused)
                    .accessibilityIdentifier("field")
                    .onChange(of: text) { _, new in state.set("field: \(new)") }
            }
        }
    }
}

/// 1,500 tiny labelled cells in a grid: the accessibility tree is huge and slow to read, while the
/// app stays responsive (3,000 wedged the main loop for good on the CI simulator: not a fair case).
struct DenseScreen: View {
    @EnvironmentObject var state: GymState
    let columns = Array(repeating: GridItem(.fixed(12), spacing: 1), count: 30)
    var body: some View {
        VStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 1) {
                    ForEach(0..<1500, id: \.self) { i in
                        Rectangle().fill(i % 7 == 0 ? Color.orange : Color.gray.opacity(0.3)).frame(width: 12, height: 12)
                            .accessibilityElement().accessibilityLabel("cell \(i)")
                    }
                }
            }
            Button("Found") { state.set("Found tapped") }.buttonStyle(.borderedProminent)
        }
    }
}

/// Two accessibility elements with the same label and frame, over one real button.
struct DupScreen: View {
    @EnvironmentObject var state: GymState
    var body: some View {
        ZStack {
            Color.clear.frame(width: 160, height: 60).accessibilityElement().accessibilityLabel("Twin").accessibilityAddTraits(.isButton)
            Color.clear.frame(width: 160, height: 60).accessibilityElement().accessibilityLabel("Twin").accessibilityAddTraits(.isButton)
            Button("Twin") { state.set("Twin tapped") }.buttonStyle(.borderedProminent).frame(width: 160, height: 60)
        }
    }
}

struct FullscreenScreen: View {
    @EnvironmentObject var state: GymState
    var body: some View {
        WebPage(onOpen: { state.set("Open followed") })
            .ignoresSafeArea(edges: .bottom)
    }
}

struct WebPage: UIViewRepresentable {
    var onOpen: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        web.loadHTMLString("""
        <html><head><meta name=viewport content='width=device-width, initial-scale=1'></head>
        <body style='font-family:-apple-system;padding:24px'>
        <h1 id=t>A web page</h1><p>One link below, nothing else to tap.</p>
        <p><a href='gym://open' style='font-size:22px'>Open</a></p>
        <p style='height:1400px'></p><p>bottom</p></body></html>
        """, baseURL: nil)
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onOpen: () -> Void
        init(onOpen: @escaping () -> Void) { self.onOpen = onOpen }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.request.url?.scheme == "gym" {
                onOpen()
                webView.evaluateJavaScript("document.getElementById('t').textContent='Opened'")
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
    }
}

struct NavScreen: View {
    @EnvironmentObject var state: GymState
    var body: some View {
        VStack(spacing: 20) {
            NavigationLink("Push") { PushedPage().environmentObject(state) }.buttonStyle(.borderedProminent)
                .simultaneousGesture(TapGesture().onEnded { state.set("pushed") })
        }
    }
}

struct PushedPage: View {
    @EnvironmentObject var state: GymState
    var body: some View {
        VStack(spacing: 16) {
            Text("Pushed page").font(.title2)
            Text("Use the system back button.").foregroundStyle(.secondary)
            Spacer()
            Text("state: \(state.last)").font(.footnote.monospaced()).padding(8)
        }
        .navigationTitle("Gym: nav 2")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { state.set("popped") }
    }
}
