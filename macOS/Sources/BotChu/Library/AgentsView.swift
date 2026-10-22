import SwiftUI
import BotChuCore

struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    private var matches: [Bot] { model.bots.filter { query.isEmpty || [$0.name, $0.title, $0.account.name].joined(separator: " ").localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryHeading(title: "Agents", subtitle: "Choose who you work with. Each bot keeps its own memory and personality.", count: model.bots.count) {
                Button { model.newBot() } label: { Label("New Agent", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            LibrarySearch(text: $query, prompt: "Search agents").padding(.horizontal, 24).padding(.bottom, 16)
            if matches.isEmpty {
                LibraryEmpty(title: model.bots.isEmpty ? "Create your first agent" : "No matching agents", subtitle: "Give a bot a name, a role, and a provider to get started.", symbol: "person.2")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16)], spacing: 16) {
                        ForEach(matches) { bot in
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(alignment: .top) {
                                    BotAvatar(bot: bot, size: 56, activity: model.status(of: bot).activity, animates: model.isBusy(bot.id))
                                    Spacer()
                                    Text(model.status(of: bot).label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(bot.name).font(.title3.weight(.semibold))
                                    Text(bot.title.isEmpty ? "Ready for your next idea." : bot.title).font(.callout).foregroundStyle(.secondary).lineLimit(2).frame(height: 36, alignment: .topLeading)
                                    Label(bot.account.name, systemImage: bot.account.symbol).font(.caption).foregroundStyle(.secondary)
                                }
                                Divider()
                                HStack {
                                    Text("\(model.openTasks(of: bot.id).count) tasks").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Edit…") { model.edit(bot.id) }
                                    Button("Open Chat") { model.show(model.tab(of: bot.id)) }
                                }
                            }.padding(20).libraryCard()
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }.background(Color(nsColor: .windowBackgroundColor)).frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity).navigationTitle("Agents")
    }
}
