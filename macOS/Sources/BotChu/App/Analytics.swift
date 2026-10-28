import AppKit
import BotChuCore

extension AppModel {
    /// View ▸ Open Analytics Dashboard (#233): reads what BotChu has recorded, off the main thread,
    /// into a page in its data folder that only this user can read (`AnalyticsDashboard`), and opens
    /// it in the default browser. It is a file, so nothing listens on a port; choosing it again makes
    /// it again with current data.
    func openAnalyticsDashboard() {
        let running = Set(conversations.filter { $0.value.run != nil }.map { AnalyticsConversation(botID: $0.key.botID, taskID: $0.key.taskID) })
        let input = AnalyticsInput(root: store.root, accounts: settings.accounts, running: running, now: Date(), zone: .current)
        Task {
            let result = await Task.detached(priority: .userInitiated) { AnalyticsDashboard.publish(input) }.value
            switch result {
            case .success(let page):
                Self.openInBrowser(page)
            case .failure(let failure):
                let alert = NSAlert()
                alert.messageText = "Couldn't open the analytics dashboard"
                alert.informativeText = failure.message
                alert.runModal()
            }
        }
    }

    /// The browser that opens web links, rather than whatever app opens `.html` files here (an editor, say).
    private static func openInBrowser(_ page: URL) {
        let workspace = NSWorkspace.shared
        if let link = URL(string: "http://localhost"), let browser = workspace.urlForApplication(toOpen: link) {
            workspace.open([page], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.open(page)
        }
    }
}
