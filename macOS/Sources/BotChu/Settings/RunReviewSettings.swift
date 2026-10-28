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
        // How a review works is in the tooltip, not as rows of facts (#232): what it uses and may
        // write stay said there.
        .help("At the review time, in this Mac's time zone, BotChu reviews each bot's work since its last review in one pass: its Home, its tasks and the sub-agents that ran as it. If BotChu is closed or the Mac asleep at the review time, it runs at the first chance afterwards. Each review runs on the bot's own account, model and effort, without tools, using its allowance (at most \(limits.perAccountPerDay) model calls a day per account), and writes up to \(EvaluationPlan.maxApplied) notes a day to its MEMORY.md, which you can revert in Activity; bots on Antigravity and Pi are skipped.")
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
