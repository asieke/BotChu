import AppKit
import BotChuCore

extension AppModel {
    /// View ▸ Open Testing Dashboard (#434): the releases `scripts/release-record.py` recorded, made
    /// into a page in the data folder off the main thread (`TestingDashboard`) and opened in the browser.
    func openTestingDashboard() {
        let root = dataFolder
        Task {
            let result = await Task.detached(priority: .userInitiated) { TestingDashboard.publish(root: root) }.value
            switch result {
            case .success(let page):
                Self.openInBrowser(page)
            case .failure(let failure):
                let alert = NSAlert()
                alert.messageText = "Couldn't open the testing dashboard"
                alert.informativeText = failure.message
                alert.runModal()
            }
        }
    }
}
