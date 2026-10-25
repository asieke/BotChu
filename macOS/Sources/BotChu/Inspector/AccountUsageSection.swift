import SwiftUI
import BotChuCore

/// The shown conversation's account allowance, as the app's usage board has it (#147): the
/// reading the background keeps current, shown at once and updated in place. It is checked only
/// when there is none or it is as old as the background lets it get, and with Refresh or after a
/// turn, within the same limits as Providers.
struct AccountUsageSection: View {
    @Environment(AppModel.self) private var model
    let request: UsageRequest
    let isRunning: Bool

    var body: some View {
        let board = model.usageBoard
        TimelineView(.periodic(from: .now, by: 30)) { context in
            // The timeline's date is its last tick, before a reading made since ("just now").
            let now = max(context.date, Date())
            let state = board.states[request]
            let checking = board.checking.contains(request)
            InspectorSection("Usage") {
                InspectorCard(padded: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(request.account.kind == .pi ? "OpenRouter key allowance" : "Account allowance")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondaryText)
                            Spacer()
                            Button { Task { await refresh(.manual) } } label: {
                                if checking {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(width: 22, height: 22)
                            .disabled(checking || !canRefresh(state, at: now))
                            .accessibilityLabel("Refresh account usage")
                            .help(refreshHelp(state, at: now))
                        }
                        if let reading = state?.reading {
                            ForEach(reading.windows) { window in
                                UsageWindowView(window: window, now: now)
                            }
                            if let note = reading.note {
                                Text(note).font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
                            }
                            let facts = reading.facts
                            if !facts.isEmpty {
                                // The account's credits and free resets, under a hairline.
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(facts) { fact in
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(fact.label).foregroundStyle(Palette.secondaryText)
                                            Spacer(minLength: 4)
                                            Text(fact.value).monospacedDigit().multilineTextAlignment(.trailing)
                                        }
                                    }
                                }
                                .font(.system(size: 12))
                                .padding(.top, 12)
                                .overlay(alignment: .top) { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
                            }
                        }
                        freshness(state, checking: checking, now: now)
                        if request.account.kind == .muse {
                            Text("Updates hourly with a brief Muse request.")
                                .font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // As the background does, each minute while it shows, for an account it may not cover.
        .task {
            while !Task.isCancelled {
                await refresh(.background)
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
        .onChange(of: isRunning) { wasRunning, running in
            if wasRunning && !running { Task { await refresh(.manual) } }
        }
    }

    /// When it was read, and whether that is stale or the last check failed, as Providers says it,
    /// with the error spelt out below.
    @ViewBuilder private func freshness(_ state: UsageState?, checking: Bool, now: Date) -> some View {
        if let reading = state?.reading {
            let stale = state?.error != nil || state?.isStale(at: now, interval: request.backgroundInterval) == true
            HStack(spacing: 4) {
                if state?.error != nil {
                    Label("Stale", systemImage: "exclamationmark.triangle.fill").fontWeight(.medium).foregroundStyle(Palette.warning)
                } else if stale {
                    Text("Stale").fontWeight(.medium).foregroundStyle(Palette.warning)
                }
                Text("\(stale ? "· updated" : "Updated") \(RelativeDate.text(reading.readAt, now: now))")
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondaryText)
            }
            .font(.system(size: 11))
            .help("Read \(reading.readAt.formatted(date: .complete, time: .standard))")
        } else if state?.error != nil {
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.warning)
        } else if state == nil || checking {
            Text(request.account.kind == .muse ? "Checking with a brief Muse request…" : "Checking \(request.account.name)…")
                .font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
        }
        if let error = state?.error {
            Text(error).font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
        }
    }

    private func canRefresh(_ state: UsageState?, at now: Date) -> Bool {
        state?.nextManualCheck(interval: request.manualInterval).map { now >= $0 } ?? true
    }

    private func refreshHelp(_ state: UsageState?, at now: Date) -> String {
        if !canRefresh(state, at: now), let next = state?.nextManualCheck(interval: request.manualInterval) {
            return "Can be checked again at \(next.formatted(date: .omitted, time: .shortened))"
        }
        return request.account.kind == .muse
            ? "Check Muse with a brief request (at most once every five minutes)"
            : "Refresh the selected account’s allowance"
    }

    private func refresh(_ check: UsageCheck) async {
        await model.usageBoard.refresh(request, usage: model.usage, openRouterKey: model.openRouterKey, for: check)
    }
}

/// A window's use and its reset as the time left and when: "Resets in 1d 10h, Monday at 5:00 PM".
struct UsageWindowView: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        let percent = window.currentPercent(at: now)
        let line = UsageLine(window, at: now)
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
                UsageBar(title: window.title, percent: percent).frame(height: 5)
            }
            if let detail = window.detail, !window.hasReset(at: now) {
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
            }
            Text(line.resetSentence)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Palette.secondaryText)
                .help(window.resetsAt?.formatted(date: .complete, time: .standard) ?? line.resetSentence)
        }
    }
}

/// How much of an allowance window is used, here and in the Providers table; in a selected table
/// row, white on a lighter track.
struct UsageBar: View {
    let title: String
    let percent: Double
    var track = Palette.rowDivider
    /// A stale reading's bar, faded.
    var dimmed = false
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(selected ? AnyShapeStyle(.white.opacity(0.3)) : AnyShapeStyle(track))
                Capsule().fill(selected ? .white : percent >= 100 ? Palette.dynamic(0xD93A2F, 0xFF6B60)
                               : percent >= 80 ? Palette.warning : Palette.violet)
                    .frame(width: geometry.size.width * min(100, max(0, percent)) / 100)
                    .opacity(dimmed ? 0.45 : 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) allowance used")
        .accessibilityValue("\(percent.formatted(.number.precision(.fractionLength(0)))) percent")
    }
}
