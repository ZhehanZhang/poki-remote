import AppIntents
import Foundation

/// Approve and Deny on the Live Activity. A decision is written to the App Group and announced with a
/// Darwin notification, so it reaches the app whichever process runs the intent. PokiCore sends no
/// input at all while an approval is pending, so the automation cannot press these buttons itself;
/// Approve also asks for Face ID or the passcode when the phone is locked.
struct ApproveActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Approve action"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let isDiscoverable = false

    @Parameter(title: "Approval") var approvalID: String

    init() {}
    init(approvalID: String) { self.approvalID = approvalID }

    func perform() async throws -> some IntentResult {
        ApprovalMailbox.post(id: approvalID, approved: true)
        return .result()
    }
}

struct DenyActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny action"
    static let isDiscoverable = false

    @Parameter(title: "Approval") var approvalID: String

    init() {}
    init(approvalID: String) { self.approvalID = approvalID }

    func perform() async throws -> some IntentResult {
        ApprovalMailbox.post(id: approvalID, approved: false)
        return .result()
    }
}

/// Stop runner on the Live Activity: stops the runner (and with it iOS's automation banner) until an
/// agent's next request. No authentication: stopping is always safe.
struct StopRunnerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop runner"
    static let isDiscoverable = false
    init() {}
    func perform() async throws -> some IntentResult {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(ApprovalMailbox.stopRunner as CFString), nil, nil, true)
        return .result()
    }
}

/// Done on the Live Activity's "your turn" card: the person finished what the agent could not do
/// (a passcode, a verification, a payment). The app passes it on to PokiCore, which tells the agent.
/// No authentication: it only says "carry on".
struct HandoffDoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Done, carry on"
    static let isDiscoverable = false

    @Parameter(title: "Handoff") var handoffID: String

    init() {}
    init(handoffID: String) { self.handoffID = handoffID }

    func perform() async throws -> some IntentResult {
        SharedContainer.defaults.set(handoffID, forKey: ApprovalMailbox.handoffKey)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(ApprovalMailbox.handoffDone as CFString), nil, nil, true)
        return .result()
    }
}

/// Swallows a tap on the Live Activity's plain areas. iOS opens the activity's app on any tap that no
/// control takes; this intent, laid under every surface (see TapShield), takes it instead and does
/// nothing, so the agent's run is never interrupted by Poki coming to the front. Poki's own buttons
/// sit above it and still work.
struct NoTapIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Nothing"
    static let isDiscoverable = false
    init() {}
    func perform() async throws -> some IntentResult { .result() }
}

/// Decisions in flight between the intent and the app.
enum ApprovalMailbox {
    static let notification = "nz.zheha.poki.approval"
    static let stopRunner = "nz.zheha.poki.stop-runner"
    static let handoffDone = "nz.zheha.poki.handoff-done"
    static let handoffKey = "handoff.done"

    /// The id of the handoff the person marked done, once.
    static func drainHandoffDone() -> String? {
        let id = SharedContainer.defaults.string(forKey: handoffKey)
        SharedContainer.defaults.removeObject(forKey: handoffKey)
        return id
    }
    private static let key = "approval.decisions"

    static func post(id: String, approved: Bool) {
        var decisions = SharedContainer.defaults.dictionary(forKey: key) as? [String: Bool] ?? [:]
        decisions[id] = approved
        SharedContainer.defaults.set(decisions, forKey: key)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(notification as CFString), nil, nil, true)
    }

    /// Takes every decision posted so far, once.
    static func drain() -> [String: Bool] {
        let decisions = SharedContainer.defaults.dictionary(forKey: key) as? [String: Bool] ?? [:]
        SharedContainer.defaults.removeObject(forKey: key)
        return decisions
    }
}
