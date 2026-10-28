import AppKit
import Observation
import SwiftUI

private typealias Design = SettingsDesign

// Send Feedback (the M5 Feedback design). Orilio has no servers: feedback leaves through the
// user's own Mail app or GitHub in the browser, and Orilio itself sends nothing.

/// What "Include system info" adds. These fields are all there is: no files, notes, clipboard
/// items or calendar events can get into feedback, because nothing else is collected.
struct SystemInfo: Equatable {
    let version: String
    let build: String
    let channel: String
    let macOS: String
    let model: String
    let displays: Int
    let modules: [String]

    static let neverIncluded = "Never included: files, notes, clipboard items, calendar events."

    var lines: [String] {
        ["Orilio \(version) (\(build)) · \(channel)",
         "macOS \(macOS) · \(model) · \(displays == 1 ? "1 display" : "\(displays) displays")",
         "Modules on: \(modules.isEmpty ? "none" : modules.joined(separator: ", "))"]
    }

    @MainActor static func current() -> SystemInfo {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return SystemInfo(version: AboutPane.version, build: AboutPane.build, channel: UpdateModel.shared.channel.rawValue.capitalized,
                          macOS: os.patchVersion > 0 ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)" : "\(os.majorVersion).\(os.minorVersion)",
                          model: String(decoding: model.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self),
                          displays: NSScreen.screens.count,
                          modules: AppModules.modules?.visible.map(\.rawValue) ?? [])
    }
}

enum FeedbackKind: String, CaseIterable, Identifiable {
    case bug, idea, question
    var id: Self { self }

    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .bug: "ladybug"
        case .idea: "lightbulb"
        case .question: "questionmark.circle"
        }
    }
    var prompt: String {
        switch self {
        case .bug: "What happened, and what did you expect?"
        case .idea: "What would make Orilio more useful?"
        case .question: "What would you like to know?"
        }
    }
    var placeholder: String {
        switch self {
        case .bug: "The island stayed open after I closed the lid…"
        case .idea: "It would be great if the Shelf could…"
        case .question: "How do I…"
        }
    }
}

/// Subject, body and the two ways out. Pure.
enum FeedbackComposer {
    /// GitHub takes long URLs, but not unlimited ones.
    static let maxBodyInURL = 6_000

    static func subject(_ kind: FeedbackKind, _ message: String) -> String {
        let first = message.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let short = first.count > 60 ? String(first.prefix(59)) + "…" : first
        return "[\(kind.label)] \(short)"
    }

    static func body(_ message: String, context: String?, info: SystemInfo?) -> String {
        var parts = [message.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let context { parts.append("Context: \(context)") }
        if let info { parts.append("—\n" + info.lines.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// Strict percent-encoding (RFC 3986 unreserved only), so "&", "+", "#" and any language
    /// survive a query string.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    static func mailto(recipient: String, subject: String, body: String) -> URL? {
        URL(string: "mailto:\(encode(recipient))?subject=\(encode(subject))&body=\(encode(body))")
    }

    static func issue(base: String, subject: String, body: String) -> URL? {
        let clipped = body.count > maxBodyInURL ? String(body.prefix(maxBodyInURL)) + "\n…" : body
        return URL(string: "\(base)?title=\(encode(subject))&body=\(encode(clipped))")
    }

    /// Info.plist `OrilioFeedbackEmail` and `OrilioIssuesURL`; empty means not set up (GitHub hidden).
    static var recipient: String { Bundle.main.object(forInfoDictionaryKey: "OrilioFeedbackEmail") as? String ?? "" }
    static var issuesURL: String? {
        (Bundle.main.object(forInfoDictionaryKey: "OrilioIssuesURL") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

@MainActor @Observable
final class FeedbackModel {
    enum Sent { case mail, github }

    var kind = FeedbackKind.bug
    var message = ""
    var includeInfo = true
    var showsInfo = false
    /// What the feedback is about, when opened from an error card ("Calendar access is off").
    var context: String?
    private(set) var sent: Sent?
    let info = SystemInfo.current()

    var isReady: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var subject: String { FeedbackComposer.subject(kind, message) }
    private var body: String { FeedbackComposer.body(message, context: context, info: includeInfo ? info : nil) }

    /// Mail's compose window with everything filled in; the user presses Send.
    func continueInMail() {
        guard isReady else { return }
        let recipient = FeedbackComposer.recipient
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = recipient.isEmpty ? [] : [recipient]
            service.subject = subject
            if service.canPerform(withItems: [body]) {
                service.perform(withItems: [body])
                sent = .mail
                return
            }
        }
        if let url = FeedbackComposer.mailto(recipient: recipient, subject: subject, body: body), NSWorkspace.shared.open(url) {
            sent = .mail
        }
    }

    /// A new GitHub issue in the browser, filled in; the user submits it.
    func postOnGitHub() {
        guard isReady, let base = FeedbackComposer.issuesURL,
              let url = FeedbackComposer.issue(base: base, subject: subject, body: body) else { return }
        NSWorkspace.shared.open(url)
        sent = .github
    }

    func again() {
        message = ""
        context = nil
        sent = nil
    }
}

struct FeedbackView: View {
    @Bindable var model: FeedbackModel

    var body: some View {
        Group {
            if let sent = model.sent { done(sent) } else { form }
        }
        .frame(width: 640)
        .foregroundStyle(Design.ink)
        .background(Design.window)
        .animation(.easeOut(duration: 0.2), value: model.sent)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 0) {
                ForEach(FeedbackKind.allCases) { kind in
                    let active = model.kind == kind
                    Button { model.kind = kind } label: {
                        Label(kind.label, systemImage: kind.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(active ? .black : Design.ink.opacity(0.8))
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(active ? Design.segmentOn : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Design.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(model.kind.prompt).font(.system(size: 13, weight: .semibold)).foregroundStyle(Design.label)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.message)
                        .font(.system(size: 13.5))
                        .scrollContentBackground(.hidden)
                        .padding(EdgeInsets(top: 10, leading: 9, bottom: 10, trailing: 9))
                        .accessibilityLabel(model.kind.prompt)
                    if model.message.isEmpty {
                        Text(model.kind.placeholder).font(.system(size: 13.5)).foregroundStyle(Design.ink.opacity(0.4))
                            .padding(EdgeInsets(top: 10, leading: 14, bottom: 0, trailing: 14))
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 130)
                .background(Design.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Design.ink.opacity(0.1), lineWidth: 1))
            }

            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include system info").font(.system(size: 13.5))
                        Button(model.showsInfo ? "Hide what’s included" : "See exactly what’s included") { model.showsInfo.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Design.loginOn)
                    }
                    Spacer(minLength: 0)
                    DesignSwitch(isOn: model.includeInfo, label: "Include system info") { model.includeInfo.toggle() }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                if model.showsInfo {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.info.lines, id: \.self) { Text($0) }
                        Text(SystemInfo.neverIncluded).foregroundStyle(Design.ink.opacity(0.45))
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(12 * 0.7 - 4)
                    .foregroundStyle(Design.ink.opacity(0.75))
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Design.divider).frame(height: 1) }
                    .textSelection(.enabled)
                }
            }
            .background(Design.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Design.cardStroke, lineWidth: 1))

            HStack {
                let count = model.message.trimmingCharacters(in: .whitespacesAndNewlines).count
                Text(count > 0 ? "\(count) characters" : "Write a few words to continue")
                    .font(.system(size: 12)).foregroundStyle(Design.ink.opacity(0.5))
                Spacer()
                if FeedbackComposer.issuesURL != nil {
                    FeedbackButton(title: "Post on GitHub", mint: false, enabled: model.isReady) { model.postOnGitHub() }
                }
                FeedbackButton(title: "Continue in Mail", mint: true, enabled: model.isReady) { model.continueInMail() }
            }
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 24, trailing: 26))
    }

    private func done(_ sent: FeedbackModel.Sent) -> some View {
        VStack(spacing: 12) {
            Circle().strokeBorder(Design.accent, lineWidth: 3)
                .frame(width: 56, height: 56)
                .shadow(color: Design.accent.opacity(0.4), radius: 10)
                .overlay { Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).foregroundStyle(Design.accentText) }
            Text(sent == .github ? "GitHub is open in your browser" : "Your Mail app is ready").font(.system(size: 20, weight: .semibold))
            Text(sent == .github ? "We filled in the title and details. Review it and press Submit new issue."
                 : "We drafted the email with your message\(model.includeInfo ? " and system info" : ""). Just press Send — nothing has gone out yet.")
                .font(.system(size: 13.5)).foregroundStyle(Design.ink.opacity(0.62))
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            FeedbackButton(title: "Send something else", mint: false, enabled: true) { model.again() }.padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(EdgeInsets(top: 48, leading: 32, bottom: 40, trailing: 32))
    }
}

private struct FeedbackButton: View {
    let title: String
    let mint: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: mint ? .semibold : .medium))
                .foregroundStyle(mint ? Design.hex(0x00140D).opacity(enabled ? 1 : 0.6) : Design.ink)
                .padding(.horizontal, mint ? 16 : 14)
                .frame(height: 36)
                .background(mint ? Design.accent.opacity(enabled ? 1 : 0.25) : Design.ink.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The Send Feedback window: from About, the menu bar, and "Report this" on error cards.
@MainActor
enum FeedbackWindow {
    private static var window: NSWindow?
    private static var model = FeedbackModel()

    static func show(kind: FeedbackKind = .bug, context: String? = nil) {
        if model.sent != nil { model = FeedbackModel() }
        model.kind = kind
        if let context { model.context = context }
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: FeedbackView(model: model)))
            window.title = "Send Feedback"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        } else {
            window?.contentViewController = NSHostingController(rootView: FeedbackView(model: model))
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
