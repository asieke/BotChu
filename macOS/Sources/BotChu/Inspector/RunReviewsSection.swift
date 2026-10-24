import SwiftUI
import BotChuCore

/// Activity's run reviews (`RunEvaluator`): Home lists those about the bot's guidance, a task those
/// of its turns and of the sub-agents it delegated. Each row opens to the review's findings and
/// evidence, the changes it saved (as the lines added and removed), its proposals and what it left
/// out, with Revert and Retry. Hidden while there are none.
struct RunReviewsSection: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget

    static let shown = 8

    var body: some View {
        let records = model.evaluations(for: target)
        if !records.isEmpty {
            let shown = Array(records.prefix(Self.shown))
            InspectorSection("Run reviews", trailing: trailing(records)) {
                InspectorCard {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, record in
                        RunReviewRow(record: record, last: index == shown.count - 1)
                    }
                }
                if records.count > Self.shown {
                    Text("\(records.count - Self.shown) earlier reviews are in .botchu/evaluations/.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    private func trailing(_ records: [EvaluationRecord]) -> String? {
        let waiting = records.filter { $0.phase.isWaiting }.count
        let failed = records.filter { $0.phase == .failed }.count
        let parts = [waiting > 0 ? "\(waiting) waiting" : nil, failed > 0 ? "\(failed) failed" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
                        Text(record.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(1)
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
        case .skipped: return "Not reviewed"
        }
    }

    private var symbol: String {
        switch record.phase {
        case .pending: "clock"
        case .running, .applying: "ellipsis.circle"
        case .failed: "exclamationmark.triangle"
        case .skipped: "minus.circle"
        case .done:
            switch record.outcome {
            case .memoryUpdated?, .instructionsUpdated?: record.revertedAt == nil ? "brain" : "arrow.uturn.backward.circle"
            case .proposed?: "lightbulb"
            case .noChange?, nil: "checkmark.circle"
            }
        }
    }

    private var color: Color {
        switch record.phase {
        case .failed: StatusLook.error.dot
        case .running, .applying: StatusLook.working.dot
        case .done where record.outcome == .memoryUpdated || record.outcome == .instructionsUpdated || record.outcome == .proposed:
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
                diff(change, title: "Saved to \(change.destination == .instructions ? "INSTRUCTIONS.md" : "MEMORY.md")")
            }
            if let revertedAt = record.revertedAt {
                Text("Reverted \(BotInspector.ago(revertedAt))").foregroundStyle(Palette.secondaryText)
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
            ForEach([record.failure?.message, record.skipReason, record.saveError, record.revertError].compactMap { $0 }, id: \.self) { problem in
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
                            .help(record.failure?.kind == .storage ? "Save this review's changes again" : "Review this run again")
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
        let ending = switch record.ending {
        case .finished: "finished"
        case .failed: "failed"
        case .stopped: "was stopped"
        }
        return "The run \(ending) · reviewed on \(record.account.name)" + (record.attempts > 1 ? " · \(record.attempts) tries" : "")
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

    private func diff(_ change: AppliedChange, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            heading(title)
            ForEach(Array(change.removed.enumerated()), id: \.offset) { _, line in
                Text("− " + line).foregroundStyle(StatusLook.error.dot)
            }
            ForEach(Array(change.added.enumerated()), id: \.offset) { _, line in
                Text("+ " + line).foregroundStyle(Color.green)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
    }
}
