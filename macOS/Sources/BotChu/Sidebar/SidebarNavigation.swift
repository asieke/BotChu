import Foundation
import BotChuCore

/// Sidebar navigation points at conversations, while galleries preserve the remembered one.
enum SidebarDestination: Hashable {
    case library(LibraryDestination)
    case botHome(UUID)
    case botTask(botID: UUID, taskID: UUID)

    var botID: UUID? {
        switch self {
        case .library: nil
        case .botHome(let id), .botTask(let id, _): id
        }
    }
}

/// Only structural changes affect expansion; streaming output never reopens a collapsed group.
struct SidebarStructure: Equatable {
    var botIDs: [UUID]
    var taskIDs: [UUID: [UUID]]
    var selection: SidebarDestination?
}

struct SidebarExpansion {
    private(set) var botIDs: Set<UUID> = []
    private var previous: SidebarStructure?

    mutating func update(_ structure: SidebarStructure) {
        botIDs.formIntersection(structure.botIDs)
        for id in structure.botIDs {
            let tasks = structure.taskIDs[id, default: []]
            if previous == nil || !Set(tasks).isSubset(of: Set(previous?.taskIDs[id] ?? [])) {
                if !tasks.isEmpty { botIDs.insert(id) }
            }
        }
        if previous == nil || previous?.selection != structure.selection,
           let id = structure.selection?.botID, structure.botIDs.contains(id) {
            botIDs.insert(id)
        }
        previous = structure
    }

    mutating func toggle(_ id: UUID) {
        if !botIDs.insert(id).inserted { botIDs.remove(id) }
    }

    mutating func reveal(_ destination: SidebarDestination) {
        if let id = destination.botID { botIDs.insert(id) }
    }
}

extension AppModel {
    var sidebarSelection: SidebarDestination? {
        if let destination { return .library(destination) }
        guard let selection else { return nil }
        let target = tab(of: selection)
        return target.taskID.map { .botTask(botID: selection, taskID: $0) } ?? .botHome(selection)
    }

    var sidebarStructure: SidebarStructure {
        SidebarStructure(botIDs: bots.map(\.id),
                         taskIDs: Dictionary(uniqueKeysWithValues: bots.map { ($0.id, openTasks(of: $0.id).map(\.id)) }),
                         selection: sidebarSelection)
    }

    func selectSidebar(_ destination: SidebarDestination) {
        switch destination {
        case .library(let library): self.destination = library
        case .botHome(let id): show(.home(id))
        case .botTask(let botID, let taskID): show(.task(taskID, of: botID))
        }
    }

    func runningTaskCount(for botID: UUID) -> Int {
        openTasks(of: botID).filter { isRunning(.task($0.id, of: botID)) }.count
    }
}
