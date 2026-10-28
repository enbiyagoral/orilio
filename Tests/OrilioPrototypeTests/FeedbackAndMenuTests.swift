import Foundation
import Testing
@testable import OrilioPrototype

struct FeedbackTests {
    private let info = SystemInfo(version: "0.5.0", build: "412", channel: "Stable", macOS: "26.1", model: "Mac15,6",
                                  displays: 2, modules: ["Calendar", "Focus"])

    @Test func systemInfoHoldsOnlyWhatIsShown() {
        // The struct is the whole list: nothing else can get into feedback.
        let fields = Set(Mirror(reflecting: info).children.compactMap(\.label))
        #expect(fields == ["version", "build", "channel", "macOS", "model", "displays", "modules"])
        #expect(info.lines == ["Orilio 0.5.0 (412) · Stable", "macOS 26.1 · Mac15,6 · 2 displays", "Modules on: Calendar, Focus"])
    }

    @Test func theBodyIsTheMessageAndOptionallyTheInfo() {
        let without = FeedbackComposer.body("  It froze.\n", context: nil, info: nil)
        #expect(without == "It froze.")
        let with = FeedbackComposer.body("It froze.", context: "Calendar access is off", info: info)
        #expect(with == "It froze.\n\nContext: Calendar access is off\n\n—\nOrilio 0.5.0 (412) · Stable\nmacOS 26.1 · Mac15,6 · 2 displays\nModules on: Calendar, Focus")
        #expect(FeedbackComposer.subject(.idea, "Shelf folders\nmore text") == "[Idea] Shelf folders")
        #expect(FeedbackComposer.subject(.bug, String(repeating: "a", count: 80)).count == "[Bug] ".count + 60)
    }

    @Test func turkishAndSymbolsSurviveTheURLs() throws {
        let body = "Ada açılmıyor & kapanmıyor: ğüşiöç İ #1 + 100% ?"
        let mail = try #require(FeedbackComposer.mailto(recipient: "a@b.co", subject: "[Bug] Çalışmıyor", body: body))
        let components = try #require(URLComponents(url: mail, resolvingAgainstBaseURL: false))
        #expect(mail.scheme == "mailto")
        #expect(components.queryItems?.first { $0.name == "body" }?.value == body)
        #expect(components.queryItems?.first { $0.name == "subject" }?.value == "[Bug] Çalışmıyor")
        #expect(!mail.absoluteString.contains("&") || mail.absoluteString.components(separatedBy: "&").count == 2) // only the separator

        let long = String(repeating: "ş", count: 10_000)
        let issue = try #require(FeedbackComposer.issue(base: "https://github.com/o/r/issues/new", subject: "t", body: long))
        let sent = try #require(URLComponents(url: issue, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        #expect(sent.count == FeedbackComposer.maxBodyInURL + 2) // clipped, with "\n…"
    }
}

@MainActor
struct MenuTests {
    @Test func quickActionsFollowTheModules() {
        #expect(QuickAction.visible(hidden: []) == [.pin, .focus, .note, .mirror])
        #expect(QuickAction.visible(hidden: [.mirror, .notes]) == [.pin, .focus])
        #expect(QuickAction.visible(hidden: Set(IslandTab.allCases)) == [.pin]) // Pin is the island itself
    }

    @Test func theHeaderSaysWhatIsLive() {
        let focus = FocusModule(defaults: UserDefaults(suiteName: "orilio.menu.\(UUID().uuidString)")!, notifier: Silent())
        let now = Date()
        #expect(MenuStatus.line(layout: .idle, focus: focus, now: now) == nil)
        focus.setMinutes(25)
        focus.begin()
        let running = EarLayout(leading: LiveActivity(payload: .focus(.running)))
        #expect(MenuStatus.line(layout: running, focus: focus, now: focus.now())?.hasPrefix("Focus · ") == true)
        focus.reset()
    }
}

private struct Silent: FocusNotifier {
    func authorize() async -> Bool { false }
    func isAuthorized() async -> Bool { false }
    func schedule(at date: Date, minutes: Int) async {}
    func cancel() async {}
}
