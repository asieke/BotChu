import SwiftUI
import BotChuCore

struct AccountUsageSection: View {
    @Environment(AppModel.self) private var model
    let request: UsageRequest
    let isRunning: Bool
    @State private var state = UsageState()
    @State private var loading = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            InspectorSection("Usage") {
                InspectorCard(padded: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(request.account.kind == .pi ? "OpenRouter key allowance" : "Account allowance")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondaryText)
                            Spacer()
                            Button { Task { await refresh(manual: true) } } label: {
                                if loading {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(width: 22, height: 22)
                            .disabled(loading || !canRefresh(at: now))
                            .accessibilityLabel("Refresh account usage")
                            .help(request.account.kind == .muse
                                  ? "Check Muse with a brief request (at most once every five minutes)"
                                  : "Refresh the selected account’s allowance")
                        }
                        if let reading = state.reading {
                            ForEach(reading.windows) { window in
                                UsageWindowView(window: window, now: now)
                            }
                            if let note = reading.note {
                                Text(note).font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
                            }
                            Text("\(state.isStale(at: now, interval: request.refreshInterval) ? "Stale · read" : "Updated") \(reading.readAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.secondaryText)
                                .help(reading.readAt.formatted(date: .complete, time: .standard))
                        } else if loading {
                            Text("Checking \(request.account.name)…")
                                .font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
                        }
                        if let error = state.error {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(state.reading == nil ? "Usage unavailable" : "Stale reading")
                                    .font(.system(size: 12, weight: .medium))
                                Text(error).font(.system(size: 11))
                            }
                            .foregroundStyle(Palette.secondaryText)
                        }
                        if request.account.kind == .muse {
                            Text("Updates hourly with a brief Muse request.")
                                .font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh(manual: false)
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
        .onChange(of: isRunning) { wasRunning, running in
            if wasRunning && !running { Task { await refresh(manual: true) } }
        }
    }

    private func canRefresh(at now: Date) -> Bool {
        if let retry = state.retryAt, now < retry { return false }
        return state.checkedAt.map { now.timeIntervalSince($0) >= request.manualInterval } ?? true
    }

    @MainActor private func refresh(manual: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let key = request.account.kind == .pi ? Keychain.get(Keychain.openRouterAccount) : nil
        let result = await model.usage.read(request, openRouterKey: key, manual: manual)
        guard !Task.isCancelled else { return }
        state = result
    }
}

struct UsageWindowView: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        let percent = window.currentPercent(at: now)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).fontWeight(.medium)
                Spacer(minLength: 4)
                Text(percent.map { "\($0.formatted(.number.precision(.fractionLength(0))))% used" } ?? "—")
                    .foregroundStyle(Palette.secondaryText)
                    .monospacedDigit()
                    .layoutPriority(1)
            }
            .font(.system(size: 12))
            if let percent {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.rowDivider)
                        Capsule().fill(percent >= 100 ? Palette.dynamic(0xD93A2F, 0xFF6B60)
                                       : percent >= 80 ? Palette.dynamic(0xB96D00, 0xF5A623) : Palette.violet)
                            .frame(width: geometry.size.width * min(100, max(0, percent)) / 100)
                    }
                }
                    .frame(height: 5)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(window.title) allowance used")
                    .accessibilityValue("\(percent.formatted(.number.precision(.fractionLength(0)))) percent")
            }
            if let detail = window.detail, !window.hasReset(at: now) {
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
            }
            Text(resetText)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
                .help(window.resetsAt?.formatted(date: .complete, time: .standard) ?? resetText)
        }
    }

    private var resetText: String {
        if window.hasReset(at: now) { return "Reset passed · awaiting update" }
        if let date = window.resetsAt { return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))" }
        if let text = window.resetDescription { return text == "No scheduled reset" ? text : "Resets \(text)" }
        return "Reset time not reported"
    }
}
