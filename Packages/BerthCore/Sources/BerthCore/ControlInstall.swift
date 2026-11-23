import Foundation

public enum ControlInstall {
    public struct SettingsError: Error, Equatable {
        public let message: String
    }

    public static let hookCommand = #"[ -z "$BERTH_TAB_ID" ] || printf 'You are running inside Berth, tab %s. The berth CLI (see the berth skill) opens, reads and closes terminal tabs in this workspace.\n' "$BERTH_TAB_ID""#

    public static let skill = """
    ---
    name: berth
    description: Drive the Berth workspace this session runs in. Open Claude sessions or run a dev server or tests in a background terminal tab, watch its output, send it input, wait for it to finish, or close it. Only applies when BERTH_TAB_ID is set.
    ---

    # Berth

    This session runs inside a Berth tab when `BERTH_TAB_ID` is set. The `berth` CLI talks to the app over a local socket (`BERTH_SOCKET` and `BERTH_TOKEN`, both already in the environment). Tabs are named by the ids `berth ls` prints.

    - `berth ls [--json]`: every tab (terminals and sessions) with its id, kind, status, title and folder. A leading `*` marks tabs you opened.
    - `berth open-terminal [--cwd <dir>] [--background] -- <command>`: opens a terminal tab in your folder (or `--cwd`), runs the command and prints the new tab's id. Use `--background` so it doesn't take focus. Without a command it opens a plain shell. The tab closes when the command exits.
    - `berth open-session [--cwd <dir>] [--background] [--json] [-- <prompt words>]` opens a Claude session in your folder or the folder given by `--cwd` and prints its tab id. The folder must already exist. Berth starts Claude directly in that folder using its existing checkout. Use `--background` to keep the current tab selected. Text after `--` is pasted into the session as a prompt.
    - `berth send <tab> <text> [--no-enter]`: types text into a tab you opened and presses Return.
    - `berth capture <tab>`: prints the tab's recent output. Works only for tabs running behind Berth's session host ("Keep sessions running when Berth quits" on); otherwise it reports that capture is unsupported.
    - `berth wait <tab> [--timeout <seconds>]`: blocks until the tab's command exits and exits with its status.
    - `berth close <tab>`: closes a tab you opened.

    When you check out PRs or create worktrees, open one Berth session per worktree with `berth open-session --cwd <worktree> --background -- "<prompt>"` so each session shows in the sidebar.

    You can only send to and close terminal and session tabs you opened. Close them when you are done with them. Output of a command that has exited is gone, so redirect it to a file if you need it.
    """

    public static func settings(adding existing: Data?) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.allSatisfy(\.isASCIIWhitespace) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
                throw SettingsError(message: "settings.json isn't a JSON object, so Berth left it alone")
            }

            root = parsed
        }
        guard root["hooks"] == nil || root["hooks"] is [String: Any] else {
            throw SettingsError(message: "settings.json has hooks in a shape Berth doesn't recognise, so it left them alone")
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        guard hooks["SessionStart"] == nil || hooks["SessionStart"] is [[String: Any]] else {
            throw SettingsError(message: "settings.json has hooks in a shape Berth doesn't recognise, so it left them alone")
        }

        var groups = hooks["SessionStart"] as? [[String: Any]] ?? []
        guard !groups.contains(where: { ($0["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == hookCommand } == true }) else { return existing ?? Data() }

        groups.append(["hooks": [["type": "command", "command": hookCommand]]])
        hooks["SessionStart"] = groups
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func hasHook(in settings: Data?) -> Bool {
        guard let settings, let root = (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any], let groups = (root["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]] else { return false }

        return groups.contains { ($0["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == hookCommand } == true }
    }

    /// What the install adds to settings.json, for the confirmation.
    public static var hookPreview: String {
        let entry: [String: Any] = ["hooks": ["SessionStart": [["hooks": [["type": "command", "command": hookCommand]]]]]]
        let data = try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool { self == 0x20 || self == 0x0A || self == 0x0D || self == 0x09 }
}
