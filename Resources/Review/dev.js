const devParams = new URLSearchParams(location.search)

const LIGHT_STORE_BASE = `import Foundation
import LanternCore
import Observation

@Observable
final class LightStore {
    private(set) var lights: [Light] = []
    private(set) var rooms: [Room] = []
    private(set) var activeScene: Scene?
    private let dimmer = Dimmer(step: 0.05)

    func apply(_ scene: Scene) {
        for light in lights {
            let level = scene.level(for: light.id)
            dimmer.set(light.id, to: level)
        }
        activeScene = scene
    }

    func light(named name: String) -> Light? {
        lights.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    func lights(in room: Room) -> [Light] {
        lights.filter { $0.roomID == room.id }
    }

    func rename(_ light: Light, to name: String) {
        guard let index = lights.firstIndex(where: { $0.id == light.id }) else { return }

        lights[index].name = name
    }

    func move(_ light: Light, to room: Room) {
        guard let index = lights.firstIndex(where: { $0.id == light.id }) else { return }

        lights[index].roomID = room.id
    }

    func sortedRooms() -> [Room] {
        rooms.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func brightness(of light: Light) -> Double {
        dimmer.level(of: light.id)
    }

    func turnOff() {
        for light in lights {
            dimmer.set(light.id, to: 0)
        }
        activeScene = nil
    }
}
`

const LIGHT_STORE = `import Foundation
import LanternCore
import Observation

@Observable
final class LightStore {
    private(set) var lights: [Light] = []
    private(set) var rooms: [Room] = []
    private(set) var activeScene: Scene?
    private(set) var runningFades: [Light.ID: Fade] = [:]
    private let dimmer = Dimmer(step: 0.05)

    func apply(_ scene: Scene, over duration: Duration = .seconds(2)) {
        for light in lights {
            let target = scene.level(for: light.id)
            let fade = Fade(from: dimmer.level(of: light.id), to: target, duration: duration)
            runningFades[light.id] = fade
            dimmer.run(fade, on: light.id)
        }
        activeScene = scene
    }

    func light(named name: String) -> Light? {
        lights.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    func lights(in room: Room) -> [Light] {
        lights.filter { $0.roomID == room.id }
    }

    func rename(_ light: Light, to name: String) {
        guard let index = lights.firstIndex(where: { $0.id == light.id }) else { return }

        lights[index].name = name
    }

    func move(_ light: Light, to room: Room) {
        guard let index = lights.firstIndex(where: { $0.id == light.id }) else { return }

        lights[index].roomID = room.id
    }

    func sortedRooms() -> [Room] {
        rooms.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func brightness(of light: Light) -> Double {
        dimmer.level(of: light.id)
    }

    func turnOff() {
        apply(.off, over: .milliseconds(400))
    }

    func cancelFades() {
        runningFades.keys.forEach { dimmer.stop($0) }
        runningFades.removeAll()
    }
}
`

const FADE = `import Foundation

public struct Fade: Sendable, Hashable {
    public let from: Double
    public let to: Double
    public let duration: Duration

    public init(from: Double, to: Double, duration: Duration) {
        self.from = from
        self.to = to
        self.duration = duration
    }

    public func level(at elapsed: Duration) -> Double {
        guard duration > .zero else { return to }

        let progress = min(1, max(0, elapsed / duration))
        return from + (to - from) * easeInOut(progress)
    }

    private func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}
`

const SCENE_BASE = `import Foundation

public struct Scene: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var levels: [String: Double]

    public init(id: UUID = UUID(), name: String, levels: [String: Double]) {
        self.id = id
        self.name = name
        self.levels = levels
    }

    public func level(for lightID: String) -> Double {
        levels[lightID] ?? 0
    }
}
`

const SCENE = SCENE_BASE.replace(`    public func level`, `    public static let off = Scene(name: "Off", levels: [:])

    public func level`)

const DIMMER = `import Foundation

public final class Dimmer {
    public let step: Double
    private var levels: [String: Double] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(step: Double) {
        self.step = step
    }

    public func level(of lightID: String) -> Double {
        levels[lightID] ?? 0
    }

    public func set(_ lightID: String, to level: Double) {
        stop(lightID)
        levels[lightID] = (level / step).rounded() * step
    }

    public func run(_ fade: Fade, on lightID: String) {
        stop(lightID)
        tasks[lightID] = Task { @MainActor in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                let elapsed = ContinuousClock.now - start
                levels[lightID] = fade.level(at: elapsed)
                if elapsed >= fade.duration { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    public func stop(_ lightID: String) {
        tasks.removeValue(forKey: lightID)?.cancel()
    }
}
`

const TIMER = `import Foundation

struct Timer: Identifiable, Codable {
    let id: UUID
    var sceneID: UUID
    var fireAt: DateComponents
    var isEnabled: Bool
}
`

const SCHEDULE = `import Foundation

struct Schedule: Identifiable, Codable {
    let id: UUID
    var sceneID: UUID
    var fireAt: DateComponents
    var weekdays: Set<Int>
    var isEnabled: Bool

    func fires(on date: Date, calendar: Calendar = .current) -> Bool {
        isEnabled && weekdays.contains(calendar.component(.weekday, from: date))
    }
}
`

const FADE_TESTS = `import Testing
@testable import LanternCore

@Test func fadeStartsAtFrom() {
    let fade = Fade(from: 0.2, to: 0.8, duration: .seconds(1))
    #expect(fade.level(at: .zero) == 0.2)
}

@Test func fadeEndsAtTo() {
    let fade = Fade(from: 0.2, to: 0.8, duration: .seconds(1))
    #expect(fade.level(at: .seconds(2)) == 0.8)
}

@Test func zeroDurationJumps() {
    let fade = Fade(from: 0, to: 1, duration: .zero)
    #expect(fade.level(at: .zero) == 1)
}
`

const CONTENT_VIEW_BASE = `import SwiftUI

struct ContentView: View {
    @Environment(LightStore.self) private var store

    var body: some View {
        NavigationSplitView {
            List(store.sortedRooms()) { room in
                NavigationLink(room.name, value: room.id)
            }
        } detail: {
            RoomGrid(lights: store.lights)
        }
        .toolbar {
            Button("All Off") { store.turnOff() }
        }
    }
}
`

const CONTENT_VIEW = CONTENT_VIEW_BASE.replace(`            Button("All Off") { store.turnOff() }`, `            Button("All Off", systemImage: "lightbulb.slash") { store.turnOff() }
            Button("Stop Fades", systemImage: "stop.circle") { store.cancelFades() }
                .disabled(store.runningFades.isEmpty)`)

const API_BASE = `export type Scene = { id: string; name: string; levels: Record<string, number> }

const BASE = "/api"

export async function fetchScenes(): Promise<Scene[]> {
  const response = await fetch(\`\${BASE}/scenes\`)
  return response.json()
}

export async function applyScene(id: string) {
  await fetch(\`\${BASE}/scenes/\${id}/apply\`, { method: "POST" })
}
`

const API = `export type Scene = { id: string; name: string; levels: Record<string, number> }

const BASE = "/api"

export async function fetchScenes(): Promise<Scene[]> {
  const response = await fetch(\`\${BASE}/scenes\`)
  if (!response.ok) throw new Error(\`scenes: \${response.status}\`)
  return response.json()
}

export async function applyScene(id: string, durationMs = 2000) {
  const response = await fetch(\`\${BASE}/scenes/\${id}/apply\`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ durationMs }),
  })
  if (!response.ok) throw new Error(\`apply \${id}: \${response.status}\`)
}
`

const SCENE_LIST_BASE = `import { applyScene, type Scene } from "../api"

export function SceneList({ scenes }: { scenes: Scene[] }) {
  return (
    <ul className="scenes">
      {scenes.map(scene => (
        <li key={scene.id}>
          <button onClick={() => applyScene(scene.id)}>{scene.name}</button>
        </li>
      ))}
    </ul>
  )
}
`

const SCENE_LIST = SCENE_LIST_BASE
  .replace(`export function SceneList({ scenes }: { scenes: Scene[] }) {`, `export function SceneList({ scenes, slow }: { scenes: Scene[]; slow: boolean }) {`)
  .replace(`applyScene(scene.id)}`, `applyScene(scene.id, slow ? 8000 : 2000)}`)

const README_BASE = `# Lantern

A menu bar app for the lights in your flat.

## Build

    ./build.sh
`

const README = README_BASE.replace("## Build", "Scenes fade over two seconds; hold ⌥ to fade slowly.\n\n## Build")

const CHANGED = [
  { path: "Sources/Lantern/LightStore.swift", status: "modified", original: LIGHT_STORE_BASE, modified: LIGHT_STORE },
  { path: "Sources/Lantern/ContentView.swift", status: "modified", original: CONTENT_VIEW_BASE, modified: CONTENT_VIEW },
  { path: "Sources/Lantern/Models/Schedule.swift", oldPath: "Sources/Lantern/Models/Timer.swift", status: "renamed", original: TIMER, modified: SCHEDULE },
  { path: "Packages/LanternCore/Sources/LanternCore/Fade.swift", status: "added", original: null, modified: FADE },
  { path: "Packages/LanternCore/Sources/LanternCore/Scene.swift", status: "modified", original: SCENE_BASE, modified: SCENE },
  { path: "Packages/LanternCore/Tests/LanternCoreTests/FadeTests.swift", status: "added", original: null, modified: FADE_TESTS },
  { path: "web/src/api.ts", status: "modified", original: API_BASE, modified: API },
  { path: "web/src/components/SceneList.tsx", status: "modified", original: SCENE_LIST_BASE, modified: SCENE_LIST },
  { path: "Resources/Assets/lamp.png", status: "added", binary: true },
  { path: "docs/legacy-notes.md", status: "deleted", original: "# Legacy notes\n\nThe v1 bridge spoke UDP on port 5683.\n", modified: null },
  { path: "README.md", status: "modified", original: README_BASE, modified: README },
]

const UNCHANGED = {
  "Packages/LanternCore/Sources/LanternCore/Dimmer.swift": DIMMER,
}

const ALL_FILES = [
  ".gitignore", "LICENSE", "README.md", "build.sh", "project.yml",
  "Sources/Lantern/LanternApp.swift", "Sources/Lantern/ContentView.swift", "Sources/Lantern/LightStore.swift", "Sources/Lantern/MenuBarView.swift", "Sources/Lantern/SettingsView.swift",
  "Sources/Lantern/Models/Light.swift", "Sources/Lantern/Models/Room.swift", "Sources/Lantern/Models/Schedule.swift",
  "Sources/Lantern/Views/BrightnessSlider.swift", "Sources/Lantern/Views/LightRow.swift", "Sources/Lantern/Views/RoomGrid.swift", "Sources/Lantern/Views/SceneButton.swift",
  "Packages/LanternCore/Package.swift",
  "Packages/LanternCore/Sources/LanternCore/Bridge.swift", "Packages/LanternCore/Sources/LanternCore/BridgeDiscovery.swift", "Packages/LanternCore/Sources/LanternCore/Color+Kelvin.swift",
  "Packages/LanternCore/Sources/LanternCore/Dimmer.swift", "Packages/LanternCore/Sources/LanternCore/Fade.swift", "Packages/LanternCore/Sources/LanternCore/Scene.swift",
  "Packages/LanternCore/Tests/LanternCoreTests/DimmerTests.swift", "Packages/LanternCore/Tests/LanternCoreTests/FadeTests.swift", "Packages/LanternCore/Tests/LanternCoreTests/SceneTests.swift",
  "Resources/Info.plist", "Resources/Lantern.entitlements", "Resources/Assets/lamp.png",
  "web/index.html", "web/package.json", "web/tsconfig.json",
  "web/src/main.tsx", "web/src/api.ts", "web/src/components/RoomCard.tsx", "web/src/components/SceneList.tsx", "web/src/hooks/useScenes.ts",
  "docs/architecture.md", "docs/bridge-protocol.md",
]

const counts = (original, modified) => {
  const before = new Set((original ?? "").split("\n"))
  const after = new Set((modified ?? "").split("\n"))
  return {
    additions: (modified ?? "").split("\n").filter(line => !before.has(line)).length,
    deletions: (original ?? "").split("\n").filter(line => !after.has(line)).length,
  }
}

const lineOf = (text, needle) => text.split("\n").findIndex(line => line.includes(needle)) + 1

const seededComments = [
  { path: "Sources/Lantern/LightStore.swift", needle: "runningFades[light.id] = fade", text: "Cancel the running fade for this light first, otherwise two fades fight over the level." },
  { path: "Sources/Lantern/LightStore.swift", needle: "apply(.off, over:", text: "400 ms feels abrupt for All Off; use the default duration?" },
  { path: "Sources/Lantern/LightStore.swift", needle: "func rename(", text: "Rename should also update the menu bar title." },
  { path: "web/src/api.ts", needle: "durationMs = 2000", text: "Share the 2000 default with the Swift side instead of repeating it." },
].map(({ path, needle, text }, i) => {
  const source = CHANGED.find(file => file.path === path).modified
  const line = lineOf(source, needle)
  return { id: `seed${i}`, path, line, endLine: line, text, snippet: source.split("\n")[line - 1] }
})

const devStore = {
  compare: "allChanges",
  comments: devParams.has("comments") ? seededComments : [],
  log: [],
}

const theme = devParams.has("light")
  ? { background: "#fafafa", foreground: "#383a42", selection: "#e5e5e6", palette: ["#383a42", "#e45649", "#50a14f", "#c18401", "#0184bc", "#a626a4", "#0997b3", "#fafafa", "#4f525e", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#ffffff"], fontFamily: "SF Mono", fontSize: 12 }
  : { background: "#282c34", foreground: "#abb2bf", selection: "#3e4451", palette: ["#3f4451", "#e05561", "#8cc265", "#d18f52", "#4aa5f0", "#c162de", "#42b3c2", "#d7dae0", "#4f5666", "#ff616e", "#a5e075", "#f0a45d", "#4dc4ff", "#de73ff", "#4cd1e0", "#e6e6e6"], fontFamily: "SF Mono", fontSize: 12 }

const loadMessage = () => {
  const files = devStore.compare === "uncommitted" ? CHANGED.filter(file => file.path.startsWith("web/")) : CHANGED
  return {
    type: "load",
    theme,
    compare: devStore.compare,
    prNumber: 42,
    base: "origin/main",
    mergeBase: "3f9c2e1",
    fetchedAt: devParams.has("offline") ? null : new Date(Date.now() - 12000).toISOString(),
    fetchError: devParams.has("offline") ? "Could not resolve host: github.com" : null,
    editable: true,
    files: files.map(file => ({ path: file.path, oldPath: file.oldPath ?? null, status: file.status, ...(file.binary ? { additions: null, deletions: null } : counts(file.original, file.modified)) })),
    allFiles: ALL_FILES,
    comments: devStore.comments,
    selectedPath: devParams.get("select") ?? null,
  }
}

const fileMessage = path => {
  const changed = CHANGED.find(file => file.path === path)
  if (changed) return { type: "file", path, original: changed.original ?? null, modified: changed.modified ?? null, language: null, binary: changed.binary === true, tooLarge: false, editable: changed.modified != null }

  const extension = path.split(".").pop()
  const text = UNCHANGED[path] ?? `${["swift", "ts", "tsx"].includes(extension) ? "//" : "#"} ${path}\n\n${Array.from({ length: 12 }, (_, i) => `${extension === "swift" ? "let" : "const"} placeholder${i} = ${i}`).join("\n")}\n`
  return { type: "file", path, original: null, modified: text, language: null, binary: path.endsWith(".png"), tooLarge: false, editable: false }
}

const reply = message => setTimeout(() => window.berth.receive(message), 30)

const runScript = () => {
  const modified = monaco.editor.getDiffEditors()[0]?.getModifiedEditor()
  const position = spec => ({ lineNumber: Number(spec.split(":")[0]), column: Number(spec.split(":")[1] ?? 1) })
  if (devParams.has("compose")) {
    const [start, end] = devParams.get("compose").split("-").map(Number)
    modified.setSelection(new monaco.Selection(start, 1, end ?? start, modified.getModel().getLineMaxColumn(end ?? start)))
    modified.getAction("berth.addComment").run()
    setTimeout(() => {
      const textarea = document.querySelector(".thread textarea")
      textarea.value = "Read the level once and reuse it in both places?"
      textarea.dispatchEvent(new Event("input"))
    }, 300)
  }
  if (devParams.has("peek")) {
    modified.setPosition(position(devParams.get("peek")))
    modified.focus()
    modified.trigger("dev", "editor.action.peekDefinition", null)
  }
  if (devParams.has("refs")) {
    modified.setPosition(position(devParams.get("refs")))
    modified.focus()
    modified.trigger("dev", "editor.action.referenceSearch.trigger", null)
  }
  if (devParams.has("goto")) {
    modified.setPosition(position(devParams.get("goto")))
    modified.focus()
    modified.trigger("dev", "editor.action.revealDefinition", null)
  }
  if (devParams.has("type")) {
    modified.executeEdits("dev", [{ range: new monaco.Range(1, 1, 1, 1), text: "// edited\n" }])
  }
}

const respond = message => {
  devStore.log.push(message)
  document.documentElement.dataset.devLog = JSON.stringify(devStore.log.map(entry => ({ ...entry, comments: entry.comments?.length, text: entry.text?.length })))
  if (message.type === "ready" || message.type === "refresh") return reply(loadMessage())
  if (message.type === "selectCompare") {
    devStore.compare = message.compare
    return reply(loadMessage())
  }
  if (message.type === "openFile" || message.type === "readFile") {
    reply(fileMessage(message.path))
    if (message.type === "openFile" && devStore.log.filter(entry => entry.type === "openFile").length === 1) setTimeout(runScript, 600)
    return
  }
  if (message.type === "save") return reply({ type: "saved", path: message.path })
  if (message.type === "commentsChanged") devStore.comments = message.comments
  if (message.type === "definition" || message.type === "references") return reply({ type: "reply", id: message.id, locations: null })
}

try {
  if (devParams.has("files")) localStorage.setItem("berth-review-files", devParams.get("files"))
} catch {}

window.webkit = { messageHandlers: { berth: { postMessage: message => respond(JSON.parse(JSON.stringify(message))) } } }
