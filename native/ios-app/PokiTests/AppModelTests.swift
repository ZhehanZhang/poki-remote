import PokiCore
import XCTest
@testable import Poki

/// A launcher that records what the app asked of it and plays back runner events.
final class FakeLauncher: RunnerLauncher, @unchecked Sendable {
    var starts = 0, restarts = 0, stops = 0
    var emit: (@Sendable (RunnerStatus) -> Void)?
    func start(config: LauncherConfig, onEvent: @escaping @Sendable (RunnerStatus) -> Void) throws { starts += 1; emit = onEvent }
    func restart() { restarts += 1 }
    func stop() { stops += 1 }
}

final class FakePairing: DevicePairing {
    func start(hostName: String, saveTo: URL, onEvent: @escaping @Sendable (PairingEvent) -> Void) throws {}
    func cancel() {}
}

@MainActor
final class AppModelTests: XCTestCase {
    private func model() -> (AppModel, FakeLauncher) {
        let launcher = FakeLauncher()
        let model = AppModel(launcher: launcher, pairer: FakePairing())
        return (model, launcher)
    }

    /// A tunnel drop while the runner is connecting is named to the agent with the time and the fix,
    /// whatever launcher state it happens to be in; "Checking pairing" alone would say nothing.
    func testLoopbackDownIsNamedToTheAgent() {
        let (model, _) = model()
        model.loopback.simulate(.working(ms: 12))
        model.loopback.simulate(.off)
        for state in ["connecting", "pairing", "waiting_network", "standby"] {
            let text = model.coreState(of: RunnerStatus(state: state)).describe
            XCTAssertTrue(text.contains("waiting for the loopback since"), "\(state): \(text)")
            XCTAssertTrue(text.contains("proxy app"), text)
        }
        // Launching and running are past the tunnel: they stay what the launcher says.
        XCTAssertEqual(model.coreState(of: RunnerStatus(state: "running")).describe, "running")
    }

    /// A tunnel that gave the phone an address but does not reflect it is told apart from no tunnel.
    func testTunnelOnButNotReflectedSaysSo() {
        let (model, _) = model()
        model.loopback.simulate(.working(ms: 12))
        model.loopback.simulate(.noAnswer)
        let text = model.coreState(of: RunnerStatus(state: "pairing")).describe
        XCTAssertTrue(text.contains("does not reflect 10.7.0.1"), text)
    }

    /// With the loopback up, the launcher's own words stand.
    func testLoopbackUpKeepsTheLauncherState() {
        let (model, _) = model()
        model.loopback.simulate(.working(ms: 9))
        XCTAssertEqual(model.coreState(of: RunnerStatus(state: "pairing")).describe, "starting (Checking pairing)")
    }

    /// A pairing refusal is kept until the phone accepts again; a disk-image refusal re-downloads.
    func testPairingRefusalThenAcceptance() {
        let (model, _) = model()
        model.runnerChanged(RunnerStatus(state: "failed", detail: "the phone refused the pairing", fix: "Pair again in Poki's setup"))
        XCTAssertNotNil(model.pairingTrouble)
        model.runnerChanged(RunnerStatus(state: "launching"))
        XCTAssertNil(model.pairingTrouble)
        XCTAssertNotNil(model.pairingVerifiedAt)
    }

    /// The agent's view of the runner follows every launcher event.
    func testHostSeesTheRunnerState() {
        let (model, _) = model()
        model.loopback.simulate(.working(ms: 9))
        model.runnerChanged(RunnerStatus(state: "running"))
        XCTAssertTrue(model.host.currentRunner.isRunning)
        model.runnerChanged(RunnerStatus(state: "failed", detail: "it stopped", fix: nil))
        if case .failed(let detail, _) = model.host.currentRunner { XCTAssertEqual(detail, "it stopped") } else { XCTFail("not failed") }
    }

    /// Idle stop setting round-trips and never goes below the floor the picker offers.
    func testIdleStopSetting() {
        let (model, _) = model()
        model.idleStopSeconds = 120
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "idleStopSeconds.v4"), 120)
        model.idleStopSeconds = 60
    }
}

@MainActor
final class PasscodeTests: XCTestCase {
    /// After a restart iOS asks for the passcode before the first automation. The launcher says so
    /// (code "passcode"); the agent reads a plain "starting" with the reason, and the Live Activity
    /// asks the owner; the hint clears when the runner answers.
    func testPasscodeWaitIsNamedAndClears() {
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        model.loopback.simulate(.working(ms: 9))
        model.runnerChanged(RunnerStatus(state: "launching"))
        model.runnerChanged(RunnerStatus(state: "launching", detail: "no answer for 12 s", code: "passcode"))
        XCTAssertTrue(model.passcodeHint)
        let text = model.host.currentRunner.describe
        XCTAssertTrue(text.contains("passcode"), text)
        XCTAssertTrue(text.contains("Call again"), text)
        XCTAssertTrue(text.hasPrefix("starting"), text)
        model.runnerChanged(RunnerStatus(state: "running"))
        XCTAssertFalse(model.passcodeHint)
        XCTAssertTrue(model.host.currentRunner.isRunning)
    }
}
