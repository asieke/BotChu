// The headless agent behind BotChu's Sail account (`SailCommand`): one turn per run, on Sail's Flex
// completion window, its events as JSON lines on stdout. The app runs the copy built beside it.
import Foundation
import BotChuCore

Task {
    let status = await SailCommand.main(arguments: Array(CommandLine.arguments.dropFirst()),
                                        environment: ProcessInfo.processInfo.environment,
                                        directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
    exit(status)
}
dispatchMain()
