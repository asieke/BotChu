import SwiftUI
import BotChuCore

/// A job's runs, newest first, beside the chosen run: when it was meant for and when it ran, what
/// it ran on, how it went, and its transcript (live while it runs). Opening it never runs anything.
struct JobHistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: JobHistoryRequest
    @State private var selected: UUID?
    @State private var pendingDelete: Job?

    var body: some View {
        VStack(spacing: 0) {
            if let job = model.jobs.job(request.jobID) {
                header(job)
                Divider()
                HStack(spacing: 0) {
                    runList(job)
                        .frame(width: 260)
                    Divider()
                    if let run = job.runs.first(where: { $0.id == selected }) ?? job.runs.last {
                        JobRunDetail(job: job, run: run).id(run.id)
                    } else {
                        ContentUnavailableView("No runs yet", systemImage: "clock",
                                               description: Text("Runs appear here as the job runs: \(job.nextRun(now: Date()).map { "next \(job.schedule.format($0))" } ?? "it is paused; Run Now runs it once").")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                ContentUnavailableView("This job was deleted", systemImage: "trash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 860, height: 620)
        .onAppear { selected = request.runID }
        .confirmationDialog("Delete \(pendingDelete?.title ?? "job")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { job in
            Button("Delete", role: .destructive) {
                model.jobs.delete(job.id)
                dismiss()
            }
        } message: { _ in
            Text("The job and its history are deleted. Tasks it started stay.")
        }
    }

    private func header(_ job: Job) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let bot = model.bot(job.botID) { BotAvatar(bot: bot, size: 40) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(job.title).font(.title2.weight(.semibold))
                    JobStateBadge(job: job)
                }
                Text("\(model.bot(job.botID)?.name ?? "Unknown agent") · \(job.schedule.summary()), \(job.schedule.zoneLabel()) · "
                     + (job.nextRun(now: Date()).map { "next \(job.schedule.format($0))" } ?? "paused"))
                    .font(.callout).foregroundStyle(.secondary)
                if let problem = model.jobs.problems[job.id] {
                    Text(problem).font(.callout).foregroundStyle(.red)
                } else if let reason = job.pauseReason, !job.enabled {
                    Text(reason).font(.callout).foregroundStyle(.orange)
                } else if let fallback = model.jobs.fallback(of: job) {
                    Text(fallback).font(.callout).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Run Now") { model.jobs.runNow(job.id) }
                .disabled(job.activeRun != nil)
                .help(job.enabled ? "Run it once now; its schedule stays as it is" : "Run it once now; it stays paused")
            Button(job.enabled ? "Pause" : "Resume") { model.jobs.setEnabled(job.id, !job.enabled) }
                .help(job.enabled ? "Stop running it on its schedule; a run under way goes on" : "Run it on its schedule again, from now")
            Menu {
                JobMenuItems(job: job) { pendingDelete = job }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More actions for \(job.title)")
        }
        .padding(16)
    }

    private func runList(_ job: Job) -> some View {
        List(selection: Binding(get: { selected ?? job.runs.last?.id }, set: { selected = $0 })) {
            ForEach(job.runs.reversed()) { run in
                HStack(alignment: .top, spacing: 8) {
                    JobOutcomeIcon(run: run).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(JobRunDetail.when(run, in: job)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(run.summary.isEmpty ? JobOutcomeIcon.title(run) : run.summary)
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
                .tag(run.id)
            }
        }
        .listStyle(.inset)
    }
}

/// One run: its facts, then its transcript.
private struct JobRunDetail: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let run: JobRun

    var body: some View {
        let bot = model.bot(job.botID)
        let messages = model.jobs.thread(of: run.id, in: job)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    JobOutcomeIcon(run: run)
                    Text(JobOutcomeIcon.title(run)).font(.headline)
                    Text(Self.trigger(run)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if run.outcome.isActive {
                        Button(run.outcome == .running ? "Stop This Run" : "Cancel") { model.jobs.stop(run: run.id) }
                            .help("Stops this run only; the job keeps its schedule (Pause stops that)")
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    if let scheduled = run.scheduledFor { row("Scheduled", job.schedule.format(scheduled)) }
                    if let started = run.startedAt {
                        row("Started", job.schedule.format(started) + (run.lateness.map { $0 >= 60 ? " (\(JobWords.duration($0)) late)" : "" } ?? ""))
                    }
                    if let started = run.startedAt, let finished = run.finishedAt {
                        row("Took", BotStatus.formatElapsed(from: started, to: finished))
                    }
                    if let account = run.accountName {
                        row("Ran on", [account, run.reportedModel ?? (run.model?.isEmpty == false ? run.model : nil) ?? "its default model",
                                       run.reasoningEffort.map { "\($0.rawValue) effort" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    row("Time zone", run.timeZone)
                }
                .font(.callout)
                if !run.summary.isEmpty, run.outcome != .succeeded || messages.isEmpty {
                    Text(run.summary).font(.callout).foregroundStyle(run.outcome == .failed ? Color.red : Color.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            Divider()
            if let bot, !messages.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            MessageRow(message: message, bot: bot, kind: run.accountID == nil || run.accountID == bot.accountID ? bot.account.kind
                                            : model.settings.account(run.accountID ?? bot.accountID).kind,
                                       startsBotTurn: message.role != .note && (index == 0 || messages[index - 1].role == .note || messages[index - 1].role == .user))
                        }
                        if let state = model.jobs.live(run.id)?.state {
                            Text(state.activity.doing).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(run.outcome == .skipped ? "Skipped occurrences have no transcript." : "No transcript.")
                    .font(.callout).foregroundStyle(.secondary).padding(16)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    static func trigger(_ run: JobRun) -> String {
        switch run.trigger {
        case .scheduled: run.coalesced > 0 && run.outcome != .skipped ? "On schedule, after \(run.coalesced) missed" : "On schedule"
        case .catchUp: "Caught up" + (run.coalesced > 0 ? ", \(run.coalesced) earlier missed" : "")
        case .manual: "Run Now"
        }
    }

    /// The run's time, as its list shows it.
    static func when(_ run: JobRun, in job: Job) -> String {
        let date = run.scheduledFor ?? run.startedAt ?? run.reservedAt
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) + (run.trigger == .manual ? " · Run Now" : "")
    }
}
