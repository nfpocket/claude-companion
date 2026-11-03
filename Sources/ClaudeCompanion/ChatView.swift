import SwiftUI
import AppKit

/// The Chat tab: the session's conversation, read from its transcript, and a field that types
/// into its Ghostty tab. Ghostty runs the session; this is a second view of the same one.
struct ChatTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var feed: ChatFeed
    let session: Session
    @State private var atBottom = true
    @State private var draft = ""
    @State private var inputHeight: CGFloat = 22

    private var outgoing: [ChatOutgoing] { feed.sessionId == session.id ? feed.outbox[session.id] ?? [] : [] }
    private var bottomKey: String {
        "\(feed.items.last?.id ?? "")|\(feed.items.last?.steps.count ?? 0)|\(feed.items.last?.text.count ?? 0)|\(feed.queued.count)|\(outgoing.count)|\(session.status.rawValue)"
    }

    var body: some View {
        VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        if feed.hasEarlier, feed.loaded {
                            Button(L("Show earlier messages")) { feed.showEarlier() }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.accentLight)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        if feed.sessionId == session.id {
                            ForEach(feed.items) { item in
                                ChatRow(item: item).equatable().id(item.id)
                            }
                            ForEach(feed.queued, id: \.self) { text in
                                YouBubble(text: text, note: L("Queued, goes in after this step"), faded: true)
                            }
                            ForEach(outgoing) { out in
                                YouBubble(text: out.text, note: out.failed ? L("Couldn’t reach its Ghostty tab") : L("Sent to Ghostty"),
                                          faded: true, failed: out.failed,
                                          onDismiss: out.failed ? { feed.dismiss(out, session: session.id) } : nil)
                            }
                        }
                        if !feed.loaded || feed.sessionId != session.id {
                            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.top, 30)
                        } else if feed.items.isEmpty, feed.queued.isEmpty, outgoing.isEmpty {
                            Text(L("No messages yet."))
                                .font(.system(size: 13))
                                .foregroundColor(Theme.faint)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 30)
                        }
                        statusRow
                        Color.clear.frame(height: 1).id("chat-bottom")
                            .onAppear { atBottom = true }
                            .onDisappear { atBottom = false }
                    }
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.automatic)
                .defaultScrollAnchor(.bottom)
                .onChange(of: feed.items.first?.id) { scrollDown(proxy) } // another session, or earlier messages
                .onChange(of: bottomKey) {
                    if atBottom { scrollDown(proxy) }
                }
                .onChange(of: feed.loaded) { if feed.loaded { scrollDown(proxy) } }
                .onAppear { scrollDown(proxy) }
                .onChange(of: outgoing.count) { scrollDown(proxy) }
            }
            .frame(maxHeight: .infinity)
            composer
        }
        .task(id: session.id) {
            feed.open(session)
            draft = feed.drafts[session.id] ?? ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if model.mainVisible { feed.refresh() } // not `animating`: this closure keeps the value it started with
            }
        }
        .onChange(of: draft) { feed.drafts[session.id] = draft.isEmpty ? nil : draft }
    }

    /// Scrolls to the end, again once SwiftUI has laid out what just arrived.
    private func scrollDown(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("chat-bottom", anchor: .bottom)
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
        }
    }

    // MARK: below the messages

    @ViewBuilder private var statusRow: some View {
        switch session.status {
        case .needs:
            WaitingCard(session: session)
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(session.activity.map(UIText.activity) ?? L("Working…"))
                    .font(.system(size: 12))
                    .foregroundColor(SessionStatus.working.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, 2)
        default:
            EmptyView()
        }
    }

    // MARK: typing

    /// Demo sessions have no tab but should look like real ones.
    private var hasTab: Bool { session.tty != nil || Demo.on }
    private var canSend: Bool { hasTab && session.status != .needs }

    private var placeholder: String {
        if session.status == .needs { return L("Answer in Ghostty first") }
        if !hasTab { return L("This session isn’t in a Ghostty tab") }
        return L("Message Claude (⇧ Return: new line)")
    }

    private var composer: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                ChatInput(text: $draft, height: $inputHeight, enabled: canSend, onSubmit: send)
                    .frame(height: inputHeight)
                if draft.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.faint)
                        .lineLimit(1)
                        .padding(.leading, 5)
                        .padding(.top, 3)
                        .allowsHitTesting(false)
                }
            }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(canSend && !empty ? Theme.ink : Theme.faint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(canSend && !empty ? Theme.accent : Theme.raised))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!canSend || empty)
            .help(L("Send to its Ghostty tab (Return)"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
        .opacity(canSend ? 1 : 0.7)
    }

    private func send() {
        guard canSend else { return }
        if model.sendChat(draft, to: session) {
            draft = ""
            atBottom = true
        }
    }
}

/// What the session is waiting on, and the way to answer it.
struct WaitingCard: View {
    @EnvironmentObject var model: AppModel
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Waiting on you in Ghostty"), systemImage: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(SessionStatus.needs.color)
            Text(UIText.needs(session.needsDetail))
                .font(.system(size: 13))
                .foregroundColor(Theme.body)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.focus(session) } label: {
                HStack(spacing: 8) {
                    Text(L("Answer in Ghostty"))
                    if let k = session.shortcut { Text(k).font(Theme.mono(11)).opacity(0.8) }
                }
            }
            .buttonStyle(PrimaryButtonStyle(height: 32))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(SessionStatus.needs.color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SessionStatus.needs.color.opacity(0.45), lineWidth: 1))
    }
}

// MARK: - Rows

struct ChatRow: View, Equatable {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .you:
            YouBubble(text: item.text, images: item.images)
        case .claude:
            MDView(blocks: item.blocks)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .steps:
            StepsRow(steps: item.steps)
        case .notice:
            HStack(spacing: 8) {
                Rectangle().fill(Theme.line).frame(height: 1)
                Text(L(item.text)).font(.system(size: 11)).foregroundColor(Theme.faint).fixedSize()
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            .padding(.vertical, 2)
        case .error:
            Label { Text(item.text).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(size: 12))
            .foregroundColor(Theme.danger)
            .textSelection(.enabled)
        }
    }
}

struct YouBubble: View {
    let text: String
    var images = 0
    var note: String?
    var faded = false
    var failed = false
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack {
            Spacer(minLength: 36)
            VStack(alignment: .trailing, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    if images > 0 {
                        Label(images == 1 ? L("1 image") : ui("\(images) images", "\(images) Bilder"), systemImage: "photo")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.muted)
                    }
                    if !text.isEmpty {
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.text)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(failed ? Theme.danger.opacity(0.6) : Theme.accent.opacity(0.28), lineWidth: 1))
                .opacity(faded ? 0.6 : 1)
                if let note {
                    HStack(spacing: 6) {
                        Text(note)
                        if let onDismiss {
                            Button(L("Dismiss"), action: onDismiss).buttonStyle(.plain).foregroundColor(Theme.accentLight)
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundColor(failed ? Theme.danger : Theme.faint)
                }
            }
        }
    }
}

/// Tool calls between two messages, folded into one line; click for each step.
struct StepsRow: View {
    let steps: [ChatStep]
    @State private var open = false

    private var failedCount: Int { steps.filter(\.failed).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Text(steps.count == 1 ? L("1 step") : ui("\(steps.count) steps", "\(steps.count) Schritte"))
                        .fontWeight(.semibold)
                    if !open, let last = steps.last {
                        Text("· " + UIText.activity(last.text)).lineLimit(1).truncationMode(.tail)
                    }
                    if failedCount > 0 {
                        Text("· " + ui("\(failedCount) failed", "\(failedCount) fehlgeschlagen")).foregroundColor(Theme.danger)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .foregroundColor(Theme.faint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps, id: \.id) { s in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: Self.icon(s.tool))
                                .font(.system(size: 10))
                                .frame(width: 14)
                                .foregroundColor(s.failed ? Theme.danger : Theme.faint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(UIText.activity(s.text))
                                    .font(.system(size: 12))
                                    .foregroundColor(s.failed ? Theme.danger : Theme.muted)
                                if let d = s.detail, !d.isEmpty, d != s.text {
                                    Text(d)
                                        .font(Theme.mono(10.5))
                                        .foregroundColor(Theme.faint)
                                        .lineLimit(3)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 2)
            }
        }
    }

    static func icon(_ tool: String) -> String {
        switch tool {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit", "NotebookEdit": return "pencil"
        case "Write": return "square.and.pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Agent", "Task": return "person.2"
        case "AskUserQuestion": return "questionmark.bubble"
        case "ExitPlanMode": return "list.bullet.rectangle"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList": return "checklist"
        default: return tool.hasPrefix("mcp__") ? "puzzlepiece" : "wrench.and.screwdriver"
        }
    }
}

/// Claude's Markdown: headings, lists, code, quotes and tables, with inline styling by Text.
struct MDView: View {
    let blocks: [MDBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks) { b in block(b) }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func block(_ b: MDBlock) -> some View {
        switch b.kind {
        case .paragraph:
            para(b.text)
        case .heading(let level):
            Text(b.text)
                .font(.system(size: level <= 2 ? 15 : 13.5, weight: .semibold))
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        case .bullet(let indent, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.faint)
                    .frame(minWidth: 12, alignment: .trailing)
                para(b.text)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.borderHi).frame(width: 3)
                Text(b.text).font(.system(size: 13)).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code:
            Text(b.text)
                .font(Theme.mono(11.5))
                .foregroundColor(Theme.body)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    ForEach(0..<rows.count, id: \.self) { i in
                        GridRow {
                            ForEach(0..<rows[i].count, id: \.self) { j in
                                Text(rows[i][j])
                                    .font(.system(size: 12, weight: i == 0 ? .semibold : .regular))
                                    .foregroundColor(i == 0 ? Theme.text : Theme.body)
                            }
                        }
                        if i == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .padding(.vertical, 2)
            }
        case .rule:
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 2)
        }
    }

    private func para(_ text: AttributedString) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Theme.body)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - The text field

/// The chat's text view: Return sends, ⇧ Return or ⌥ Return adds a line, and it grows to six
/// lines before it scrolls.
final class ChatTextView: NSTextView {}

struct ChatInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var enabled: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = ChatTextView(frame: .zero)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = NSColor(Theme.text)
        tv.insertionPointColor = NSColor(Theme.accent)
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 3)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        tv.isEditable = enabled
        scroll.documentView = tv
        context.coordinator.textView = tv
        DispatchQueue.main.async { context.coordinator.measure() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text {
            tv.string = text
            context.coordinator.measure()
        }
        if tv.isEditable != enabled { tv.isEditable = enabled }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInput
        weak var textView: NSTextView?

        init(_ parent: ChatInput) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            measure()
        }

        func measure() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            let clamped = min(max(h.rounded(.up), 22), 118)
            if abs(clamped - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = clamped }
            }
        }

        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if tv.hasMarkedText() { return false }
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if mods.contains(.shift) || mods.contains(.option) {
                tv.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSubmit()
            return true
        }
    }
}
