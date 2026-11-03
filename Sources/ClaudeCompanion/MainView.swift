import SwiftUI
import TaskTrackerCore
import TaskTrackerUI

// MARK: - Window root

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            ZStack {
                StageView()
                OverlayLayer()
            }
            FooterBar()
        }
        .background(Theme.bg)
        .foregroundColor(Theme.text)
        .environment(\.colorScheme, .dark)
        .environment(\.animating, model.mainVisible)
        .focusEffectDisabled()
        .id(model.uiLanguage) // rebuild every label when the app language changes
        .sheet(isPresented: $model.showHelp) { HelpView().environmentObject(model) }
    }
}

// MARK: - Header

struct HeaderBar: View {
    @EnvironmentObject var model: AppModel

    private var counts: [(SessionStatus, String)] {
        let s = model.sessions
        var out: [(SessionStatus, String)] = []
        let needs = s.filter { $0.status == .needs }.count
        let failed = s.filter { $0.status == .failed && $0.unseen }.count
        let done = s.filter { $0.status == .done && $0.unseen }.count
        let working = s.filter { $0.status == .working }.count
        let shell = s.filter { $0.status == .shell }.count
        if needs > 0 { out.append((.needs, UIText.count(.needs, needs))) }
        if failed > 0 { out.append((.failed, UIText.count(.failed, failed))) }
        if done > 0 { out.append((.done, UIText.count(.done, done))) }
        if working > 0 { out.append((.working, UIText.count(.working, working))) }
        if shell > 0 { out.append((.shell, UIText.count(.shell, shell))) }
        return out
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(L("Companion")).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(counts, id: \.0) { status, text in
                    StatusChip(status: status, text: text)
                }
            }
            Spacer()
            if !model.hooksInstalled {
                Text(L("Status hooks not installed"))
                    .font(.system(size: 12))
                    .foregroundColor(SessionStatus.needs.color)
                    .help(L("Run scripts/install-hooks.sh so “needs you” shows up."))
            }
            Button { model.showTodos.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                    Text(L("Tasks"))
                    let n = model.todos.count + (model.menuPanel?.openCount ?? 0)
                    if n > 0 {
                        Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.muted)
                    }
                }
                .font(.system(size: 13))
            }
            .buttonStyle(ChromeButtonStyle())
            .help(L("Show or hide your tasks and the menu"))
            Picker("", selection: $model.uiLanguage) {
                Text("EN").tag(Lang.en)
                Text("DE").tag(Lang.de)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 92)
            .help(L("App language"))
            Button { Ghostty.activate() } label: {
                Label(L("Ghostty"), systemImage: "terminal").font(.system(size: 13))
            }
            .buttonStyle(ChromeButtonStyle())
            Button { model.showHelp = true } label: {
                Image(systemName: "questionmark").font(.system(size: 13, weight: .semibold)).frame(width: 14)
            }
            .buttonStyle(ChromeButtonStyle())
            .help(L("What you can say"))
        }
        .padding(.leading, 84)
        .padding(.trailing, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

struct StatusChip: View {
    var status: SessionStatus
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            StatusGlyph(status: status, size: 12)
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(status.color)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(status.color.opacity(0.15)))
    }
}

// MARK: - Orbit

struct OrbitLayout {
    let center: CGPoint
    let rx: CGFloat
    let ry: CGFloat
    let roomy: Bool
    private var points: [String: CGPoint] = [:]
    private var widths: [String: CGFloat] = [:]

    init(size: CGSize, sessions: [Session], drawer: CGFloat, bottom: CGFloat, leading: CGFloat = 0) {
        let w = max(400, size.width - drawer - leading)
        let h = max(300, size.height - bottom)
        center = CGPoint(x: leading + w / 2, y: h / 2)
        let n = sessions.count
        let cardW: CGFloat = n > 8 ? 240 : 290
        rx = max(170, min(w / 2 - cardW / 2 - 18, 400))
        ry = max(110, min(h / 2 - 42 - 16, 230))
        roomy = ry >= 165
        let angles = OrbitLayout.slots(n)
        for (i, s) in sessions.enumerated() {
            let a = angles[i] * .pi / 180
            let pull: CGFloat = (s.status == .needs && i == 0) ? 0.84 : 1
            points[s.id] = CGPoint(x: center.x + rx * pull * cos(a), y: center.y + ry * pull * sin(a))
            widths[s.id] = s.status == .needs ? max(cardW, 320) : cardW
        }
    }

    func point(_ id: String) -> CGPoint { points[id] ?? center }
    func width(_ id: String) -> CGFloat { widths[id] ?? 290 }

    /// Angles around the ellipse, nearest the top first, left before right on ties.
    static func slots(_ n: Int) -> [Double] {
        guard n > 0 else { return [] }
        let step = 360.0 / Double(n)
        func dist(_ a: Double) -> Double {
            let d = abs((a + 90).truncatingRemainder(dividingBy: 360))
            return min(d, 360 - d)
        }
        return (0..<n).map { -90.0 + Double($0) * step }.sorted { a, b in
            let da = dist(a), db = dist(b)
            if abs(da - db) > 0.01 { return da < db }
            return cos(a * .pi / 180) < cos(b * .pi / 180)
        }
    }
}

struct LineShape: Shape {
    var from: CGPoint
    var to: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(from.x, from.y), .init(to.x, to.y)) }
        set {
            from = CGPoint(x: newValue.first.first, y: newValue.first.second)
            to = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        return p
    }
}

struct StageView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let drawer: CGFloat = model.selectedId != nil ? 360 : 0
            let leading: CGFloat = model.showTodos ? TodoPanel.width : 0
            let lay = OrbitLayout(size: geo.size, sessions: model.sessions, drawer: drawer,
                                  bottom: model.overlayHeight, leading: leading)
            ZStack(alignment: .topLeading) {
                Color.clear
                Ellipse()
                    .stroke(Theme.ring, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: lay.rx * 2, height: lay.ry * 2)
                    .position(lay.center)
                ForEach(model.sessions) { s in
                    let style = cardStyle(s)
                    LineShape(from: lay.center, to: lay.point(s.id))
                        .stroke(lineColor(s, style), lineWidth: style.highlight != nil ? 2 : 1)
                }
                AvatarView(mode: model.avatar, size: 140, level: { model.voiceLevel() })
                    .position(lay.center)
                    .onTapGesture { _ = model.escape() }
                if lay.roomy {
                    VStack(spacing: 4) {
                        Text(avatarTitle).font(.system(size: 16, weight: .semibold))
                        Text(avatarSubtitle).font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
                    }
                    .frame(width: 280)
                    .position(x: lay.center.x, y: lay.center.y + 70 + 30)
                }
                ForEach(model.sessions) { s in
                    let style = cardStyle(s)
                    SessionCard(session: s, menuCount: model.menuPanel?.openCount(forSession: s.id) ?? 0,
                                selected: model.selectedId == s.id,
                                highlight: style.highlight, dimmed: style.dimmed) { model.select(s.id) }
                        .frame(width: lay.width(s.id))
                        .position(lay.point(s.id))
                }
                if model.sessions.isEmpty {
                    Text(L("No Claude Code sessions are running.\nHold Space and say “start a session in …”, or click Start a session."))
                        .multilineTextAlignment(.center)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                        .frame(width: 420)
                        .position(x: lay.center.x, y: lay.center.y + 150)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.86), value: model.sessions.map(\.id))
            .animation(.spring(response: 0.55, dampingFraction: 0.86), value: drawer)
            .animation(.spring(response: 0.55, dampingFraction: 0.86), value: model.overlayHeight)
            .overlay(alignment: .bottomLeading) {
                if model.overlayHeight == 0 && !model.showTodos { Legend().padding(.leading, 20).padding(.bottom, 16) }
            }
            .overlay(alignment: .leading) {
                if model.showTodos { TodoPanel().transition(.move(edge: .leading)) }
            }
            .animation(.easeOut(duration: 0.22), value: model.showTodos)
            .overlay(alignment: .trailing) {
                if model.selectedId != nil {
                    DetailPanel().transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.22), value: model.selectedId)
        }
    }

    private struct CardStyle { var highlight: Color?; var dimmed: Bool }

    private func cardStyle(_ s: Session) -> CardStyle {
        if let p = model.pending, p.sessionId == s.id { return CardStyle(highlight: Theme.accent, dimmed: false) }
        if model.listening, let t = model.replyTarget { return CardStyle(highlight: t == s.id ? Theme.listen : nil, dimmed: t != s.id) }
        if model.listening { return CardStyle(highlight: nil, dimmed: true) }
        if let ids = model.currentCaptionIds, !ids.isEmpty {
            return CardStyle(highlight: ids.contains(s.id) ? SessionStatus.done.color : nil, dimmed: !ids.contains(s.id))
        }
        return CardStyle(highlight: nil, dimmed: false)
    }

    private func lineColor(_ s: Session, _ style: CardStyle) -> Color {
        if let h = style.highlight { return h }
        if s.status == .needs { return s.status.color.opacity(0.55) }
        return Theme.line
    }

    private var avatarTitle: String {
        switch model.avatar {
        case .listening: return L("Listening…")
        case .thinking: return L("Thinking…")
        case .speaking: return L("Speaking")
        case .idle: return L("Claude")
        }
    }

    private var avatarSubtitle: String {
        switch model.avatar {
        case .listening:
            if let t = model.session(model.replyTarget) { return ui("Reply to \(t.spokenName)", "Antwort an \(t.spokenName)") }
            return L("Let go to send")
        case .thinking: return model.heard.map { "“\($0)”" } ?? L("Working it out")
        case .speaking: return L("Talk or press Esc to interrupt")
        case .idle:
            let n = model.sessions.count
            if model.isMuted { return L("Quiet") + " · " + UIText.watching(n) }
            return n == 0 ? L("No sessions open") : UIText.watching(n)
        }
    }
}

struct SessionCard: View {
    var session: Session
    var menuCount: Int = 0
    var selected: Bool
    var highlight: Color?
    var dimmed: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                StatusBadge(status: session.status, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(session.statusLine).font(.system(size: 12)).foregroundColor(session.status.color).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(session.metaLine).font(Theme.mono()).foregroundColor(Theme.faint).lineLimit(1)
                        if menuCount > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "checklist").font(.system(size: 9, weight: .bold))
                                Text("\(menuCount)").font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(SessionStatus.done.color)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(Capsule().fill(SessionStatus.done.color.opacity(0.15)))
                            .help(ui("\(menuCount) open on the menu", "\(menuCount) offen im Menü"))
                        }
                    }
                }
                Spacer(minLength: 0)
                if let k = session.shortcut {
                    Text(k).font(Theme.mono()).foregroundColor(Theme.faint)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 84)
            .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Theme.surfaceHi : (hover ? Theme.raised : Theme.surface)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(border, lineWidth: highlight != nil ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if session.unseen {
                    Circle()
                        .fill(session.status.color)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                        .offset(x: 5, y: -5)
                        .help(L("Not seen yet"))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.text)
        .opacity(dimmed ? 0.45 : 1)
        .onHover { hover = $0 }
        .help(session.cwd)
    }

    private var border: Color {
        if let h = highlight { return h }
        if selected { return session.status.color }
        if session.status == .needs { return session.status.color.opacity(0.6) }
        return Theme.border
    }
}

struct Legend: View {
    var body: some View {
        HStack(spacing: 16) {
            item(.needs, L("Needs you"))
            item(.done, L("Done, not seen"))
            item(.working, L("Working"))
            item(.shell, L("Waiting on a shell"))
            item(.failed, L("Failed"))
            item(.idle, L("Idle"))
        }
    }

    private func item(_ s: SessionStatus, _ label: String) -> some View {
        HStack(spacing: 6) {
            StatusGlyph(status: s, size: 12)
            Text(label).font(.system(size: 11)).foregroundColor(Theme.muted)
        }
    }
}

// MARK: - Detail

struct DetailPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let s = model.selected {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    StatusChip(status: s.status, text: "\(UIText.status(s.status)) · \(timeText(s))")
                    Spacer()
                    Button { model.selectedId = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 38, height: 38)
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .help(L("Close (Esc)"))
                }
                // Long summaries scroll here; they must never make the window grow.
                ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.title).font(.system(size: 19, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text((s.cwd as NSString).abbreviatingWithTildeInPath).font(Theme.mono(12)).foregroundColor(Theme.faint)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(L("Where it stands"))
                    if let text = model.summaries[s.id] {
                        Text(text).font(.system(size: 14)).foregroundColor(Theme.body).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(s.statusLine).font(.system(size: 14)).foregroundColor(Theme.muted)
                        }
                    }
                }
                if let p = s.lastPrompt {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(L("Your last prompt") + (s.lastPromptAt.map { " · " + Fmt.ago($0) } ?? ""))
                        Text(p).font(.system(size: 13)).foregroundColor(Color(hex: 0xC3C5CA)).lineSpacing(2)
                            .lineLimit(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                    }
                }
                SessionMenuSection(session: s)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                VStack(spacing: 10) {
                    Button { model.focus(s) } label: {
                        HStack(spacing: 10) {
                            Text(L("Open in Ghostty"))
                            if let k = s.shortcut { Text(k).font(Theme.mono(12)).opacity(0.8) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    HStack(spacing: 10) {
                        HoldToTalk(onDown: { model.pttDown(target: s.id) }, onUp: { model.pttUp() }) { pressed in
                            Label(pressed ? L("Listening…") : L("Hold to reply"), systemImage: "mic")
                                .frame(maxWidth: .infinity)
                                .modifier(SecondaryLook(active: pressed))
                        }
                        Button { model.readAloud(s) } label: {
                            Label(L("Read aloud"), systemImage: "speaker.wave.2").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    let closing = s.status == .done || s.status == .failed || s.status == .idle
                    Button { model.propose(closing ? .close : .stop, sessionId: s.id) } label: {
                        Text(closing ? L("Close session") : L("Stop this turn (sends Esc)")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DangerButtonStyle())
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(width: 360)
            .frame(maxHeight: .infinity)
            .background(Theme.panel)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
            .task(id: s.id) { await model.ensureSummary(s.id) }
        }
    }

    private func timeText(_ s: Session) -> String {
        switch s.status {
        case .done, .failed: return Fmt.ago(s.outcomeAt ?? s.since)
        default: return Fmt.duration(s.since)
        }
    }
}

struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(Theme.muted)
    }
}

// MARK: - Footer

struct FooterBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 18) {
            MicButton(size: 56)
            VStack(alignment: .leading, spacing: 5) {
                if model.hotkeyOK {
                    HStack(spacing: 4) {
                        Text(L("Hold"))
                        Kbd(L("Space"))
                        Text(L("and talk"))
                    }
                    .font(.system(size: 14, weight: .semibold))
                } else {
                    Text(L("Hold Space here (⌥ Space is taken by another app)"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SessionStatus.needs.color)
                }
                Text(lastHeard).font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
            }
            .frame(minWidth: 200, alignment: .leading)
            HStack(spacing: 8) {
                Button(L("What needs me?")) { model.askNeeds() }.buttonStyle(ChipButtonStyle())
                Button(L("Summarize all")) { model.briefing() }.buttonStyle(ChipButtonStyle())
                Button(L("Start a session")) { model.openNewSession() }.buttonStyle(ChipButtonStyle())
            }
            .focusable(false)
            .focusEffectDisabled()
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Toggle(isOn: $model.speakOnDone) {
                    Text(L("Speak when a session finishes")).font(.system(size: 13))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Menu {
                    Picker(L("Spoken language"), selection: $model.languageSetting) {
                        ForEach(AppModel.LanguageSetting.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    if model.el.isConfigured {
                        Section(L("English voice")) {
                            ForEach(model.voices.filter { $0.language == nil || $0.language == "en" }) { v in
                                Button { model.voiceId = v.id; model.useSystemVoice(false) } label: {
                                    if v.id == model.voiceId { Label(v.name, systemImage: "checkmark") } else { Text(v.name) }
                                }
                            }
                        }
                        Section(L("German voice (for German sessions and replies)")) {
                            ForEach(model.voices.filter { $0.language == "de" }) { v in
                                Button { model.voiceIdDE = v.id; model.useSystemVoice(false) } label: {
                                    if v.id == model.voiceIdDE { Label(v.name, systemImage: "checkmark") } else { Text(v.name) }
                                }
                            }
                        }
                        Divider()
                    }
                    Button(L("Mac voice (free)")) { model.useSystemVoice(true) }
                    if model.isMuted { Button(L("Talk again")) { model.mutedUntil = nil } }
                    else { Button(L("Be quiet for an hour")) { model.mutedUntil = Date().addingTimeInterval(3600) } }
                    Toggle(L("Only tell me when something needs me"), isOn: $model.onlyNeeds)
                    Divider()
                    Toggle(L("Open at login"), isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                } label: {
                    Text(voiceLine).font(.system(size: 12)).foregroundColor(Theme.faint)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 96)
        .background(Theme.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var lastHeard: String {
        if model.micDenied { return L("Microphone access is off (System Settings › Privacy › Microphone)") }
        guard let h = model.heard, let at = model.heardAt else {
            return model.hotkeyOK ? L("⌥ Space works from any app, too") : L("Ask “what needs me?” or “summarize everything”")
        }
        return ui("Last heard", "Zuletzt gehört") + ": “\(h)” · \(Fmt.ago(at))"
    }

    private var voiceLine: String {
        var s = ui("Voice", "Stimme") + ": \(model.voiceName)"
        if !model.usingSystemVoice, let c = model.charsLeft {
            let n = c >= 1000 ? String(format: "%.1fk", Double(c) / 1000) : "\(c)"
            s += " · " + ui("\(n) chars left", "\(n) Zeichen übrig")
        }
        if model.languageSetting != .auto { s += model.languageSetting == .de ? " · Deutsch" : " · English" }
        if model.isMuted { s += " · " + ui("quiet", "still") }
        if model.onlyNeeds { s += " · " + ui("only needs", "nur Wichtiges") }
        return s
    }
}

struct Kbd: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.mono(12).weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.borderHi, lineWidth: 1))
    }
}

/// Press-and-hold control: fires onDown when pressed, onUp when released.
struct HoldToTalk<Label: View>: View {
    var onDown: () -> Void
    var onUp: () -> Void
    @ViewBuilder var label: (Bool) -> Label
    @State private var pressed = false

    var body: some View {
        label(pressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed { pressed = true; onDown() }
                    }
                    .onEnded { _ in
                        pressed = false
                        onUp()
                    }
            )
            .accessibilityAddTraits(.isButton)
    }
}

struct MicButton: View {
    @EnvironmentObject var model: AppModel
    var size: CGFloat
    @Environment(\.animating) private var animating

    var body: some View {
        HoldToTalk(onDown: { model.pttDown() }, onUp: { model.pttUp() }) { _ in
            ZStack {
                Circle().fill(model.listening ? Theme.listen : Theme.accent)
                Image(systemName: "mic.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundColor(model.listening ? Color(hex: 0x0E1A2C) : Theme.ink)
            }
            .frame(width: size, height: size)
            .overlay {
                if model.listening {
                    TimelineView(.animation(minimumInterval: 1 / 24, paused: !animating)) { ctx in
                        let p = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Circle().stroke(Theme.listen.opacity(0.6 * (1 - p)), lineWidth: 3).scaleEffect(1 + 0.3 * p)
                    }
                }
            }
        }
        .help(L("Hold to talk"))
        .accessibilityLabel(Text(L("Hold to talk")))
    }
}

// MARK: - Overlays

struct OverlayLayer: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let drawer: CGFloat = model.selectedId != nil ? 360 : 0
        ZStack {
            VStack {
                Spacer()
                Group {
                    if model.listening || model.thinking {
                        ListeningPanel()
                    } else if let p = model.pending, p.kind != .newSession {
                        ConfirmCard(action: p)
                    } else if !model.captions.isEmpty {
                        CaptionsPanel()
                    }
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .padding(.trailing, drawer)
            .padding(.leading, model.showTodos ? TodoPanel.width : 0)

            if let p = model.pending, p.kind == .newSession {
                Color.black.opacity(0.6)
                    .onTapGesture { model.cancelPending() }
                NewSessionCard(action: p)
                    .frame(width: 600)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }

            VStack {
                if let t = model.toast {
                    Text(t)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.raised))
                        .overlay(Capsule().stroke(Theme.borderHi, lineWidth: 1))
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.listening)
        .animation(.easeOut(duration: 0.2), value: model.thinking)
        .animation(.easeOut(duration: 0.2), value: model.pending?.id)
        .animation(.easeOut(duration: 0.2), value: model.captions)
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }
}

struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0x33363C), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
    }
}

struct ListeningPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(model.listening ? Color(hex: 0x8DBBFF) : Theme.accentLight).frame(width: 7, height: 7)
                SectionLabel(model.listening ? L("Listening") : L("Heard"))
                if let t = model.session(model.replyTarget) {
                    Text(ui("· reply to \(t.spokenName)", "· Antwort an \(t.spokenName)")).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.listen)
                }
                Spacer()
                if model.thinking { ProgressView().controlSize(.small) }
            }
            if model.listening {
                Waveform(level: { model.recorder.level }, color: Theme.listen)
                    .frame(height: 40)
                Text(L("Let go to send · Esc cancels")).font(.system(size: 12)).foregroundColor(Theme.muted)
            } else {
                Text(model.heard.map { "“\($0)”" } ?? L("Transcribing…"))
                    .font(.system(size: 19, weight: .medium))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.heard == nil ? L("Turning your voice into text") : L("Working out what you mean"))
                    .font(.system(size: 12)).foregroundColor(Theme.muted)
            }
        }
        .modifier(PanelBackground())
    }
}

struct Waveform: View {
    var level: () -> Float
    var color: Color
    var bars = 36
    @Environment(\.animating) private var animating

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !animating)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let l = CGFloat(level())
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<bars, id: \.self) { i in
                    let wobble = 0.55 + 0.45 * sin(t * 9 + Double(i) * 0.7)
                    let shape = 0.5 + 0.5 * sin(Double(i) * 0.9 + 1)
                    Capsule()
                        .fill(color)
                        .frame(width: 4, height: max(4, 38 * l * CGFloat(wobble) * CGFloat(shape) + 4))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct ConfirmCard: View {
    @EnvironmentObject var model: AppModel
    var action: PendingAction

    var body: some View {
        let s = model.session(action.sessionId)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let s { StatusGlyph(status: s.status, size: 14) }
                Text(title(s)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if let k = s?.shortcut { Text(k).font(Theme.mono()).foregroundColor(Theme.muted) }
                Spacer()
            }
            if action.kind == .send {
                Text("“\(action.prompt)”").font(.system(size: 15)).foregroundColor(Theme.body)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(detail).font(.system(size: 13)).foregroundColor(Theme.muted)
            }
            Countdown(action: action, verb: verb)
            HStack(spacing: 10) {
                Spacer()
                Button { model.cancelPending() } label: {
                    HStack(spacing: 8) { Text(L("Cancel")); Text(L("Esc")).font(Theme.mono()).foregroundColor(Theme.muted) }
                }
                .buttonStyle(SecondaryButtonStyle())
                Button { model.confirmPending() } label: {
                    HStack(spacing: 8) { Text(confirmTitle); Text(L("↩")).font(Theme.mono(12)).opacity(0.8) }
                }
                .buttonStyle(PrimaryButtonStyle(destructive: action.kind == .close))
                .keyboardShortcut(.defaultAction)
            }
        }
        .modifier(PanelBackground())
    }

    private func title(_ s: Session?) -> String {
        let name = s?.spokenName ?? L("the session")
        switch action.kind {
        case .send: return ui("Send to \(name)", "An \(name) senden")
        case .stop: return ui("Stop \(name)?", "\(name) stoppen?")
        case .close: return ui("Close \(name)?", "\(name) schließen?")
        case .newSession: return L("New session")
        }
    }

    private var detail: String {
        switch action.kind {
        case .stop: return L("Presses Esc in its tab, which interrupts what it is doing.")
        case .close: return L("Types /exit in its tab and then closes the tab.")
        default: return L("")
        }
    }

    private var verb: String {
        switch action.kind {
        case .send: return L("Sending")
        case .stop: return L("Stopping")
        case .close: return L("Closing")
        case .newSession: return L("Starting")
        }
    }

    private var confirmTitle: String {
        switch action.kind {
        case .send: return L("Send now")
        case .stop: return L("Stop now")
        case .close: return L("Close session")
        case .newSession: return L("Start now")
        }
    }
}

struct Countdown: View {
    var action: PendingAction
    var verb: String
    @Environment(\.animating) private var animating

    var body: some View {
        if let total = action.countdown {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: !animating)) { ctx in
                let elapsed = ctx.date.timeIntervalSince(action.started)
                let left = max(0, total - elapsed)
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.line)
                            Capsule().fill(Theme.accent).frame(width: g.size.width * CGFloat(left / total))
                        }
                    }
                    .frame(height: 4)
                    Text(UIText.countdown(verb, Int(ceil(left))))
                        .font(.system(size: 12)).foregroundColor(Theme.muted)
                }
            }
        } else {
            Text(L("Waiting for you to confirm.")).font(.system(size: 12)).foregroundColor(Theme.muted)
        }
    }
}

struct CaptionsPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(model.captions.prefix(5).enumerated()), id: \.element.id) { i, c in
                let now = model.captionIndex == i
                let spoken = (model.captionIndex ?? -1) > i
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(spoken ? "✓" : "\(i + 1)")
                        .font(Theme.mono(12).weight(.bold))
                        .foregroundColor(now ? SessionStatus.done.color : Theme.faint)
                        .frame(width: 18, alignment: .leading)
                    Text(c.text)
                        .font(.system(size: now ? 16 : 13, weight: now ? .medium : .regular))
                        .foregroundColor(now ? Theme.text : (spoken ? Theme.faint : Theme.muted))
                        .lineLimit(now ? 4 : 1)
                        .fixedSize(horizontal: false, vertical: now)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L("Skip")) { model.speaker.skip() }.buttonStyle(ChipButtonStyle())
                Button { model.stopSpeaking() } label: {
                    HStack(spacing: 8) { Text(L("Stop talking")); Text(L("Esc")).font(Theme.mono()).foregroundColor(Theme.muted) }
                }
                .buttonStyle(ChipButtonStyle())
            }
        }
        .modifier(PanelBackground())
    }
}

struct NewSessionCard: View {
    @EnvironmentObject var model: AppModel
    var action: PendingAction

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                MiniAvatar(mode: .idle, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("New session")).font(.system(size: 17, weight: .semibold))
                    Text(action.heard != nil ? L("From what you just said · check it, or let it start") : L("Opens a new Ghostty tab running claude"))
                        .font(.system(size: 12)).foregroundColor(Theme.muted)
                }
            }
            if let h = action.heard {
                Text("“\(h)”")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x23252A)))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Folder")).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.muted)
                Menu {
                    ForEach(model.folders.prefix(25), id: \.self) { f in
                        Button((f as NSString).abbreviatingWithTildeInPath) { model.updatePending(folder: f) }
                    }
                    Divider()
                    Button(L("Choose another folder…")) { chooseFolder() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder").foregroundColor(Theme.muted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((action.folder as NSString).lastPathComponent).font(.system(size: 14, weight: .semibold))
                            Text((action.folder as NSString).abbreviatingWithTildeInPath).font(Theme.mono()).foregroundColor(Theme.faint)
                        }
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.muted)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0x3A3D43), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("First prompt")).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.muted)
                TextField(L("Optional: what should it start on?"), text: Binding(
                    get: { model.pending?.prompt ?? "" },
                    set: { model.updatePending(prompt: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0x3A3D43), lineWidth: 1))
            }
            HStack(spacing: 12) {
                info(L("Opens in"), L("New Ghostty tab"))
                info(L("Runs"), L("claude, with your usual settings"))
            }
            Countdown(action: action, verb: L("Starting"))
            HStack(spacing: 10) {
                Spacer()
                Button { model.cancelPending() } label: {
                    HStack(spacing: 8) { Text(L("Cancel")); Text(L("Esc")).font(Theme.mono()).foregroundColor(Theme.muted) }
                }
                .buttonStyle(SecondaryButtonStyle())
                Button { model.confirmPending() } label: {
                    HStack(spacing: 8) { Text(L("Start now")); Text(L("↩")).font(Theme.mono(12)).opacity(0.8) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.borderHi, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
    }

    private func info(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundColor(Theme.faint)
            Text(value).font(.system(size: 13, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x202226)))
    }

    private func chooseFolder() {
        model.holdPending()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: action.folder)
        if panel.runModal() == .OK, let url = panel.url { model.updatePending(folder: url.path) }
    }
}

// MARK: - Help

struct HelpView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var groups: [(String, SessionStatus, [(String, String)])] {[
        (ui("Ask", "Fragen"), .working, [
            (ui("“What needs me?”", "„Was braucht mich?“"), ui("Reads out only the sessions waiting on you.", "Liest nur die Sessions vor, die auf dich warten.")),
            (ui("“Summarize everything”", "„Fass alles zusammen“"), ui("A short spoken briefing, most urgent first.", "Ein kurzes gesprochenes Briefing, Dringendes zuerst.")),
            (ui("“What did the Outlook one do?”", "„Was hat die Outlook-Session gemacht?“"), ui("Where one session stands, in a sentence or two.", "Wo eine Session steht, in ein, zwei Sätzen.")),
        ]),
        (ui("Steer", "Steuern"), .done, [
            (ui("“Tell the fleet cleanup to also check the settings page”", "„Sag dem Fleet-Cleanup, es soll auch die Einstellungsseite prüfen“"),
             ui("Types that as the next prompt in its tab, after 3 s.", "Tippt das nach 3 s als nächsten Prompt in ihren Tab.")),
            (ui("“Open the dashboard one”", "„Öffne die Dashboard-Session“"), ui("Brings its Ghostty tab to the front.", "Holt ihren Ghostty-Tab nach vorn.")),
            (ui("“Repeat that”", "„Nochmal“"), ui("Says the last thing again.", "Sagt das Letzte noch einmal.")),
            (ui("“Speak German” / “Speak English”", "„Sprich Deutsch“ / „Sprich Englisch“"), ui("Sets the language I talk in, for every session.", "Legt fest, in welcher Sprache ich spreche, für alle Sessions.")),
        ]),
        (ui("Start and stop", "Starten und stoppen"), .needs, [
            (ui("“Start a session in claude-hub: …”", "„Starte eine Session in claude-hub: …“"), ui("A new Ghostty tab running claude with that prompt.", "Ein neuer Ghostty-Tab, in dem claude mit diesem Prompt startet.")),
            (ui("“Stop the deploy one”", "„Stopp die Deploy-Session“"), ui("Presses Esc in its tab to interrupt it.", "Drückt Esc in ihrem Tab und unterbricht sie.")),
            (ui("“Close the Outlook session”", "„Schließ die Outlook-Session“"), ui("Ends it and closes the tab, after you confirm.", "Beendet sie und schließt den Tab, nachdem du bestätigst.")),
        ]),
        (ui("Quiet", "Ruhe"), .shell, [
            (ui("“Only tell me when something needs me”", "„Sag mir nur Bescheid, wenn mich etwas braucht“"), ui("No more “done” announcements.", "Keine „fertig“-Ansagen mehr.")),
            (ui("“Be quiet for an hour”", "„Sei eine Stunde still“"), ui("Mutes announcements; the orbit keeps updating.", "Schaltet Ansagen stumm; der Orbit zeigt weiter alles an.")),
            (ui("“You can talk again”", "„Du kannst wieder reden“"), ui("Back to normal.", "Wieder wie vorher.")),
        ]),
    ]}

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                MiniAvatar(mode: .idle, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("What you can say")).font(.system(size: 22, weight: .semibold))
                    HStack(spacing: 4) {
                        Text(L("Hold")); Kbd(L("Space")); Text(L("in this window or")); Kbd(L("⌥ Space")); Text(L("anywhere, say it, let go."))
                    }
                    .font(.system(size: 13)).foregroundColor(Theme.muted)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 38, height: 38)
                }
                .buttonStyle(OutlineButtonStyle())
                .keyboardShortcut(.cancelAction)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24, alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 28) {
                ForEach(groups, id: \.0) { title, status, items in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(title.uppercased()).font(.system(size: 12, weight: .bold)).tracking(0.6).foregroundColor(status.color)
                        ForEach(items, id: \.0) { say, does in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(say).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                                Text(does).font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            Text(L("Sessions are matched loosely: “the fleet one”, “the dashboard session” and “number three” all work. When it isn’t clear which one you mean, I ask instead of guessing."))
                .font(.system(size: 13)).foregroundColor(Color(hex: 0xC9CBD0))
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x23252A)))
        }
        .padding(32)
        .frame(width: 720)
        .background(Theme.card)
        .foregroundColor(Theme.text)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Button styles

struct PrimaryButtonStyle: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Theme.ink)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(destructive ? Color(hex: 0xFF8A80) : Theme.accent))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

struct SecondaryLook: ViewModifier {
    var active = false
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .foregroundColor(Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? Theme.listen.opacity(0.25) : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Theme.listen : Theme.border, lineWidth: 1))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(SecondaryLook())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(Theme.danger)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10).stroke(Theme.danger.opacity(0.4), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(configuration.isPressed ? Theme.raised : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .focusEffectDisabled()
    }
}

struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? Theme.raised : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Theme.text)
            .background(RoundedRectangle(cornerRadius: 10).fill(configuration.isPressed ? Theme.raised : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

// MARK: - Tasks and the menu

/// Task Tracker inside the orbit window: the open tasks, and the menu of checks and ideas
/// agents left on their PRs. The ⌃⌥T popover shows the same store and menu.
struct TodoPanel: View {
    static let width: CGFloat = 330
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $model.showWork) {
                Text(L("Tasks") + countText(model.todos.count)).tag(AppModel.WorkTab.tasks)
                Text(L("Menu") + countText(model.menuPanel?.openCount ?? 0)).tag(AppModel.WorkTab.menu)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            switch model.showWork {
            case .tasks: TaskList()
            case .menu:
                if let menu = model.menuPanel {
                    MenuView(panel: menu)
                        .onAppear { menu.didOpen() }
                }
            }
        }
        .frame(width: TodoPanel.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func countText(_ n: Int) -> String { n > 0 ? "  \(n)" : "" }
}

private struct TaskList: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = ""
    @FocusState private var adding: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.muted)
                TextField(L("Add a task"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($adding)
                    .onSubmit {
                        model.addTask(draft)
                        draft = ""
                        adding = true
                    }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(adding ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: 1))
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            if let problem = model.tasks?.problem {
                Text(problem).font(.system(size: 12)).foregroundColor(SessionStatus.needs.color)
                    .padding(.horizontal, 18).padding(.vertical, 6)
            }
            let todos = model.todos
            if todos.isEmpty {
                Text(L("No open tasks. Add one above, or with ⌃⌥T from any app."))
                    .font(.system(size: 13))
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        stage(todos, .inProgress, L("In Progress"))
                        stage(todos, .todo, L("Todo"))
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
            Spacer(minLength: 0)
            Text(L("Right-click a task to start a session with it or paste it into one. Nothing is sent until you press Return."))
                .font(.system(size: 11))
                .foregroundColor(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func stage(_ todos: [Todo], _ stage: Todo.Stage, _ title: String) -> some View {
        let items = todos.filter { $0.stage == stage }
        if !items.isEmpty {
            SectionLabel(title)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 2)
            ForEach(items) { TodoRow(todo: $0) }
        }
    }
}

struct TodoRow: View {
    var todo: Todo
    @EnvironmentObject var model: AppModel
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { model.setStage(todo, .done) } label: {
                Circle()
                    .strokeBorder(todo.stage == .inProgress ? SessionStatus.working.color : Theme.faint, lineWidth: 1.5)
                    .background(Circle().fill(todo.stage == .inProgress ? SessionStatus.working.color.opacity(0.3) : .clear))
                    .overlay {
                        if hover { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundColor(Theme.muted) }
                    }
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            .help(L("Mark done"))
            VStack(alignment: .leading, spacing: 3) {
                Text(todo.title).font(.system(size: 13)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let meta = meta {
                    Text(meta).font(.system(size: 11)).foregroundColor(Theme.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Theme.raised : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { model.openInTaskList(todo) }
        .help(todo.title)
        .contextMenu {
            Menu(L("Start a new session with it")) {
                ForEach(model.folders.prefix(12), id: \.self) { f in
                    Button((f as NSString).lastPathComponent + "   " + (f as NSString).abbreviatingWithTildeInPath) {
                        model.startSession(with: todo, in: f)
                    }
                }
                Divider()
                Button(L("Choose a folder…")) { chooseFolder() }
            }
            Menu(L("Paste into a session")) {
                if model.sessions.isEmpty { Text(L("No sessions open")) }
                ForEach(model.sessions) { s in
                    Button((s.shortcut.map { $0 + "  " } ?? "") + s.title) { model.paste(todo, into: s) }
                        .disabled(s.tty == nil || s.status == .needs)
                }
            }
            Divider()
            if todo.stage == .todo {
                Button(L("Move to In Progress")) { model.setStage(todo, .inProgress) }
            } else {
                Button(L("Move to Todo")) { model.setStage(todo, .todo) }
            }
            Button(L("Defer")) { model.setStage(todo, .deferred) }
            Button(L("Mark done")) { model.setStage(todo, .done) }
            Divider()
            Button(L("Open in the task list (⌃⌥T)")) { model.openInTaskList(todo) }
            Button(L("Copy")) { model.copyToClipboard(todo.pasteText) }
        }
    }

    private var meta: String? {
        var parts: [String] = []
        if let f = todo.folder { parts.append(f) }
        if !todo.images.isEmpty {
            parts.append(ui(todo.images.count == 1 ? "1 image" : "\(todo.images.count) images",
                            todo.images.count == 1 ? "1 Bild" : "\(todo.images.count) Bilder"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.folders.first.map { URL(fileURLWithPath: $0) }
        if panel.runModal() == .OK, let url = panel.url { model.startSession(with: todo, in: url.path) }
    }
}

// MARK: - A session's checks and ideas

/// In a session's detail: what's on the menu for the PRs this session opened.
struct SessionMenuSection: View {
    var session: Session
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let menu = model.menuPanel {
            let groups = menu.groups(forSession: session.id).filter { g in g.items.contains { !$0.status.isSettled } }
            if !groups.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(L("On the menu"))
                    ForEach(groups, id: \.pr.id) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text("#\(group.pr.number)").font(Theme.mono(12)).foregroundColor(Theme.faint)
                                Text(group.pr.title ?? group.pr.repo).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                                if group.items.contains(where: { $0.status == .problem }) {
                                    Button(L("Fix in its session")) { menu.fix(group.pr) }
                                        .buttonStyle(ChipButtonStyle())
                                        .disabled(menu.isBusy(group.pr.id))
                                }
                            }
                            ForEach(group.items.filter { !$0.status.isSettled }) { item in
                                MenuItemRow(item: item, menu: menu)
                            }
                        }
                    }
                    if let message = menu.message {
                        Text(message).font(.system(size: 12))
                            .foregroundColor(menu.messageIsError ? Theme.danger : Theme.muted)
                    }
                }
            }
        }
    }
}

private struct MenuItemRow: View {
    var item: MenuItem
    @Bindable var menu: MenuPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.kind == .check ? "checkmark.circle" : "lightbulb")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(item.kind == .check ? SessionStatus.done.color : SessionStatus.needs.color)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.text).font(.system(size: 13)).foregroundColor(Theme.body).fixedSize(horizontal: false, vertical: true)
                    let meta = [item.location, item.minutes.map { "\($0) min" }, item.status == .open ? nil : item.status.label]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !meta.isEmpty { Text(meta).font(.system(size: 11)).foregroundColor(Theme.faint) }
                }
            }
            if menu.reportingID == item.id {
                TextField(L("What went wrong?"), text: $menu.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                HStack(spacing: 6) {
                    Spacer()
                    Button(L("Cancel")) { menu.cancelProblem() }.buttonStyle(ChipButtonStyle())
                    Button(L("Send to the PR")) { menu.sendProblem(item) }.buttonStyle(ChipButtonStyle())
                        .disabled(menu.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || menu.isBusy(item.id))
                }
            } else if item.status == .open || item.status == .later {
                HStack(spacing: 6) {
                    if item.kind == .check {
                        Button(L("Works")) { menu.setStatus(item, .works) }.buttonStyle(MiniButtonStyle())
                        Button(L("Problem…")) { menu.beginProblem(item) }.buttonStyle(MiniButtonStyle())
                    } else {
                        Button(L("Make issue")) { menu.makeIssue(item) }.buttonStyle(MiniButtonStyle())
                            .disabled(menu.isBusy(item.id))
                    }
                    if item.status != .later {
                        Button(L("Later")) { menu.setStatus(item, .later) }.buttonStyle(MiniButtonStyle())
                    }
                    Button(L("Dismiss")) { menu.setStatus(item, .dismissed) }.buttonStyle(MiniButtonStyle())
                    if item.openURL != nil {
                        Button(L("Open")) { menu.open(item) }.buttonStyle(MiniButtonStyle())
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
    }
}

struct MiniButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(Theme.text)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(configuration.isPressed ? Theme.raised : Theme.surfaceHi))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}
