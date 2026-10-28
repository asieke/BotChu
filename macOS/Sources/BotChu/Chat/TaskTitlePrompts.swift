import SwiftUI
import BotChuCore

/// A task's Rename… and Regenerate Title (#236), in its menu (`TaskMenu`), in its tab and its tile.
/// While its title is being made again, the menu says so, and choosing it again asks nothing more.
struct TaskTitleItems: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget

    var body: some View {
        Button("Rename…") { model.askToRename(target) }
        if model.isRegeneratingTitle(target) {
            Button("Regenerating Title…") {}
                .disabled(true)
        } else {
            Button("Regenerate Title") { model.regenerateTitle(target) }
        }
    }
}

/// Where a task of the bot beside its chat is renamed, in an alert that starts from the title its
/// tab shows (an empty name changes nothing), and where a title that couldn't be made again says
/// why, with what to do about it: open Quick tasks' settings, or try again. Cancel changes nothing.
struct TaskTitlePrompts: ViewModifier {
    @Environment(AppModel.self) private var model
    let botID: UUID

    func body(content: Content) -> some View {
        let renaming = model.renamingTask?.botID == botID ? model.renamingTask : nil
        let notice = model.titleNotice?.botID == botID ? model.titleNotice : nil
        content
            .alert("Rename Task", isPresented: Binding(
                get: { model.renamingTask?.botID == botID }, set: { if !$0 { model.renamingTask = nil } }),
                presenting: renaming) { target in
                TextField("Title", text: Binding(get: { model.renamingText }, set: { model.renamingText = $0 }))
                Button("Rename") { _ = model.renameTask(target, to: model.renamingText) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The title its tab shows. Its issue, branch and folder keep their names.")
            }
            .alert(notice?.title ?? "", isPresented: Binding(
                get: { model.titleNotice?.botID == botID },
                set: { if !$0, model.titleNotice?.id == notice?.id { model.titleNotice = nil } }),
                presenting: notice) { notice in
                Button(notice.action) { act(on: notice) }
                Button("Cancel", role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
    }

    private func act(on notice: TaskTitleNotice) {
        model.titleNotice = nil
        switch notice.kind {
        case .notConfigured: model.openSettings(.general)
        case .failed: model.regenerateTitle(.task(notice.taskID, of: notice.botID))
        }
    }
}
