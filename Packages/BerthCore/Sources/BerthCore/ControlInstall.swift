import Foundation

public enum ControlInstall {
    public struct SettingsError: Error, Equatable {
        public let message: String
    }

    public static let hookCommand = #"[ -z "$BERTH_TAB_ID" ] || printf 'You are running inside Berth, tab %s. Use berth show-pr to show a GitHub PR in Review. Use berth browser open to open the dev server and berth browser snapshot to find elements to interact with. Browser commands see only the current session tabs and omit pinned tabs. See the berth skill for command syntax.\n' "$BERTH_TAB_ID""#

    public static let skill = """
    ---
    name: berth
    description: Drive the Berth workspace this session runs in. Show a GitHub PR in Review or a folder in Berth, open and interact with pages in the current session’s Browser pane, open Claude sessions, or run and manage dev servers and tests in background terminal tabs. Only applies when BERTH_TAB_ID is set.
    ---

    # Berth

    This session runs inside a Berth tab when `BERTH_TAB_ID` is set. The `berth` CLI talks to the app over a local socket (`BERTH_SOCKET` and `BERTH_TOKEN`, both already in the environment). Tabs are named by the ids `berth ls` prints.

    - `berth ls [--json]`: every tab (terminals and sessions) with its id, kind, status, title and folder. A leading `*` marks tabs you opened.
    - `berth open-terminal [--cwd <dir>] [--background] -- <command>`: opens a terminal tab in your folder (or `--cwd`), runs the command and prints the new tab's id. Use `--background` so it doesn't take focus. Without a command it opens a plain shell. The tab closes when the command exits.
    - `berth open-session [--cwd <dir>] [--background] [--json] [-- <prompt words>]` opens a Claude session in your folder or the folder given by `--cwd` and prints its tab id. The folder must already exist. Berth starts Claude directly in that folder using its existing checkout. Use `--background` to keep the current tab selected. Text after `--` is pasted into the session as a prompt.
    - `berth open <path> [--background] [--json]`: shows a folder to the user. Selects the Claude session tab already in that folder, or opens one there, and prints the tab id. The path must exist and be a folder, Berth cannot open a single file. Use it when the user asks you to open or show a project in Berth.
    - `berth open-url <url> [--background] [--json]`: opens an http or https page as a new tab in the current session’s Browser pane, so the user sees it next to the session (a dev server, a deploy preview, docs). `--background` adds the tab without switching the pane to Browser.
    - `berth browser tabs [--json]` lists the current session’s browser tabs with their ids, titles, URLs and loading states. A leading `*` marks the active session tab.
    - `berth browser screenshot [--tab <id>] [--out <path>] [--full-page] [--json]` saves a PNG and prints its path. Without `--out` it uses a new temporary file. Full-page screenshots are capped at 10000 points in height.
    - `berth browser console [--tab <id>] [--since <n>] [--follow] [--json]` prints recent console messages, JS errors and network failures. `--since` returns only sequences after `n`. `--follow` polls for new entries and prints one JSON object per line with `--json`.
    - `berth browser url [--tab <id>] [--json]` prints the current URL.
    - `berth browser reload [--tab <id>] [--json]` reloads the current page.
    - `berth browser navigate <url> [--tab <id>] [--json]` takes the tab to an http or https URL.
    - `berth browser text [--tab <id>] [--json]` prints the page’s visible text, capped at 100000 characters.
    - `berth browser html [--tab <id>] [--selector <css>] [--json]` prints the formatted DOM for the page or the first matching element, capped at 100000 characters.
    - `berth browser snapshot [--tab <id>] [--json]` prints an accessibility-style outline with roles, names, states and element refs, capped at 100000 characters.
    - `berth browser open [<url>] [--background] [--json]` opens an http or https URL like `berth open-url`. Omit the URL to open a blank tab and show the Browser pane. Use `--background` to keep the current pane and tab selected.
    - `berth browser click <target> [--tab <id>] [--json]` clicks an element.
    - `berth browser fill <target> <text> [--tab <id>] [--json]` replaces an editable element’s value.
    - `berth browser type <text> [--tab <id>] [--json]` types into the focused element.
    - `berth browser press <key> [--tab <id>] [--json]` sends Enter, Tab, Escape, Backspace, Delete, Space, ArrowUp, ArrowDown, ArrowLeft, ArrowRight, Home, End, PageUp, PageDown or a single character. Join modifiers with `+`, as in `Shift+Tab`, `Control+a`, `Meta+Enter` or `Alt+ArrowLeft`.
    - `berth browser select <target> <value> [--tab <id>] [--json]` selects an option by value, falling back to its label.
    - `berth browser hover <target> [--tab <id>] [--json]` sends pointer and mouse hover events.
    - `berth browser scroll (<target> | --to top|bottom | --by <px>) [--tab <id>] [--json]` scrolls an element into view or scrolls the page to an edge or by a signed pixel offset. Choose one mode.
    - `berth browser wait (<selector> | --text <text> | --url <substring> | --load | --ms <n>) [--timeout <seconds>] [--tab <id>] [--json]` waits for a visible CSS match, visible page text, a URL substring, page load or a duration in milliseconds. Choose one condition. The timeout defaults to 10 seconds.
    - `berth browser back [--tab <id>] [--json]` goes back in the tab’s history.
    - `berth browser forward [--tab <id>] [--json]` goes forward in the tab’s history.
    - `berth browser eval <js> [--tab <id>] [--json]` runs an async JavaScript body in the page for cases the other commands do not cover. Use `return` to return a JSON value, for example `return document.title`. Results are limited to 100000 characters.
    - `berth show-pr <number|url> [--repo <path>] [--json]` expands a GitHub pull request in the current session’s Review panel and opens its first changed file. A number uses the origin of your current repo or `--repo`. For a URL such as `https://github.com/acme/api/pull/42`, Berth looks for a matching local clone. Use `--repo` if the clone is elsewhere.
    - `berth send <tab> <text> [--no-enter]`: types text into a tab you opened and presses Return.
    - `berth capture <tab>`: prints the tab's recent output. Works only for tabs running behind Berth's session host ("Keep sessions running when Berth quits" on); otherwise it reports that capture is unsupported.
    - `berth wait <tab> [--timeout <seconds>]`: blocks until the tab's command exits and exits with its status.
    - `berth close <tab>`: closes a tab you opened.

    When the user asks to review or check out a PR in Berth, use `berth show-pr` to show it in their current tab. If the user asks for a separate working session, open it with `berth open-session --cwd <worktree> --background -- "<prompt>"` so each session shows in the sidebar.

    Run `berth browser open <dev server url>`, then `berth browser snapshot`. Act on the refs it reports with commands such as `berth browser click e12` or `berth browser fill e7 "text"`. Check the result with `berth browser screenshot` or `berth browser console`.

    Targets accept a snapshot ref such as `e12`, `text=<visible text>` or a CSS selector. Text targets prefer exact matches, then partial matches, and favor interactive elements. Take a new snapshot if a ref is stale. When multiple elements match, the outcome reports that Berth used the first in document order.

    Browser commands see only the current session’s tabs and omit pinned tabs. `--tab` accepts a unique id prefix. When omitted, Berth uses the selected session tab or falls back to the last session tab.

    You can only send to and close terminal and session tabs you opened. Close them when you are done with them. Output of a command that has exited is gone, so redirect it to a file if you need it.
    """

    private static let hookSignature = #"[ -z "$BERTH_TAB_ID" ] ||"#

    /// Brings a skill and hook that Berth installed earlier up to date. Installs nothing that is absent.
    public static func refreshInstalled(skillFile: URL, settingsFile: URL) throws {
        if let installed = try? String(contentsOf: skillFile, encoding: .utf8), installed.contains("\nname: berth\n"), installed.contains("BERTH_TAB_ID"), installed != skill {
            try Data(skill.utf8).write(to: skillFile, options: .atomic)
        }
        guard let existing = try? Data(contentsOf: settingsFile), let refreshed = refreshedHook(in: existing) else { return }

        let backup = settingsFile.appendingPathExtension("berth-backup")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: settingsFile, to: backup)
        try refreshed.write(to: settingsFile, options: .atomic)
    }

    private static func refreshedHook(in settings: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any], var hooks = root["hooks"] as? [String: Any], var groups = hooks["SessionStart"] as? [[String: Any]] else { return nil }

        var isChanged = false
        for group in groups.indices {
            guard var entries = groups[group]["hooks"] as? [[String: Any]] else { continue }

            for entry in entries.indices {
                guard let command = entries[entry]["command"] as? String, command.hasPrefix(hookSignature), command != hookCommand else { continue }

                entries[entry]["command"] = hookCommand
                isChanged = true
            }
            groups[group]["hooks"] = entries
        }
        guard isChanged else { return nil }

        hooks["SessionStart"] = groups
        root["hooks"] = hooks
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

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
