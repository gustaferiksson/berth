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
    let response = try ControlClient.send(invocation.request, socketPath: invocation.socketPath)
    guard response.succeeded else {
        fputs("berth: \(response.error ?? "failed")\n", stderr)
        exit(1)
    }

    let output = ControlCommand.render(response, json: invocation.json)
    if !output.isEmpty { print(output) }
    exit(response.exit ?? 0)
} catch {
    fputs("berth: can't reach Berth (\(error)). Is Agent Control on in Settings > General?\n", stderr)
    exit(1)
}
