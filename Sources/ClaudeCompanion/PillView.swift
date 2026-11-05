import SwiftUI

struct PillMetrics: Equatable {
    var hasNotch: Bool
    var notchWidth: CGFloat
    var stripHeight: CGFloat

    static let wing: CGFloat = 118
    static let expandedWidth: CGFloat = 460

    var collapsedWidth: CGFloat { hasNotch ? notchWidth + 2 * PillMetrics.wing : 320 }
}

/// What the pill shows under its strip when something is going on.
enum PillActivity: Equatable {
    case listening, thinking, pending, caption

    var height: CGFloat {
        switch self {
        case .listening: return 78
        case .thinking: return 78
        case .pending: return 150
        case .caption: return 104
        }
    }
}

/// The companion folded into the notch: status at a glance, a list on click.
struct PillView: View {
    @EnvironmentObject var model: AppModel
    let metrics: PillMetrics

    static let rowHeight: CGFloat = 50
    static let maxRows = 8

    @MainActor static func activity(_ m: AppModel) -> PillActivity? {
        if m.listening { return .listening }
        if m.thinking { return .thinking }
        if m.pending != nil { return .pending }
        if !m.captions.isEmpty, m.captionIndex != nil { return .caption }
        return nil
    }

    @MainActor static func size(_ m: AppModel, _ metrics: PillMetrics) -> CGSize {
        let act = activity(m)
        let open = m.pillExpanded || act != nil
        var h = metrics.stripHeight
        if let act { h += act.height + 8 }
        if m.pillExpanded {
            h += 14 + 46 + 12 + listHeight(m) + 12 + 40 + 16
        }
        let w = open ? max(metrics.collapsedWidth, expandedWidth) : metrics.collapsedWidth
        return CGSize(width: w, height: h)
    }

    static var expandedWidth: CGFloat { PillMetrics.expandedWidth }

    static let sectionHeight: CGFloat = 24

    static let workspaceRowHeight: CGFloat = 38

    /// Too many sessions for a list, in workspaces: what needs you on top, then a line per
    /// workspace that opens to its sessions.
    @MainActor static func folded(_ m: AppModel) -> Bool { m.tree.hasWorkspaces && m.sessions.count > maxRows }

    /// Folded: the workspaces' lines (loose projects are one more line), and their sessions
    /// that aren't already on top.
    @MainActor static func foldedGroups(_ m: AppModel) -> [(id: String, name: String, sessions: [Session])] {
        var out = m.tree.workspaces.filter { !$0.repos.isEmpty }.map { (id: $0.id, name: $0.name, sessions: $0.sessions) }
        let loose = m.tree.loose.flatMap(\.sessions)
        if !loose.isEmpty { out.append((id: "", name: ui("Other projects", "Andere Projekte"), sessions: loose)) }
        return out
    }

    @MainActor static func urgent(_ m: AppModel) -> [Session] { Array(m.sessions.filter(\.isUrgent).prefix(4)) }

    /// The session list's height: every row (and project heading) up to `maxRows` rows' worth;
    /// past that it scrolls.
    @MainActor static func listHeight(_ m: AppModel) -> CGFloat {
        let row = rowHeight + 4
        let cap = CGFloat(maxRows) * row
        if folded(m) {
            let top = urgent(m)
            let onTop = Set(top.map(\.id))
            var h = top.isEmpty ? 0 : sectionHeight + CGFloat(top.count) * row
            for g in foldedGroups(m) {
                h += workspaceRowHeight + 4
                if m.pillOpen.contains(g.id) { h += CGFloat(g.sessions.filter { !onTop.contains($0.id) }.count) * row }
            }
            return min(cap, h)
        }
        guard let groups = m.projectGroups else { return CGFloat(max(1, min(maxRows, m.sessions.count))) * row }
        let shown = groups.filter { !m.collapsedProjects.contains($0.id) }.reduce(0) { $0 + $1.sessions.count }
        return min(cap, CGFloat(groups.count) * sectionHeight + CGFloat(shown) * row)
    }

    var body: some View {
        let act = PillView.activity(model)
        let open = model.pillExpanded || act != nil
        VStack(spacing: 0) {
            strip
            if let act {
                activityView(act)
                    .frame(height: act.height, alignment: .top)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
            }
            if model.pillExpanded { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .clipShape(shape(open))
        .foregroundColor(Theme.text)
        .environment(\.colorScheme, .dark)
        .environment(\.animating, model.pillVisible)
        .focusEffectDisabled()
        .id(model.uiLanguage)
    }

    private func shape(_ open: Bool) -> some Shape {
        if metrics.hasNotch {
            let r: CGFloat = open ? 24 : 12
            return AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r))
        }
        return AnyShape(RoundedRectangle(cornerRadius: open ? 20 : metrics.stripHeight / 2))
    }

    // MARK: strip

    private var strip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                MiniAvatar(mode: model.avatar, height: 18, level: { model.voiceLevel() })
                Text(stripText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(stripColor)
                    .lineLimit(1)
            }
            .frame(width: PillMetrics.wing - 14, alignment: .leading)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(model.sessions.prefix(7)) { s in StatusGlyph(status: s.status, size: 12) }
            }
            .frame(width: PillMetrics.wing - 14, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: metrics.stripHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.pillExpanded.toggle() }
        .help(L("Claude Companion: click for your sessions"))
    }

    private var stripText: String {
        switch model.avatar {
        case .listening: return L("Listening")
        case .thinking: return L("Thinking")
        case .speaking: return L("Speaking")
        case .idle: break
        }
        let s = model.sessions
        let needs = s.filter { $0.status == .needs }.count
        if needs > 0 { return UIText.count(.needs, needs) }
        let failed = s.filter { $0.status == .failed && $0.unseen }.count
        if failed > 0 { return UIText.count(.failed, failed) }
        let done = s.filter { $0.status == .done && $0.unseen }.count
        if done > 0 { return UIText.count(.done, done) }
        let working = s.filter { $0.status == .working }.count
        if working > 0 { return UIText.count(.working, working) }
        return L("Claude")
    }

    private var stripColor: Color {
        if model.avatar == .listening { return Theme.listen }
        if model.avatar != .idle { return Theme.accentLight }
        let s = model.sessions
        if s.contains(where: { $0.status == .needs }) { return SessionStatus.needs.color }
        if s.contains(where: { $0.status == .failed && $0.unseen }) { return SessionStatus.failed.color }
        if s.contains(where: { $0.status == .done && $0.unseen }) { return SessionStatus.done.color }
        if s.contains(where: { $0.status == .working }) { return SessionStatus.working.color }
        return Theme.muted
    }

    // MARK: activity

    @ViewBuilder
    private func activityView(_ a: PillActivity) -> some View {
        switch a {
        case .listening:
            VStack(alignment: .leading, spacing: 8) {
                Waveform(level: { model.recorder.level }, color: Theme.listen, bars: 30).frame(height: 30)
                Text(model.session(model.replyTarget).map { ui("Reply to \($0.spokenName) · let go to send", "Antwort an \($0.spokenName) · loslassen zum Senden") } ?? L("Listening · let go to send"))
                    .font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
            }
        case .thinking:
            HStack(alignment: .top, spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.heard.map { "“\($0)”" } ?? L("Transcribing…"))
                    .font(.system(size: 14, weight: .medium)).lineLimit(3)
                Spacer(minLength: 0)
            }
        case .pending:
            if let p = model.pending { pendingView(p) }
        case .caption:
            let targets = model.currentCaptionSessions
            VStack(alignment: .leading, spacing: 10) {
                if let i = model.captionIndex, model.captions.indices.contains(i) {
                    Text(model.captions[i].text).font(.system(size: 13)).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { if let s = targets.first { model.open(fromCaption: s) } }
                        .help(targets.isEmpty ? "" : L("Click to open it in Ghostty"))
                }
                HStack(spacing: 8) {
                    CaptionOpenButtons(targets: targets, pill: true)
                    Spacer()
                    if model.speaking {
                        Button(L("Skip")) { model.speaker.skip() }.buttonStyle(PillButtonStyle()).focusable(false)
                    }
                    Button(model.speaking ? L("Stop") : L("Close")) { model.stopSpeaking() }
                        .buttonStyle(PillButtonStyle()).focusable(false)
                }
            }
        }
    }

    private func pendingView(_ p: PendingAction) -> some View {
        let s = model.session(p.sessionId)
        let title: String
        let name = s?.spokenName ?? "Session"
        let folder = (p.folder as NSString).lastPathComponent
        switch p.kind {
        case .send: title = ui("Send to \(name)", "An \(name) senden")
        case .stop: title = ui("Stop \(name)?", "\(name) stoppen?")
        case .close: title = ui("Close \(name)?", "\(name) schließen?")
        case .newSession: title = ui("New session in \(folder)", "Neue Session in \(folder)")
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if !p.prompt.isEmpty {
                Text("“\(p.prompt)”").font(.system(size: 13)).foregroundColor(Theme.body).lineLimit(2)
            }
            Countdown(action: p, verb: p.kind == .newSession ? L("Starting") : L("Doing it"))
            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel")) { model.cancelPending() }.buttonStyle(PillButtonStyle()).focusable(false)
                Button(p.kind == .close ? L("Close") : L("Now")) { model.confirmPending() }.buttonStyle(PillButtonStyle(primary: true)).focusable(false)
            }
        }
    }

    // MARK: list

    private var list: some View {
        let s = model.sessions
        let needs = s.filter { $0.status == .needs }.count
        let done = s.filter { $0.status == .done && $0.unseen }.count
        let busy = s.filter { $0.status == .working || $0.status == .shell }.count
        let headline = needs > 0 ? UIText.thingsNeedYou(needs)
            : (s.isEmpty ? L("No sessions open") : L("Nothing needs you"))
        var sub: [String] = []
        if done > 0 { sub.append(ui("\(done) finished", "\(done) fertig")) }
        if busy > 0 { sub.append(ui("\(busy) still going", "\(busy) laufen noch")) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.system(size: 15, weight: .semibold))
                    Text(sub.isEmpty ? L("Hold ⌥ Space to talk") : sub.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundColor(Theme.muted)
                }
                Spacer()
                HoldToTalk(onDown: { model.pttDown() }, onUp: { model.pttUp() }) { pressed in
                    ZStack {
                        Circle().fill(pressed ? Theme.listen : Theme.accent)
                        Image(systemName: "mic.fill").font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.ink)
                    }
                    .frame(width: 44, height: 44)
                }
                .help(L("Hold to talk"))
            }
            .frame(height: 46)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    if PillView.folded(model) {
                        let top = PillView.urgent(model)
                        let onTop = Set(top.map(\.id))
                        if !top.isEmpty {
                            heading(L("Needs you"))
                            ForEach(top) { session in
                                Button { model.focus(session) } label: { row(session, place: true) }.buttonStyle(.plain)
                            }
                        }
                        ForEach(PillView.foldedGroups(model), id: \.id) { g in
                            workspaceRow(g.id, g.name, g.sessions)
                            if model.pillOpen.contains(g.id) {
                                ForEach(g.sessions.filter { !onTop.contains($0.id) }) { session in
                                    Button { model.focus(session) } label: { row(session) }.buttonStyle(.plain)
                                }
                            }
                        }
                    } else if let groups = model.projectGroups {
                        ForEach(groups) { g in
                            section(g)
                            if !model.collapsedProjects.contains(g.id) {
                                ForEach(g.sessions) { session in
                                    Button { model.focus(session) } label: { row(session) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    } else {
                        ForEach(s) { session in
                            Button { model.focus(session) } label: { row(session) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(height: PillView.listHeight(model))
            HStack(spacing: 8) {
                Button(L("Summarize all")) { model.briefing() }.buttonStyle(PillButtonStyle()).focusable(false)
                Button(L("What needs me?")) { model.askNeeds() }.buttonStyle(PillButtonStyle()).focusable(false)
                Spacer()
                Button(L("Open window")) { model.onOpenWindow?() }.buttonStyle(PillButtonStyle()).focusable(false)
            }
            .frame(height: 40)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    private func heading(_ text: String) -> some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundColor(Theme.faint)
            Spacer()
        }
        .padding(.horizontal, 4)
        .frame(height: PillView.sectionHeight - 4, alignment: .bottom)
    }

    /// One line for a workspace: how its sessions stand. Click it for the sessions.
    private func workspaceRow(_ id: String, _ name: String, _ sessions: [Session]) -> some View {
        let open = model.pillOpen.contains(id)
        return Button {
            if open { model.pillOpen.remove(id) } else { model.pillOpen.insert(id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.faint)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: id.isEmpty ? "folder" : "square.stack.3d.up").font(.system(size: 11))
                    .foregroundColor(id.isEmpty ? Theme.muted : Theme.accentLight)
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(sessions.count)").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.faint)
                Spacer(minLength: 6)
                Tally(sessions: sessions)
            }
            .padding(.horizontal, 10)
            .frame(height: PillView.workspaceRowHeight)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0E0F11)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(id.isEmpty ? "" : (id as NSString).abbreviatingWithTildeInPath)
    }

    /// A project's heading over its sessions; click it to fold them away (the same as in the window).
    private func section(_ g: ProjectGroup) -> some View {
        let collapsed = model.collapsedProjects.contains(g.id)
        return Button { model.toggleCollapsed(g.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 10)
                Image(systemName: collapsed ? "folder.fill" : "folder").font(.system(size: 10, weight: .semibold))
                Text(Projects.shortName(g.name, max: 30)).font(Theme.mono(11).weight(.medium)).lineLimit(1)
                if collapsed {
                    StatusRow(sessions: g.sessions, limit: 8, size: 10).padding(.leading, 4)
                } else {
                    Text("\(g.sessions.count)").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.faint.opacity(0.7))
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(Theme.faint)
            .padding(.horizontal, 4)
            .frame(height: PillView.sectionHeight - 4, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help((g.root as NSString).abbreviatingWithTildeInPath)
    }

    /// A session; `place` says where it works ("acme › api") before its status.
    private func row(_ s: Session, place: Bool = false) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(s.status.color.opacity(0.18))
                StatusGlyph(status: s.status, size: 13)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 0) {
                    if place {
                        Text(s.place + " · ").font(Theme.mono(11)).foregroundColor(Theme.muted)
                    }
                    Text(s.statusLine).font(.system(size: 12)).foregroundColor(s.status.color)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if s.unseen { Circle().fill(s.status.color).frame(width: 8, height: 8) }
            if let k = s.shortcut { Text(k).font(Theme.mono()).foregroundColor(Theme.faint) }
        }
        .padding(.horizontal, 10)
        .frame(height: PillView.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10).fill(s.status == .needs ? SessionStatus.needs.color.opacity(0.08) : Color(hex: 0x0E0F11)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(s.status == .needs ? SessionStatus.needs.color.opacity(0.45) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .help(L("Open in Ghostty"))
    }
}

struct PillButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: primary ? .semibold : .regular))
            .foregroundColor(primary ? Theme.ink : Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(primary ? Theme.accent : Color(hex: 0x1A1B1E)))
            .overlay(Capsule().stroke(primary ? Color.clear : Theme.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
