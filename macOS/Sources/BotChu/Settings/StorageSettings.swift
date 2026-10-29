import AppKit
import SwiftUI
import BotChuCore

struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var preview: [StorageMove] = []
    @State private var showingPreview = false
    @State private var message: String?
    @State private var move: Task<Void, Never>?
    @State private var availability = StorageAvailability.unconfigured

    var body: some View {
        @Bindable var settings = model.settings
        Section("Storage locations") {
            location("Workspace", path: Binding(get: { settings.reposRoot }, set: { model.setWorkspaceRoot($0) }), kind: .repository)
            location("Bots", path: Binding(get: { settings.botsRoot }, set: { model.setBotsRoot($0) }), kind: .bot)
            location("Archive", path: $settings.archiveRoot, kind: nil)
            Text("Archive: \(availability.label)").font(.caption).foregroundStyle(.secondary)
            if model.storageMovePending {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for turns or moving folders… New turns are paused.").font(.caption)
                    Button("Cancel") { move?.cancel() }
                }
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            if let problem = model.storageMoveProblem { Text(problem).font(.caption).textSelection(.enabled) }
        }
        .task(id: settings.archiveRoot) {
            while !Task.isCancelled {
                availability = StorageAvailability.read(settings.expandedArchiveRoot)
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .sheet(isPresented: $showingPreview) { movePreview }
        Section("Storage Janitor") {
            if let job = settings.janitorJobID.flatMap({ model.jobs.job($0) }) {
                LabeledContent("Security Racoon", value: job.schedule.summary() + " · " + job.schedule.timeZone)
            }
            HStack {
                Button(settings.janitorJobID == nil ? "Set up report-only Janitor" : "Edit Janitor job…") {
                    do { try model.setupJanitor(); message = "Janitor scheduled. Edit its skill and policy in Security Racoon’s workspace." }
                    catch { message = error.localizedDescription }
                }
                .disabled(model.janitorOwner == nil || model.storageMovePending)
                if let bot = model.janitorOwner {
                    Button("Show skill and policy") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: bot.workspace).appendingPathComponent(Janitor.skillPath),
                            URL(fileURLWithPath: bot.workspace).appendingPathComponent(Janitor.policyPath)])
                    }
                }
            }
        }.help("Starts report-only, daily at 3 a.m. while BotChu is open and the Mac is awake. Approve a concrete preview, scope and retention policy before enabling cleanup. Edit the schedule in Jobs.")
    }

    private func location(_ name: String, path: Binding<String>, kind: StorageMove.Kind?) -> some View {
        LabeledContent(name) {
            VStack(alignment: .trailing) {
                HStack {
                    TextField("\(name) folder", text: path).labelsHidden().settingsField()
                        .font(.system(size: 12, design: .monospaced))
                    Button("Choose…") { if let folder = chooseFolder() { path.wrappedValue = folder.path } }
                }
                if let kind {
                    Button("Move existing…") {
                        preview = model.storageMovePreview(kind)
                        showingPreview = true
                    }
                }
            }
        }.disabled(model.storageMovePending)
            .help("New locations affect new items only. Move existing… previews a separate move and waits for running turns.")
    }

    private var movePreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move existing folders").font(.headline)
            Text("Folders and their data move to the paths below. BotChu updates task associations and Git worktree paths. Existing destinations are never overwritten.")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if preview.isEmpty { Text("No existing folders need moving to this location.") }
                    ForEach(preview) { item in
                        VStack(alignment: .leading) {
                            Text(item.source)
                            Text("→ \(item.destination)")
                            if let problem = problem(item) { Text(problem).foregroundStyle(.red) }
                        }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showingPreview = false }.keyboardShortcut(.cancelAction)
                Button("Move these folders") {
                    let plan = preview
                    showingPreview = false
                    move = Task {
                        do { try await model.moveStorage(plan); message = "Moved \(plan.count) folders." }
                        catch is CancellationError { message = "Move cancelled. Completed moves were kept; remaining folders stayed in place." }
                        catch { message = error.localizedDescription }
                        move = nil
                    }
                }.disabled(preview.isEmpty || preview.contains { problem($0) != nil })
            }
        }.padding(24).frame(width: 640, height: 420)
    }

    private func problem(_ item: StorageMove) -> String? {
        do { try item.validate(); return nil } catch { return error.localizedDescription }
    }
}
