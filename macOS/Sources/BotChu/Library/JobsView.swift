import SwiftUI
import BotChuCore

/// Every agent's scheduled jobs in one compact table: who owns each, when it runs, how it is doing
/// and how its last run went. Filtered by agent (as Agents and the Activity tab open it), search and
/// state; a row's menu runs, pauses, edits, deletes or opens its history.
struct JobsView: View {
    enum Filter: String, CaseIterable {
        case all = "All", on = "On", paused = "Paused", running = "Running", failed = "Failed"

        func includes(_ job: Job) -> Bool {
            switch self {
            case .all: true
            case .on: job.enabled
            case .paused: !job.enabled
            case .running: job.state == .running || job.state == .waiting
            case .failed: job.lastRun?.outcome == .failed
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filter = Filter.all
    @State private var selection: Job.ID?
    @State private var pendingDelete: Job?

    private var agentFilter: Binding<UUID?> {
        Binding(get: { model.jobs.agentFilter }, set: { model.jobs.agentFilter = $0 })
    }

    private var matches: [Job] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.jobs.jobs.filter { job in
            (model.jobs.agentFilter.map { $0 == job.botID } ?? true) && filter.includes(job)
                && (query.isEmpty || [job.title, job.prompt, model.bot(job.botID)?.name ?? "", job.schedule.summary()]
                    .joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryHeading(title: "Jobs", subtitle: "Recurring work your agents do on a schedule, each run in a session of its own.",
                           count: model.jobs.jobs.count) {
                Button { model.jobs.newJob(for: model.jobs.agentFilter) } label: { Label("New Job", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.bots.isEmpty)
            }
            // The search beside the filters, or above them in a narrow window.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    LibrarySearch(text: $query, prompt: "Search jobs").frame(minWidth: 200)
                    filters
                }
                VStack(alignment: .leading, spacing: 8) {
                    LibrarySearch(text: $query, prompt: "Search jobs")
                    filters
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 10)
            JobsRuntimeNote().padding(.horizontal, 24).padding(.bottom, 12)
            if model.jobs.jobs.isEmpty {
                LibraryEmpty(title: "No jobs yet",
                             subtitle: model.bots.isEmpty
                                 ? "Create an agent first; each job belongs to one."
                                 : "A job is saved instructions an agent runs on a schedule, such as a morning issue triage on weekdays at 9:00.",
                             symbol: "clock.arrow.circlepath")
            } else if matches.isEmpty {
                LibraryEmpty(title: "No matching jobs", subtitle: "Try another agent, state or search.", symbol: "magnifyingglass")
            } else {
                table
            }
        }
        .background(Color(nsColor: .windowBackgroundColor)).frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity).navigationTitle("Jobs")
        .confirmationDialog("Delete \(pendingDelete?.title ?? "job")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { job in
            Button("Delete", role: .destructive) { model.jobs.delete(job.id) }
        } message: { job in
            Text(job.state == .running
                 ? "Its run in progress stops, and the job and its history are deleted. Tasks it started stay."
                 : "The job and its history are deleted. Tasks it started stay.")
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Picker("Agent", selection: agentFilter) {
                Text("All agents").tag(UUID?.none)
                Divider()
                ForEach(model.bots) { bot in Text("\(bot.emoji) \(bot.name)").tag(UUID?.some(bot.id)) }
            }
            .labelsHidden().fixedSize()
            .accessibilityLabel("Agent")
            Picker("State", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private var table: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = max(context.date, Date())
            Table(matches, selection: $selection) {
                TableColumn("Job") { (job: Job) in JobTitleCell(job: job, problem: model.jobs.problems[job.id], fallback: model.jobs.fallback(of: job)) }
                    .width(min: 130, ideal: 180)
                TableColumn("Agent") { (job: Job) in JobAgentCell(botID: job.botID) }
                    .width(min: 90, ideal: 120, max: 220)
                TableColumn("Schedule") { (job: Job) in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.schedule.summary()).font(.system(size: 12)).lineLimit(1)
                        Text(job.schedule.zoneLabel(at: now)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help("\(job.schedule.summary()), \(job.schedule.zoneLabel(at: now))")
                }
                .width(min: 110, ideal: 150, max: 260)
                TableColumn("Next run") { (job: Job) in
                    Text(job.nextRun(now: now).map { JobsView.when($0, now: now) } ?? "—")
                        .font(.system(size: 12)).foregroundStyle(job.enabled ? .primary : .secondary).lineLimit(1)
                        .help(job.nextRun(now: now).map { job.schedule.format($0) } ?? "Paused: it doesn't run on its schedule.")
                }
                .width(min: 70, ideal: 90, max: 160)
                TableColumn("State") { (job: Job) in JobStateBadge(job: job) }
                    .width(min: 64, ideal: 76, max: 110)
                TableColumn("Last run") { (job: Job) in JobLastRunCell(job: job, now: now) }
                    .width(min: 120, ideal: 200)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: Job.ID.self) { ids in
                if let id = ids.first, let job = model.jobs.job(id) { JobMenuItems(job: job) { pendingDelete = job } }
            } primaryAction: { ids in
                if let id = ids.first { model.jobs.showHistory(id) }
            }
        }
    }

    /// A time soon as “in 25 min”, later today as its time, later still as its day and time.
    static func when(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 3600 { return "in \(max(1, Int((seconds / 60).rounded(.up)))) min" }
        if Calendar.current.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// Where jobs run, said wherever they are listed: only while BotChu is open and the Mac awake.
struct JobsRuntimeNote: View {
    var body: some View {
        Label {
            Text("Jobs run while BotChu is open and this Mac is awake, never while it is quit or the Mac sleeps. A time missed meanwhile runs once when BotChu is open again, or is skipped, as each job says.")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A job's actions, in the table's menu and the history's header.
struct JobMenuItems: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let delete: () -> Void

    var body: some View {
        Button("Run Now") { model.jobs.runNow(job.id) }
            .disabled(job.activeRun != nil)
        if let run = job.activeRun {
            Button(run.outcome == .running ? "Stop This Run" : "Cancel Waiting Run") { model.jobs.stop(run: run.id) }
        }
        Button(job.enabled ? "Pause Job" : "Resume Job") { model.jobs.setEnabled(job.id, !job.enabled) }
        Divider()
        Button("View History…") { model.jobs.showHistory(job.id) }
        Button("Edit…") { model.jobs.edit(job.id) }
        Divider()
        Button("Delete…", role: .destructive, action: delete)
    }
}

private struct JobTitleCell: View {
    let job: Job
    let problem: String?
    /// Why its runs are on its agent's instead of its own choice.
    let fallback: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(job.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if let problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1).help(problem)
            } else if let reason = job.pauseReason, !job.enabled {
                Text(reason).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1).help(reason)
            } else if let fallback {
                Text(fallback).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1).help(fallback)
            } else {
                Text(job.prompt).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(job.prompt)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct JobAgentCell: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    var body: some View {
        if let bot = model.bot(botID) {
            HStack(spacing: 8) {
                BotAvatar(bot: bot, size: 22)
                Text(bot.name).font(.system(size: 12)).lineLimit(1)
            }
        } else {
            Text("Unknown agent").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// On, paused, waiting or running, as a small capsule.
struct JobStateBadge: View {
    let job: Job
    var body: some View {
        let (title, color): (String, Color) = switch job.state {
        case .on: ("On", .green)
        case .paused: ("Paused", .secondary)
        case .waiting: ("Waiting", .orange)
        case .running: ("Running", Palette.violet)
        }
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .help(job.state == .waiting ? "Waiting for its agent's other work in its workspace, or a free slot, to finish." : title)
    }
}

private struct JobLastRunCell: View {
    let job: Job
    let now: Date
    var body: some View {
        if let run = job.lastRun {
            HStack(spacing: 6) {
                JobOutcomeIcon(run: run)
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.summary.isEmpty ? JobOutcomeIcon.title(run) : run.summary).font(.system(size: 12)).lineLimit(1)
                    Text("\(JobOutcomeIcon.title(run)) · \((run.finishedAt ?? run.startedAt ?? run.reservedAt).formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .help(run.summary)
        } else {
            Text("Not run yet").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// A run's outcome as a symbol in its color.
struct JobOutcomeIcon: View {
    let run: JobRun
    var body: some View {
        let (symbol, color) = Self.look(run)
        Image(systemName: symbol).foregroundStyle(color).font(.system(size: 12))
            .accessibilityLabel(Self.title(run))
    }

    static func look(_ run: JobRun) -> (String, Color) {
        switch run.outcome {
        case .waiting: ("hourglass", .orange)
        case .running: ("circle.dotted", Palette.violet)
        case .succeeded: run.quiet ? ("checkmark.circle", .secondary) : ("checkmark.circle.fill", .green)
        case .failed: ("exclamationmark.triangle.fill", .red)
        case .stopped: ("stop.circle", .secondary)
        case .skipped: ("forward.end", .secondary)
        case .interrupted: ("questionmark.circle", .orange)
        }
    }

    static func title(_ run: JobRun) -> String {
        switch run.outcome {
        case .waiting: "Waiting"
        case .running: "Running"
        case .succeeded: run.quiet ? "Nothing to report" : "Succeeded"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .skipped: run.coalesced > 0 ? "Skipped \(run.coalesced + 1) times" : "Skipped"
        case .interrupted: "Interrupted"
        }
    }
}
