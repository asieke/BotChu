import SwiftUI
import BotChuCore

/// Settings ▸ Hosts: the computers besides this Mac that tasks can run on, over SSH.
struct HostsSection: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SSHHost?

    var body: some View {
        Section {
            ForEach(model.settings.hosts) { host in
                HStack(spacing: 10) {
                    Image(systemName: "network").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(host.nickname)
                        Text("\(host.destination) · \(host.reposFolder)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { editing = host }
                    Button {
                        model.settings.hosts.removeAll { $0.id == host.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(host.nickname). Tasks already on it stop until it is back.")
                }
            }
            Button("Add Host…") { editing = SSHHost(nickname: "", destination: "") }
        } header: {
            Text("Hosts")
        } footer: {
            Text("Other computers tasks can work on, over SSH with your keys (never a password). A repository whose PROJECT.md deploys it to a host's machine name works there by default.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { host in
            HostEditor(host: host)
                .environment(model)
        }
    }
}

/// Where the owner chose to work on repositories, in New Task.
struct RepoLocationsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.settings.repoLocations.isEmpty {
            Section {
                ForEach(model.settings.repoLocations.keys.sorted(), id: \.self) { repo in
                    if let location = model.settings.repoLocations[repo] {
                        HStack {
                            Text(repo)
                            Spacer()
                            Text("\(model.machineName(location.hostID)): \(location.hostID == nil ? (location.path as NSString).abbreviatingWithTildeInPath : location.path)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                model.settings.repoLocations[repo] = nil
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Work on \(repo) where it lives by default again")
                        }
                    }
                }
            } header: {
                Text("Repository locations")
            } footer: {
                Text("Chosen in New Task. Any other repository works where its PROJECT.md deploys it, else in the repositories folder on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Adds or edits a host, with a test of the connection that also reads its machine name.
struct HostEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host: SSHHost
    @State private var testing = false
    @State private var tested: Result<String, TaskWorktree.Failure>?
    private let isNew: Bool

    init(host: SSHHost) {
        _host = State(initialValue: host)
        isNew = host.destination.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Add Host" : "Edit \(host.nickname)")
                .font(.headline)
                .padding(.top, 16)
            Form {
                Section {
                    TextField("Nickname", text: $host.nickname, prompt: Text("Omarchy"))
                    TextField("SSH host", text: $host.destination, prompt: Text("alias, host name, or user@host"))
                        .font(.system(.body, design: .monospaced))
                    TextField("Repositories folder", text: $host.reposFolder, prompt: Text("~/apps"))
                        .font(.system(.body, design: .monospaced))
                    TextField("Machine name", text: $host.machine, prompt: Text(SSHHost.machineName(destination: host.destination)))
                        .font(.system(.body, design: .monospaced))
                } footer: {
                    Text("The machine name is what PROJECT.md's deploy calls this computer (local:<machine>:<path>); Test reads it from the host.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(model.settings.accounts) { account in
                        LabeledContent {
                            TextField("Command", text: Binding(get: { host.commands?[account.id] ?? "" },
                                                               set: { host.commands = (host.commands ?? [:]).merging([account.id: $0]) { $1 } }),
                                      prompt: Text(model.settings.command(for: account)))
                                .labelsHidden()
                                .font(.system(.body, design: .monospaced))
                        } label: {
                            ProviderLabel(account)
                        }
                    }
                } header: {
                    Text("Commands there")
                } footer: {
                    Text("Each account's CLI on this host, run through its user's login shell. Leave one empty to use the same command as on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Button("Test Connection", action: test)
                            .disabled(SSHHost.destinationProblem(host.destination) != nil || testing)
                        if testing { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                } footer: {
                    Group {
                        switch tested {
                        case .success(let name)?: Text("Reached \(name).").foregroundStyle(.green)
                        case .failure(let failure)?: Text(failure.message).foregroundStyle(.red).textSelection(.enabled)
                        case nil: Text(problem ?? "BotChu connects with ssh, as you would in Terminal, without asking for a password.")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Host" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .padding(16)
        }
        .frame(width: 520, height: 680)
    }

    private var problem: String? {
        let trimmed = SSHHost(id: host.id, nickname: host.nickname, destination: host.destination, machine: host.machine,
                              reposFolder: host.reposFolder, commands: host.commands)
        if let problem = trimmed.problem { return problem }
        if model.settings.hosts.contains(where: { $0.id != host.id && $0.nickname.caseInsensitiveCompare(trimmed.nickname) == .orderedSame }) {
            return "Another host is called \(trimmed.nickname)."
        }
        return nil
    }

    private func test() {
        testing = true
        tested = nil
        let machine = Machine(destination: host.destination.trimmingCharacters(in: .whitespaces))
        Task {
            let result = await machine.machineName()
            testing = false
            tested = result
            if case .success(let name) = result, host.machine.trimmingCharacters(in: .whitespaces).isEmpty { host.machine = name }
        }
    }

    private func save() {
        var saved = SSHHost(id: host.id, nickname: host.nickname, destination: host.destination, machine: host.machine,
                            reposFolder: host.reposFolder, commands: host.commands?.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty })
        if saved.machine.isEmpty { saved.machine = SSHHost.machineName(destination: saved.destination) }
        if let i = model.settings.hosts.firstIndex(where: { $0.id == saved.id }) {
            model.settings.hosts[i] = saved
        } else {
            model.settings.hosts.append(saved)
        }
        dismiss()
    }
}
