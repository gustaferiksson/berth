import BerthCore
import Darwin

let arguments = CommandLine.arguments
guard arguments.count >= 4,
      let socketPath = try? SessionHost.socketPath(directory: arguments[2], id: arguments[3])
else {
    fputs("usage: berth-host new|start <dir> <id> <command> | attach|close|probe <dir> <id>\n", stderr)
    exit(2)
}

switch (arguments[1], arguments.count) {
case ("new", 5), ("start", 5):
    do {
        try SessionHost.start(directory: arguments[2], id: arguments[3], command: arguments[4])
    } catch {
        fputs("berth-host: could not start a session host: \(error)\n", stderr)
        exit(1)
    }
    exit(arguments[1] == "new" ? SessionHost.attach(socketPath: socketPath) : 0)
case ("attach", 4):
    exit(SessionHost.attach(socketPath: socketPath))
case ("close", 4):
    SessionHost.hangUp(socketPath: socketPath)
case ("probe", 4):
    guard let found = SessionHost.probe(socketPath: socketPath) else { exit(1) }

    print("host \(found.host) child \(found.child)")
default:
    fputs("berth-host: unknown command\n", stderr)
    exit(2)
}
