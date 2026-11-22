#if DEBUG
import AppKit
import BerthCore
import Foundation
import GhosttyTerminal

extension Snapshot {
    static func captureHost(mode: String, store: Store, window: NSWindow, output: URL) async {
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil, let id = UserDefaults.standard.string(forKey: "snapshotHostID").flatMap(UUID.init) else {
            FileHandle.standardError.write(Data("snapshot: -snapshotHost needs CFFIXED_USER_HOME and -snapshotHostID <uuid>\n".utf8))
            exit(1)
        }

        let socket = store.hostSocket(of: id) ?? ""
        print("hosts directory \(Store.hostsDirectory), setting \(UserDefaults.standard.bool(forKey: GeneralSettings.keepsSessionsRunningKey))")
        func identity(_ label: String) -> Int32? {
            let found = SessionHost.probe(socketPath: socket)
            print("\(label): host \(found.map { "\($0.host) alive \(kill($0.host, 0) == 0)" } ?? "none"), child \(found.map { "\($0.child) alive \(kill($0.child, 0) == 0)" } ?? "none")")
            return found?.child
        }

        if mode == "new" {
            store.openShell(cwd: NSHomeDirectory(), command: "echo scrollback-marker; exec cat", id: id)
            print("tab hosted \(store.tabs.first?.isHosted ?? false), busy sessions \(store.busySessionCount), isIdle ignores terminal \(store.terminals.allSatisfy(\.isHosted))")
            for _ in 0..<100 where SessionHost.probe(socketPath: socket) == nil { try? await Task.sleep(for: .milliseconds(100)) }
            _ = identity("after open")
            try? await Task.sleep(for: .seconds(1))
            print("pasted \(store.tabs.first?.terminal.paste(text: "typed-by-run-1\r") ?? false)")
            try? await Task.sleep(for: .seconds(1))
        } else if mode == "reattach" {
            _ = identity("before reattach")
            let text = SessionHost.scrollback(socketPath: socket).map { String(decoding: $0, as: UTF8.self) } ?? ""
            print("scrollback replayed \(text.debugDescription), has marker \(text.contains("scrollback-marker")), has typed text \(text.contains("typed-by-run-1"))")
            store.reattach(id: id, kind: .shell, cwd: NSHomeDirectory(), sessionID: nil)
            print("tab hosted \(store.tabs.first?.isHosted ?? false)")
            try? await Task.sleep(for: .seconds(2))
            _ = identity("after reattach")
        } else if mode == "close" {
            store.reattach(id: id, kind: .shell, cwd: NSHomeDirectory(), sessionID: nil)
            try? await Task.sleep(for: .seconds(1))
            let child = identity("before close")
            store.close(id)
            try? await Task.sleep(for: .seconds(4))
            print("after close: host answers \(SessionHost.probe(socketPath: socket) != nil), child alive \(child.map { kill($0, 0) == 0 } ?? false), socket file \(FileManager.default.fileExists(atPath: socket))")
        }
        guard let image = image(of: window), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }

        try? png.write(to: output)
        store.isTerminating = true
        ProcessAncestry.hangUpDescendants()
        exit(0)
    }
}
#endif
