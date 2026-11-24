import BerthCore
import Darwin
import Foundation

let invocation: ControlCommand.Invocation

do {
    invocation = try ControlCommand.parse(Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment, currentDirectory: FileManager.default.currentDirectoryPath)
} catch let error as ControlCommand.UsageError {
    fputs("berth: \(error.message)\n", stderr)
    exit(2)
}

do {
    var request = invocation.request
    var entries: [ControlConsoleEntry] = []
    while true {
        var response = try ControlClient.send(request, socketPath: invocation.socketPath)
        guard response.succeeded else {
            fputs("berth: \(response.error ?? "failed")\n", stderr)
            exit(1)
        }

        if let batch = response.console {
            request.tab = response.tab ?? request.tab
            if let last = batch.last { request.since = last.sequence }
            if invocation.follow {
                for entry in batch { print(ControlCommand.render(entry, json: invocation.json)) }
                fflush(nil)
                if response.consoleHasMore != true { try await Task.sleep(for: .milliseconds(500)) }
                continue
            }
            entries.append(contentsOf: batch)
            if response.consoleHasMore == true, entries.count < ControlConsoleEntry.bufferCapacity { continue }

            response.console = Array(entries.prefix(ControlConsoleEntry.bufferCapacity))
            response.consoleHasMore = nil
            response.tab = nil
        }
        let output = ControlCommand.render(response, json: invocation.json)
        if !output.isEmpty { print(output) }
        exit(response.exit ?? 0)
    }
} catch {
    fputs("berth: can't reach Berth (\(error)). Is Agent Control on in Settings > General?\n", stderr)
    exit(1)
}
