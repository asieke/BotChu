import SwiftUI
import BotChuCore

/// Settings ▸ Run reviews: whether each bot's work is reviewed once a day, and at what time of day
/// in this Mac's time zone (#138).
struct RunReviewSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let limits = model.evaluator.limits
        Section {
            Toggle("Review each bot's work once a day", isOn: $settings.evaluateRuns)
                .onChange(of: settings.evaluateRuns) { model.evaluator.pump() }
            DatePicker("Review time", selection: time, displayedComponents: .hourAndMinute)
                .disabled(!settings.evaluateRuns)
                .onChange(of: settings.reviewTime) { model.evaluator.pump() }
        }
        .help("At the review time, in this Mac's time zone, BotChu reviews each bot's work since its last review in one pass: its Home, its tasks and the sub-agents that ran as it. If BotChu is closed or the Mac asleep at the review time, it runs at the first chance afterwards.")
        Section("Each review") {
            LabeledContent("Runs on", value: "The bot's own account, model and effort")
                .help("In a fresh session, with every tool turned off by the CLI itself. Reviews use the bot's allowance.")
            LabeledContent("Reviews", value: "Only work with signal")
                .help("A failure, a stop, you steering a task, \(limits.failedToolCalls) or more failed tool calls, \(limits.toolCalls) or more tool calls, or \(Int(limits.turnTime / 60)) minutes or more at work; a day without it asks no model.")
            LabeledContent("Limit", value: "\(limits.perAccountPerDay) model calls a day per account")
                .help("A review waits until its account has been idle for a minute, one at a time, each stopped after \(Int(limits.timeout / 60)) minutes.")
            LabeledContent("Writes", value: "Up to \(EvaluationPlan.maxApplied) notes a day to the bot's MEMORY.md")
                .help("Concise, evidence-backed notes, which you can revert in the status sidebar's Activity (which also has Review now); changes to INSTRUCTIONS.md and anything else are kept as proposals for you.")
            LabeledContent("Skips", value: "Bots on Antigravity and Pi")
                .help("BotChu can't run them without tools.")
        }
    }

    /// The review time as a moment today, for the picker.
    private var time: Binding<Date> {
        Binding(get: {
            let time = model.settings.reviewTime
            return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.settings.reviewTime = ReviewTime(hour: parts.hour ?? ReviewTime.standard.hour, minute: parts.minute ?? 0)
        })
    }
}
