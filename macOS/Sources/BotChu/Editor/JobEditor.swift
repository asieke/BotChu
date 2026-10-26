import SwiftUI
import BotChuCore

/// A job's owner and the account, model and effort its runs use (its owner's, unless chosen here),
/// title, instructions, schedule and time zone, what to do about missed times, its time limit and
/// whether it is on, with the schedule in words and its next times.
struct JobEditor: View {
    /// How often it repeats, as the editor offers it.
    enum Repeat: String, CaseIterable, Identifiable {
        case daily = "Every day", weekdays = "Weekdays", days = "Chosen days", minutes = "Every few minutes", hours = "Every few hours"
        var id: String { rawValue }

        init(_ schedule: JobSchedule) {
            switch schedule.kind {
            case .daily: self = .daily
            case .weekdays: self = .weekdays
            case .days: self = .days
            case .interval: self = schedule.unit == .minutes ? .minutes : .hours
            }
        }

        func apply(to schedule: inout JobSchedule) {
            switch self {
            case .daily: schedule.kind = .daily
            case .weekdays: schedule.kind = .weekdays
            case .days:
                schedule.kind = .days
                if schedule.days.isEmpty { schedule.days = JobSchedule.weekdayNumbers }
            case .minutes:
                if schedule.kind != .interval || schedule.unit != .minutes { schedule.every = 30 }
                schedule.kind = .interval
                schedule.unit = .minutes
            case .hours:
                if schedule.kind != .interval || schedule.unit != .hours { schedule.every = 1 }
                schedule.kind = .interval
                schedule.unit = .hours
            }
        }
    }

    static let catchUpWindows: [(String, TimeInterval)] = [("1 hour", 3600), ("6 hours", 6 * 3600), ("1 day", 86_400), ("7 days", 7 * 86_400)]
    static let timeLimits: [(String, TimeInterval)] = [("10 minutes", 600), ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200), ("4 hours", 14_400)]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: JobEditorRequest
    @State private var job: Job
    @State private var error: String?

    init(request: JobEditorRequest) {
        self.request = request
        _job = State(initialValue: request.job)
    }

    private var repeatChoice: Binding<Repeat> {
        Binding(get: { Repeat(job.schedule) }, set: { $0.apply(to: &job.schedule) })
    }

    /// The time of day, shown in the job's own zone.
    private var time: Binding<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = job.schedule.zone
        return Binding(get: {
            calendar.date(bySettingHour: job.schedule.hour, minute: job.schedule.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            job.schedule.hour = parts.hour ?? 9
            job.schedule.minute = parts.minute ?? 0
        })
    }

    var body: some View {
        let agent = model.bot(job.botID)
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Agent", selection: $job.botID) {
                        ForEach(model.bots.filter { !$0.isRemoteQueue }) { bot in Text("\(bot.emoji) \(bot.name)").tag(bot.id) }
                    }
                    .disabled(!request.isNew)
                    .help(request.isNew ? "The agent that runs the job, as itself" : "A job stays with the agent that owns it.")
                    if let agent { RunsOnRows(job: $job, agent: agent) }
                }
                Section {
                    TextField("Title", text: $job.title, prompt: Text("Morning issue triage"))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Instructions")
                        TextEditor(text: $job.prompt)
                            .font(.body)
                            .frame(minHeight: 96)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                            .accessibilityLabel("Instructions")
                        Text("What the agent does each time, as you would ask it in a message.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Schedule") {
                    Picker("Repeat", selection: repeatChoice) {
                        ForEach(Repeat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch job.schedule.kind {
                    case .interval:
                        let unit = job.schedule.unit
                        Stepper(value: $job.schedule.every, in: unit == .minutes ? 5...720 : 1...48, step: unit == .minutes ? 5 : 1) {
                            Text(job.schedule.summary())
                        }
                        DatePicker("Starting", selection: $job.schedule.anchor)
                            .environment(\.timeZone, job.schedule.zone)
                            .help("Runs at this time, then every \(job.schedule.every) \(unit.rawValue) after it, however the clock changes")
                    case .daily, .weekdays, .days:
                        DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, job.schedule.zone)
                        if job.schedule.kind == .days { DayToggles(days: $job.schedule.days) }
                    }
                    Picker("Time zone", selection: $job.schedule.timeZone) {
                        ForEach(Self.zones(including: job.schedule.timeZone), id: \.self) { Text($0).tag($0) }
                    }
                    SchedulePreview(schedule: job.schedule, after: max(Date(), job.handledThrough))
                }
                Section("When BotChu misses a time") {
                    Picker("Missed times", selection: $job.missedRuns) {
                        Text("Run once if missed").tag(MissedRunPolicy.runOnce)
                        Text("Skip missed runs").tag(MissedRunPolicy.skip)
                    }
                    .pickerStyle(.radioGroup)
                    if job.missedRuns == .runOnce {
                        Picker("Catch up within", selection: $job.catchUpWindow) {
                            ForEach(Self.options(Self.catchUpWindows, including: job.catchUpWindow), id: \.1) { Text($0.0).tag($0.1) }
                        }
                    }
                    Text(job.missedRuns == .runOnce
                         ? "BotChu runs jobs only while it is open and this Mac is awake. If it misses times, it runs the job once for the latest of them when it is open again (if that was within \(JobWords.duration(job.catchUpWindow))), and tells the agent how late it is. Earlier missed times aren't run."
                         : "BotChu runs jobs only while it is open and this Mac is awake. Times it misses are recorded as skipped, and the job waits for its next time.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Section("Each run") {
                    Picker("Time limit", selection: $job.timeLimit) {
                        ForEach(Self.options(Self.timeLimits, including: job.timeLimit), id: \.1) { Text($0.0).tag($0.1) }
                    }
                    Toggle("Enabled", isOn: $job.enabled)
                    Text("Each run is a fresh session of \(agent?.name ?? "the agent")'s\(agent.map { " on \(model.jobs.runSettings(of: job, agent: $0).settings.account.name)" } ?? ""), with its identity, instructions and memory, in its workspace, as a new task beside its Home conversation, which it never uses. Findings and failures appear in Home with Open Run; a run that ends with nothing to report stays in the job's history and its task.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let problem = error ?? job.problem {
                    Text(problem).font(.callout).foregroundStyle(error == nil ? Color.secondary : Color.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.isNew ? "Create Job" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.problem != nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 700)
    }

    private func save() {
        do {
            try model.jobs.save(job)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Every zone this Mac knows, with the job's even when it doesn't.
    static func zones(including zone: String) -> [String] {
        let known = TimeZone.knownTimeZoneIdentifiers
        return known.contains(zone) ? known : [zone] + known
    }

    static func options(_ options: [(String, TimeInterval)], including value: TimeInterval) -> [(String, TimeInterval)] {
        options.contains { $0.1 == value } ? options : options + [(JobWords.duration(value), value)]
    }
}

/// The account, model and effort the job's runs use: its agent's, as they are when each run starts,
/// until others are chosen here, from the accounts and pickers a conversation has. A choice BotChu
/// can't run any more shows as unavailable, and why the runs use the agent's instead.
private struct RunsOnRows: View {
    @Environment(AppModel.self) private var model
    @Binding var job: Job
    let agent: Bot

    var body: some View {
        let unavailable = model.jobs.runSettings(of: job, agent: agent).unavailable
        // The job's own choice, also one that can't run, else the agent's.
        let shown = job.runsOn?.applied(to: agent, accounts: model.settings.accounts) ?? agent
        Picker("Account", selection: account) {
            ProviderMenuLabel(title: "Same as \(agent.name) · \(agent.account.name)", kind: agent.account.kind).tag(String?.none)
            Divider()
            if case .account(let name) = unavailable, let runsOn = job.runsOn {
                ProviderMenuLabel(title: "\(name) · unavailable", kind: shown.account.kind).tag(String?.some(runsOn.accountID))
            }
            ForEach(model.settings.accounts) { account in
                ProviderMenuLabel(account).tag(String?.some(account.id))
            }
        }
        .help("The account each run starts on")
        ModelMenu(settings: shown, disabled: false, onModel: { job.selectModel($0, agent: agent) },
                  onEffort: { job.selectReasoningEffort($0, agent: agent, openRouterDefault: model.settings.openRouterModel) }, inForm: true)
            // There's no choosing a model for an account BotChu can't run.
            .disabled(unavailable?.isAccount ?? false)
        Group {
            if let unavailable {
                Label {
                    Text(unavailable.explanation(agent: agent.name) + " Choose another \(unavailable.isAccount ? "account" : "model"), or Same as \(agent.name).")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            } else if job.runsOn == nil {
                Text("Runs use \(agent.name)'s account, model and effort, as they are when each starts. Choose others here for this job alone.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Runs use these, whatever \(agent.name) uses. Same as \(agent.name) goes back to the agent's.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The job's account, nil for its agent's. Only an account BotChu offers can be chosen: choosing
    /// the unavailable one again leaves it as it is.
    private var account: Binding<String?> {
        Binding(get: { job.runsOn?.accountID }, set: { id in
            if let id {
                guard let account = model.settings.accounts.first(where: { $0.id == id }) else { return }
                job.selectAccount(account, agent: agent)
            } else {
                job.selectAccount(nil, agent: agent)
            }
        })
    }
}

private extension JobRunsOn.Unavailable {
    var isAccount: Bool {
        if case .account = self { return true }
        return false
    }
}

/// A toggle per weekday, Monday first.
private struct DayToggles: View {
    @Binding var days: [Int]

    var body: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        HStack(spacing: 6) {
            Text("Days")
            Spacer()
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on { days.removeAll { $0 == day } } else { days.append(day) }
                } label: {
                    Text(symbols[day - 1])
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.12), in: Circle())
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                .accessibilityValue(on ? "On" : "Off")
            }
        }
    }
}

/// The schedule in words, and its next three times in its zone.
private struct SchedulePreview: View {
    let schedule: JobSchedule
    let after: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem = schedule.problem {
                Text(problem).foregroundStyle(.secondary)
            } else {
                Text("\(schedule.summary()), \(schedule.zoneLabel(at: after))").fontWeight(.medium)
                let next = schedule.upcoming(after: after, count: 3)
                Text(next.isEmpty ? "No upcoming times." : "Next: " + next.map { schedule.format($0) }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
