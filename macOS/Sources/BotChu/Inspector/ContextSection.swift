import SwiftUI
import BotChuCore

/// What the conversation is about (#320): its context from the Quick tasks profile, with how old it
/// is beside the heading. Nothing shows without a Quick tasks profile, nor until there is one.
struct ContextSection: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget

    var body: some View {
        if let context = model.context(of: target) {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                InspectorSection("Context", trailing: BotInspector.ago(context.madeAt)) {
                    InspectorCard(padded: true) {
                        Text(context.text)
                            .font(.system(size: 13))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

extension View {
    /// Reads the shown conversation's saved context (#320) once there is a Quick tasks profile.
    func readsContext(of target: ChatTarget, in model: AppModel) -> some View {
        task(id: model.settings.quickTasks == nil ? nil : target) { model.readContext(target) }
    }
}
