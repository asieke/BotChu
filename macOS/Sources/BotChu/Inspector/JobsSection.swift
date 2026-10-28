import SwiftUI
import BotChuCore

/// The agent's scheduled jobs in its Activity tab, beside its tasks: each job's state, next time
/// and last run, opening its history; New Job… and All Jobs (Jobs, showing this agent's).
struct JobsSection: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    /// The most jobs listed here; All Jobs shows the rest.
    static let shown = 5

    var body: some View {
        let jobs = model.jobs.jobs(of: botID)
        let on = jobs.filter(\.enabled).count
        // A specialist owns no new jobs; the ones paused when it became one still show (#250).
        let ownsJobs = model.bot(botID)?.canOwnTasks == true
        if ownsJobs || !jobs.isEmpty {
            InspectorSection("Jobs", trailing: jobs.isEmpty ? nil : "\(on) on") {
                if !jobs.isEmpty {
                    InspectorCard {
                        let listed = Array(jobs.prefix(Self.shown))
                        ForEach(Array(listed.enumerated()), id: \.element.id) { index, job in
                            JobRow(job: job, last: index == listed.count - 1)
                        }
                    }
                }
                HStack(spacing: 8) {
                    if ownsJobs {
                        Button { model.jobs.newJob(for: botID) } label: {
                            Label("New Job…", systemImage: "plus")
                        }
                        .help("Saved instructions this agent runs on a schedule, each run in a session of its own")
                    }
                    if !jobs.isEmpty {
                        Button { model.showJobs(for: botID) } label: {
                            Label(jobs.count > Self.shown ? "All \(jobs.count)" : "All Jobs", systemImage: "clock.arrow.circlepath")
                        }
                        .help("Show this agent's jobs in Jobs")
                    }
                }
                .buttonStyle(InspectorButtonStyle(fill: true))
            }
        }
    }
}

/// A job in an agent's list: its light, title, and next time or last run.
private struct JobRow: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let last: Bool

    var body: some View {
        Button { model.jobs.showHistory(job.id) } label: {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        }
        .help("Show \(job.title)'s history")
    }

    /// A job that is on, and whose last run didn't fail.
    static let on = Palette.dynamic(0x34C759, 0x30D158)

    private var color: Color {
        switch job.state {
        case .running, .waiting: return StatusLook.working.dot
        case .paused: return StatusLook.idle.dot.opacity(0.5)
        case .on: return job.lastRun?.outcome == .failed ? StatusLook.error.dot : Self.on
        }
    }

    private var detail: String {
        switch job.state {
        case .running: return "Running now"
        case .waiting: return "Waiting for this agent's other work"
        case .paused: return job.pauseReason == nil ? "Paused" : "Paused after failures"
        case .on:
            let next = job.nextRun(now: Date()).map { "Next \(JobsView.when($0, now: Date()))" } ?? job.schedule.summary()
            guard let run = job.lastRun else { return next }
            return "\(next) · last \(JobOutcomeIcon.title(run).lowercased())"
        }
    }
}
