import SwiftUI
import BotChuCore

/// Activity's run reviews (`RunEvaluator`, #138): one summary line with what the reviews are doing
/// (the next review time, or the real reason one waits) and Review now; rows only for reviews with
/// news (memory updated, a change proposed, or a failure), each opening to its findings and
/// evidence, the changes it saved (every line added and removed), its proposals and what it left
/// out, with Revert (and what Revert left as the owner had changed it) and Retry; and one line
/// counting the past week's other reviews. Home's covers all the bot's work; a task's lists the
/// reviews that covered it. Hidden while reviews are off and there are none.
struct RunReviewsSection: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget

    static let shown = 8

    var body: some View {
        let status = model.reviewStatus(for: target)
        let records = model.evaluations(for: target)
        let news = records.filter(\.isNews)
        let counts = model.reviewCounts(for: target)
        if status != .off || !news.isEmpty || !counts.isEmpty {
            let shown = Array(news.prefix(Self.shown))
            InspectorSection("Run reviews", trailing: trailing(news)) {
                InspectorCard {
                    RunReviewSummary(target: target)
                }
                if !shown.isEmpty {
                    InspectorCard {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, record in
                            RunReviewRow(record: record, last: index == shown.count - 1)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    if !counts.isEmpty { Text(counts.text) }
                    if news.count > Self.shown { Text("\(news.count - Self.shown) earlier reviews are in .botchu/evaluations/.") }
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            }
        }
    }

    private func trailing(_ news: [EvaluationRecord]) -> String? {
        let failed = news.filter { $0.phase == .failed }.count
        return failed > 0 ? "\(failed) failed" : nil
    }
}

/// The reviews' state in one line, kept current as time passes, with Review now while there is
/// unreviewed work and no review of it waits; Home's says it covers all the bot's work.
private struct RunReviewSummary: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let status = model.reviewStatus(for: target)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol(status))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color(status))
                        .frame(width: 16)
                    Text(status.text())
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.canReviewNow(target) {
                    Button("Review now") { model.reviewNow(target) }
                        .buttonStyle(InspectorButtonStyle())
                        .help(target.taskID == nil ? "Review all of this bot's unreviewed work without waiting for the review time"
                                                   : "Review this task's unreviewed work without waiting for the review time")
                        .padding(.leading, 26)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    private func symbol(_ status: ReviewStatus) -> String {
        switch status {
        case .off: "pause.circle"
        case .upToDate: "checkmark.circle"
        case .next: "clock"
        case .waiting(let wait, _):
            switch wait {
            case .reviewing, .saving, .starting: "ellipsis.circle"
            case .unavailable: "minus.circle"
            case .busy, .another, .dailyLimit, .allowance, .retrying: "hourglass"
            }
        }
    }

    private func color(_ status: ReviewStatus) -> Color {
        switch status {
        case .waiting(.reviewing, _), .waiting(.saving, _), .waiting(.starting, _): StatusLook.working.dot
        default: Palette.secondaryText
        }
    }
}

/// One review: what it was about and how it went, opening to its details.
private struct RunReviewRow: View {
    let record: EvaluationRecord
    let last: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(1)
                        if let cited = record.cited, !cited.isEmpty {
                            Text("From " + cited.joined(separator: ", "))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Palette.secondaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .help(record.findings?.summary ?? status)
            if open {
                RunReviewDetail(record: record)
                    .padding(EdgeInsets(top: 0, leading: 38, bottom: 10, trailing: 12))
            }
        }
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        }
    }

    /// The day a review is for, or (before #138) the run it was of.
    private var title: String {
        switch record.subject.kind {
        case .day, .task:
            var title = "Review of " + ReviewTime.dayText(record.scheduledFor ?? record.createdAt, in: .current)
            if let days = record.coalesced, days > 0 { title += " · \(days + 1) days" }
            if record.requested == true { title += " · Review now" }
            return title
        case .taskTurn, .subagent:
            return record.title.prefix(1).uppercased() + record.title.dropFirst()
        }
    }

    private var status: String {
        switch record.phase {
        case .pending:
            if let failure = record.failure { return "Waiting to try again (\(failure.kind.label))" }
            return "Waiting for \(record.account.name) to be idle"
        case .running: return "Reviewing on \(record.account.name)…"
        case .applying: return "Saving…"
        case .done:
            let outcome = record.outcome?.label ?? "Done"
            return outcome + (record.revertedAt == nil ? "" : " · reverted") + " · " + BotInspector.ago(record.finishedAt ?? record.createdAt)
        case .failed: return "Failed (\(record.failure?.kind.label ?? "review"))"
        case .skipped, .folded: return "Not reviewed"
        }
    }

    private var symbol: String {
        switch record.phase {
        case .pending: "clock"
        case .running, .applying: "ellipsis.circle"
        case .failed: "exclamationmark.triangle"
        case .skipped, .folded: "minus.circle"
        case .done:
            switch record.outcome {
            case .memoryUpdated?: record.revertedAt == nil ? "brain" : "arrow.uturn.backward.circle"
            case .proposed?: "lightbulb"
            case .noChange?, .noSignal?, nil: "checkmark.circle"
            }
        }
    }

    private var color: Color {
        switch record.phase {
        case .failed: StatusLook.error.dot
        case .running, .applying: StatusLook.working.dot
        case .done where record.outcome == .memoryUpdated || record.outcome == .proposed:
            Palette.accent
        default: Palette.secondaryText
        }
    }
}

/// A review's findings, evidence, saved changes, proposals, what it left out and why it failed.
private struct RunReviewDetail: View {
    @Environment(AppModel.self) private var model
    let record: EvaluationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let findings = record.findings {
                if !findings.summary.isEmpty { Text(findings.summary) }
                list("Worked", findings.worked)
                list("Didn't work", findings.didNotWork)
                list("Evidence", findings.evidence, monospaced: true)
            }
            ForEach(Array(record.applied.enumerated()), id: \.offset) { _, change in
                diff(change, title: "Saved to \(place(change.destination))")
            }
            if let revertedAt = record.revertedAt {
                Text("Reverted \(BotInspector.ago(revertedAt))").foregroundStyle(Palette.secondaryText)
                list("Not reverted", record.unreverted)
            }
            ForEach(Array(record.proposals.enumerated()), id: \.offset) { _, proposal in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        heading("Proposed for \(place(proposal.destination))")
                        Spacer(minLength: 4)
                        CopyButton(text: proposal.text, help: "Copy the proposed change")
                            .frame(height: 16)
                    }
                    Text(proposal.text).textSelection(.enabled)
                    if let held = proposal.held { Text(held + ".").foregroundStyle(Palette.secondaryText) }
                }
            }
            list("Left out", record.leftOut)
            if let reason = record.skipReason {
                Text(reason).foregroundStyle(Palette.secondaryText).textSelection(.enabled)
            }
            ForEach([record.failure?.message, record.saveError, record.revertError].compactMap { $0 }, id: \.self) { problem in
                Text(problem).foregroundStyle(StatusLook.error.dot).textSelection(.enabled)
            }
            Text(footer).foregroundStyle(Palette.secondaryText)
            if record.canRevert || record.canRetry {
                HStack(spacing: 8) {
                    if record.canRevert {
                        Button("Revert") { model.revertEvaluation(record.id) }
                            .help("Undo what this review saved, keeping every other edit made since")
                    }
                    if record.canRetry {
                        Button("Retry") { model.retryEvaluation(record.id) }
                            .help(record.failure?.kind == .storage ? "Save this review's changes again" : "Review this work again")
                    }
                }
                .buttonStyle(InspectorButtonStyle())
            }
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: String {
        let tries = record.attempts > 1 ? " · \(record.attempts) tries" : ""
        guard let ending = record.ending else {
            let covered = (record.covered ?? []).map(\.title).filter { !$0.isEmpty }
            return (covered.isEmpty ? "" : "Covered \(covered.joined(separator: ", ")) · ") + "reviewed on \(record.account.name)" + tries
        }
        let ended = switch ending {
        case .finished: "finished"
        case .failed: "failed"
        case .stopped: "was stopped"
        }
        return "The run \(ended) · reviewed on \(record.account.name)" + tries
    }

    private func place(_ destination: EvaluationChange.Destination) -> String {
        switch destination {
        case .memory: "MEMORY.md"
        case .instructions: "INSTRUCTIONS.md"
        case .shared: "the shared MEMORY.md"
        case .team: "TEAM.md"
        case .repository: "the repository"
        case .caller: "the calling bot"
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondaryText)
    }

    @ViewBuilder private func list(_ title: String, _ items: [String], monospaced: Bool = false) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                heading(title)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• " + item)
                        .font(.system(size: monospaced ? 11 : 12, design: monospaced ? .monospaced : .default))
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Every line the save removed and added, blank ones included, hunk by hunk.
    private func diff(_ change: AppliedChange, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            heading(title)
            ForEach(Array(change.hunks.enumerated()), id: \.offset) { _, hunk in
                ForEach(Array(hunk.removed.enumerated()), id: \.offset) { _, line in
                    Text("− " + (line.isEmpty ? "(blank line)" : line)).foregroundStyle(StatusLook.error.dot)
                }
                ForEach(Array(hunk.added.enumerated()), id: \.offset) { _, line in
                    Text("+ " + (line.isEmpty ? "(blank line)" : line)).foregroundStyle(Color.green)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
    }
}
