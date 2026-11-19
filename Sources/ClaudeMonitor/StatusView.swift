import MonitorCore
import SwiftUI

struct StatusView: View {
    @ObservedObject var model: MonitorModel
    /// The popover's height; screenshots use a taller one so every section shows.
    var height: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let s = model.snapshot {
                        hardware(s)
                        sessions(s)
                        worktrees
                        if !s.orphans.isEmpty { orphans(s) }
                        if !s.otherGroups.isEmpty { outside(s) }
                    } else {
                        ProgressView("Sampling…").frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: height)
    }

    // MARK: Header

    private var header: some View {
        let level = model.snapshot?.rollup
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(level.map(LevelStyle.color) ?? .secondary)
                .frame(width: 16, height: 16)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(level.map(LevelStyle.headline) ?? "Claude Monitor").font(.headline)
                if let s = model.snapshot {
                    if s.reasons.isEmpty {
                        Text("CPU, memory, swap, disk and thermal are all within limits.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(s.reasons, id: \.self) { r in
                            Text(r).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let e = model.errorText {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
                if let n = model.notice {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(n).foregroundStyle(.primary)
                        Button { model.dismissNotice() } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Dismiss")
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    // MARK: Hardware

    private func hardware(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Hardware")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                ForEach(s.hardware, id: \.title) { m in
                    GridRow {
                        dot(m.level, size: 8)
                        Text(m.title).foregroundStyle(.secondary)
                        Text(m.value).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: Sessions

    private func sessions(_ s: Snapshot) -> some View {
        let counts = Dictionary(grouping: s.sessions, by: { $0.usage.record.status.label }).mapValues(\.count)
        let order = ["waiting", "busy", "shell", "idle"]
        let summary = order.compactMap { k in counts[k].map { "\($0) \(k)" } }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Claude sessions (\(s.sessions.count))")
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            if s.sessions.isEmpty {
                Text("No running Claude Code sessions.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(s.sessions, id: \.usage.process.pid) { r in
                SessionRow(report: r, now: s.takenAt, model: model,
                           isExpanded: model.expandedSessions.contains(r.usage.process.pid)) {
                    model.toggleExpanded(r.usage.process.pid)
                }
            }
        }
    }

    // MARK: Worktrees

    private var worktrees: some View {
        let scan = model.worktreeScan
        let items = scan?.reclaimable ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { model.showWorktrees.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.showWorktrees ? "chevron.down" : "chevron.right").font(.caption2)
                        sectionTitle("Reclaimable worktrees")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if model.scanningWorktrees {
                    ProgressView().controlSize(.mini)
                    Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                } else if let scan {
                    Text(items.isEmpty ? "none" : "\(items.count) · \(Format.bytes(scan.totalBytes))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            if model.showWorktrees {
                if let scan {
                    Text(scanSummary(scan)).font(.caption).foregroundStyle(.secondary)
                } else if !model.scanningWorktrees {
                    Text("First scan starts shortly after launch.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(items) { w in WorktreeRow(item: w, model: model) }
                if let msg = model.worktreeMessage, !msg.isEmpty {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Scan Now") { model.scanWorktrees() }
                        .disabled(model.scanningWorktrees || !model.deletingWorktrees.isEmpty)
                    Spacer()
                    if items.count > 1 {
                        Button("Delete All \(items.count)…") { model.confirmDelete(items) }
                            .disabled(!model.deletingWorktrees.isEmpty || model.scanningWorktrees)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func scanSummary(_ scan: WorktreeScan) -> String {
        let kept = scan.skipped.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        var s = "Checked \(scan.worktreeCount) worktrees in \(scan.repoCount) repos at "
        s += scan.finishedAt.formatted(date: .omitted, time: .shortened)
        return kept.isEmpty ? s + "." : s + ". Kept: \(kept)."
    }

    // MARK: Orphans / outside

    private func orphans(_ s: Snapshot) -> some View {
        let cores = s.orphans.reduce(0) { $0 + $1.cores }
        let mem = s.orphans.reduce(Int64(0)) { $0 + $1.rssBytes }
        return VStack(alignment: .leading, spacing: 6) {
            Button { model.showOrphans.toggle() } label: {
                HStack {
                    Image(systemName: model.showOrphans ? "chevron.down" : "chevron.right").font(.caption2)
                    sectionTitle("Left behind by closed sessions")
                    Spacer()
                    Text("\(s.orphans.count) · \(Format.cores(cores)) · \(Format.bytes(mem))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.showOrphans {
                ForEach(s.orphans.prefix(12), id: \.pid) { p in ProcessLine(process: p, detached: false) }
            }
        }
    }

    private func outside(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Heaviest outside Claude")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(s.otherGroups, id: \.name) { g in
                    GridRow {
                        Text(g.name).lineLimit(1)
                        Text("×\(g.count)").foregroundStyle(.secondary)
                        Text(Format.cores(g.cores)).gridColumnAlignment(.trailing)
                        Text(Format.bytes(g.rssBytes)).gridColumnAlignment(.trailing)
                    }
                    .font(.callout).monospacedDigit()
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let s = model.snapshot {
                Text("Updated \(s.takenAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                     set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox).font(.caption)
            Button("Refresh") { model.refresh() }.controlSize(.small)
            Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

func dot(_ l: Level, size: CGFloat) -> some View {
    Circle().fill(LevelStyle.color(l)).frame(width: size, height: size)
}

struct SessionRow: View {
    let report: SessionReport
    let now: Date
    let model: MonitorModel
    let isExpanded: Bool
    let toggle: () -> Void

    private var u: SessionUsage { report.usage }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 8) {
                    dot(report.level, size: 9).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(u.record.name).fontWeight(.medium).lineLimit(1)
                            StatusChip(status: u.record.status)
                            Spacer(minLength: 4)
                            Text("\(Format.cores(u.totalCores)) · \(Format.bytes(u.totalRSSBytes))")
                                .font(.callout).monospacedDigit()
                                .foregroundStyle(u.totalCores >= 1 ? .primary : .secondary)
                        }
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        // Color only the icon: orange/red text on the translucent popover is hard to read.
                        ForEach(report.reasons, id: \.self) { why in
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(report.level == .red ? Color.red : Color.orange)
                                Text(why).foregroundStyle(.primary)
                            }
                            .font(.caption)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(report.isStale && report.level == .green ? 0.6 : 1)

            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    if u.descendants.isEmpty {
                        Text("No child processes").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(u.descendants.prefix(10), id: \.pid) { p in
                        ProcessLine(process: p, detached: u.detachedPids.contains(p.pid))
                    }
                    if u.descendants.count > 10 {
                        Text("+ \(u.descendants.count - 10) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 17)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Reveal Folder in Finder") { model.revealFolder(u.record.cwd) }.disabled(u.record.cwd == nil)
            Button("Copy PID (\(u.process.pid))") { model.copy("\(u.process.pid)") }
            if let cmd = model.resumeCommand(u.record) {
                Button("Copy Resume Command") { model.copy(cmd) }
            }
            Divider()
            Button("End Session…") { model.confirmTerminate(u) }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let cwd = u.record.cwd { parts.append(Format.path(cwd)) }
        if let age = report.statusAge { parts.append("\(u.record.status.label) \(Format.duration(age))") }
        if report.isStale { parts.append("stale") }
        if let top = u.topChild, top.cpuPercent >= 10 { parts.append("\(top.name) \(Format.cores(top.cores))") }
        return parts.joined(separator: " · ")
    }
}

struct WorktreeRow: View {
    let item: ReclaimableWorktree
    @ObservedObject var model: MonitorModel

    var body: some View {
        let deleting = model.deletingWorktrees.contains(item.path)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text((item.path as NSString).lastPathComponent).fontWeight(.medium).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(item.sizeBytes.map(Format.bytes) ?? "?").font(.callout).monospacedDigit()
            if deleting {
                ProgressView().controlSize(.mini)
            } else {
                Button { model.confirmDelete([item]) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete this worktree (branch is kept)")
                    .disabled(model.scanningWorktrees)
            }
        }
        .opacity(deleting ? 0.5 : 1)
        .help(item.path)
        .contextMenu {
            Button("Reveal in Finder") { model.revealFolder(item.path) }
            Button("Copy Path") { model.copy(item.path) }
        }
    }

    private var detail: String {
        var parts = [Format.path(item.repo)]
        if let b = item.branch { parts.append(b) }
        if let a = item.lastActivity { parts.append("untouched \(Format.duration(Date().timeIntervalSince(a)))") }
        return parts.joined(separator: " · ")
    }
}

struct StatusChip: View {
    let status: SessionStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch status {
        case .busy: return .blue
        case .waiting: return LevelStyle.readableOrange
        case .shell: return .purple
        default: return .secondary
        }
    }
}

struct ProcessLine: View {
    let process: ProcessRow
    let detached: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(process.name).font(.caption.weight(.medium)).lineLimit(1)
            if detached {
                Text("detached").font(.caption2).foregroundStyle(.secondary)
            }
            Text(process.args).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(Format.cores(process.cores)) · \(Format.bytes(process.rssBytes)) · \(Format.duration(TimeInterval(process.elapsedSeconds)))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .help(process.args)
    }
}
