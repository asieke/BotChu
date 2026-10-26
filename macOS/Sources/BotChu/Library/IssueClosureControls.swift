import SwiftUI

/// Shared by a row's context menu and the sidebar detail's archive menu.
struct IssueClosureActions: View {
    @Environment(AppModel.self) private var model
    let repo: String
    let number: Int
    let title: String

    var body: some View {
        ForEach(IssueClosure.Disposition.allCases, id: \.self) { disposition in
            Button(disposition.action + "…") {
                model.askToCloseIssue(number, of: repo, title: title, as: disposition)
            }
            .disabled(model.updatingIssues.contains("\(repo)#\(number)"))
        }
    }
}

struct IssueClosurePrompt: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let request = model.issueClosure
        content
            .confirmationDialog("\(request?.disposition.question ?? "Archive issue") #\(request?.number ?? 0) of \(request?.repo ?? "")?", isPresented: Binding(
                get: { model.issueClosure != nil && model.issueClosure?.failure == nil },
                set: { if !$0, model.issueClosure?.failure == nil { model.issueClosure = nil } }),
                titleVisibility: .visible, presenting: request) { request in
                Button(request.disposition.action) { Task { await model.closeIssue(request) } }
            } message: { request in
                Text("“\(request.title)” will be closed as not planned and leave the open issues list. "
                     + "Its description, comments and link stay on GitHub, where you can reopen it.")
            }
            .alert("Couldn’t Close Issue #\(request?.number ?? 0)", isPresented: Binding(
                get: { model.issueClosure?.failure != nil }, set: { if !$0 { model.issueClosure = nil } }), presenting: request) { _ in
                Button("OK") {}
            } message: { request in
                Text(request.failure ?? "")
            }
    }
}
