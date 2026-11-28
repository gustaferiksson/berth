# Simulator pane (feasibility spike)

Question: should Berth get a Simulator pane next to the Browser pane, so an agent building an iOS app can boot a simulator, the user sees it beside the session, and the agent can screenshot, tap and type through `berth sim`? No app code was written. Measurements below come from one throwaway device (iPhone 17, iOS 27.0, Xcode 27.2, Apple silicon), created, booted, probed, shut down and deleted.

## What the Browser pane gives us to reuse

- Pane slot: `PaneHost` hosts one view per mode, and the mode switcher already has Browser, Terminal and Tasks that work with Review off (docs/adr/0010).
- Agent path: `berth browser *` goes CLI, per-launch Unix socket, `ControlService.handle`, a per-session approval (`BrowserAccess`, `AgentBrowserPrompt`), then the model (design/flows-terminals.md, Agent control). A sim command would copy that shape, including the approval prompt.
- Constraint that differs: WebKit gives Berth screenshots and input in-process. A simulator is another process tree, so everything goes through Apple tooling.
- Berth ships with an empty entitlements plist (not sandboxed) and hardened runtime, notarized, outside the App Store. Spawning `xcrun` and loading Xcode's frameworks is therefore possible; only the App Store would forbid it.

## Measurements

| Check | Result |
| --- | --- |
| `simctl create` with the iOS 27.2 runtime | Failed, "Incompatible device" (that runtime is tied to one device model). The 27.0 runtime worked. Berth must pick a runtime and device type pair from `simctl list` rather than hardcode. |
| `simctl boot` then `bootstatus -b` | 1.3 s to start, 35 s until fully booted (first boot of a fresh device). |
| `simctl io screenshot` PNG | 1.9 to 7.3 s wall per call over 6 calls, 70 to 190 KB. The slow ones ran while the device was still settling; the best case seen was about 1.4 s (JPEG). Each call is a process launch plus a framebuffer grab. |
| `simctl io screenshot --type=jpeg` | 1.4 s, 460 KB (larger than the PNG here because the screen was mostly flat). |
| `simctl io recordVideo --codec=h264` | Works; SIGINT finalizes the MP4 (72 KB for 3 s of an idle screen). Output is a file, not a stream. |
| `simctl io enumerate` | Lists the framebuffer ports (the device display, 720x480 external ones) and a capture service, which is what the private APIs attach to. |
| `simctl ui appearance dark`, `openurl`, `launch`, `privacy`, `location`, `push`, `keychain` | Exist and cover appearance, deep links, permissions and state. None inject touches or keys. |
| AXe 1.x (installed via Homebrew at /opt/homebrew/bin/axe) `describe-ui` | Returned the full accessibility tree (roles, labels, frames in points, 402x874 on this device) after 12 s on first use ("Timed out creating the simulator remote automation session" on the first try, right after boot). |
| AXe `tap -x 200 -y 400` | Succeeded; 14 s wall, mostly session setup. |
| AXe `stream-video --format mjpeg --fps 10 --scale 0.5` | Delivered 3 MB of MJPEG to a pipe. Its own help says it is built on screenshot capture, so it is polling, not a hardware stream. |

Takeaway: `simctl` alone is fine for an agent screenshot (a second or two) and useless for a live view or input. Input needs a persistent HID session; the per-invocation cost above is mostly that session being rebuilt each time.

## Options for showing the simulator

### A. Poll `simctl io screenshot` into an image view

- Cost: smallest. Public CLI, no private API.
- Tradeoff: 1 to 7 s per frame, so about 0.3 to 1 fps and a process spawn per frame. Fine as a "last known screen" that refreshes after each agent action, bad as a live view.

### B. In-process framebuffer via CoreSimulator and SimulatorKit (private frameworks)

- Frameworks live in Xcode (`CoreSimulator.framework` is at /Library/Developer/PrivateFrameworks, SimulatorKit inside Xcode). The framebuffer exposes an IOSurface through the same ports `simctl io enumerate` lists; Berth could draw it in a `CALayer` at display rate.
- Same machinery gives HID (touch, keyboard, buttons) from one long-lived session, so taps cost milliseconds.
- Tradeoffs: private and changes every Xcode release (the AXe first-call timeout seen here is the kind of fragility to expect). Needs dlopen of the active Xcode's frameworks, ObjC runtime calls with no headers, and a break-and-fix cycle per Xcode. Not an App Store issue for Berth, but a maintenance one.

### C. Helper process that wraps B (idb, AXe, Radon's simulator-server)

- idb (Meta) and AXe wrap the same private frameworks behind a CLI or gRPC server; Radon (Software Mansion's VS Code and Cursor extension) ships its own native helper that streams the simulator into its panel; FlowDeck is a commercial CLI in the same space. I did not install idb or FlowDeck, and the Radon and FlowDeck details are from memory, so treat them as unverified. Only AXe was run.
- Berth would spawn the helper, read MJPEG or frames from a pipe, and call it for taps. The private-API breakage lives in someone else's repo, and a crash cannot take Berth down.
- Tradeoffs: a dependency the user installs (`brew install`), a pipe protocol to parse, and the 12 s first-call setup unless Berth keeps one session open (AXe has `batch` for "one HID session"; a long-lived helper is the real fix). Check AXe's licence before bundling it (not checked).

### D. Host Simulator.app's window inside the pane

- macOS cannot reparent another app's window. The only routes are ScreenCaptureKit capture of that window (needs the Screen Recording permission, and the window still exists on screen) or positioning it beside Berth.
- Opens Simulator.app's UI, which also steals focus. Rejected: worse than B or C on every axis except effort.

### E. Xcode previews, Xcode's own simulator embedding

- Xcode's own simulator embedding and previews are not APIs Berth can call (from memory, unverified). Not an option.

## Input injection

- `simctl` has no tap or type command. `simctl ui` only toggles appearance, contrast and text size.
- Real injection: HID events via SimulatorKit (what AXe and idb use), tested here for tap only. Text goes in as key events, so `type` needs a keycode map; non-ASCII needs the pasteboard (`simctl pbcopy` then paste) as a fallback.
- Targeting: AXe can tap by accessibility id or label from `describe-ui`. The accessibility tree is the sim equivalent of `berth browser snapshot`, and it is what makes an agent reliable. Coordinates are in points.

## Performance and cost

- A booted simulator is a handful of processes and several processes and real memory (not measured here), and the first boot of a device took 35 s here. Berth should boot lazily and never auto-boot.
- Frame cost for B or C at 30 fps and 0.5 scale is small next to Review and the terminal, but it must stop when the pane is hidden. The Terminal surface rule (keep mounted, docs/adr/0002) does not apply: nothing in the simulator pane owns a shell.
- Agents on several worktrees will contend for one booted device unless each session gets its own (see Unknowns).

## Distribution and notarization

- Berth is Developer ID signed and notarized, not sandboxed, so loading Xcode's private frameworks at runtime and spawning `xcrun simctl` is permitted. Hardened runtime library validation applies only to frameworks loaded in Berth's process; it would block B unless the `disable-library-validation` entitlement is added (it is not in Berth.entitlements today). Option C avoids that by keeping the load in the helper.
- A helper that Berth does not bundle needs no notarization of its own. Bundling one means signing and notarizing it with Berth and tracking its licence.
- Requires Xcode installed; Command Line Tools alone have no simulators. Berth should detect `xcrun simctl` and hide the pane otherwise.

## Recommendation

Ship in two steps, public tooling first, private only behind a helper.

1. Phase 1 is Option A plus `simctl`: no private API, no dependency beyond Xcode. The pane shows the last screenshot and refreshes after every agent command, with a device picker and Boot and Shut Down. This already answers "boot a simulator, see it beside the session, screenshot it".
2. Phase 2 adds input and a live view through Option C with AXe (or idb) as an optional, user-installed helper, kept as one long-lived process per booted device. Do not link CoreSimulator or SimulatorKit into Berth (Option B) unless C proves too slow, because it needs the library validation entitlement and breaks per Xcode.

Reject D and E.

## berth sim commands

Same shape as `berth browser`: CLI, control socket, `ControlService`, a per-session approval prompt before the first command (reuse `BrowserAccess` with a sim key, or a sibling), and results as plain text or `--json`.

- `berth sim devices [--json]` lists devices with udid, name, runtime and state. A leading `*` marks the session's device.
- `berth sim boot [<name|udid>] [--json]` boots (creating a Berth-owned device if none named), waits for boot, and shows the pane. Only devices Berth created or the user picked in the pane are bootable by an agent.
- `berth sim shutdown` and `berth sim delete` act only on the session's own device, never "all".
- `berth sim screenshot [--out <path>] [--json]` writes a PNG and prints the path, like browser screenshot.
- `berth sim install <app>` and `berth sim launch <bundle-id> [-- args]` wrap `simctl install` and `launch`; `berth sim openurl <url>` and `berth sim appearance light|dark` wrap theirs.
- `berth sim snapshot [--json]` prints the accessibility outline (phase 2), the counterpart of `berth browser snapshot`.
- `berth sim tap (<x> <y> | --label <text> | --id <id>)`, `berth sim type <text>`, `berth sim swipe` and `berth sim button home|lock` (phase 2).
- `berth sim log [--since <n>] [--follow]` wraps `simctl spawn log stream` filtered to the app (optional).

## Phased plan

1. Pane shell: Simulator mode in the mode switcher (hidden when `xcrun simctl` is missing), device list, boot and shut down, screenshot view. Setting to gate it, off by default like the other opt-in features. Snapshot flag with a stubbed `simctl` so offscreen runs never boot anything.
2. `berth sim` read and lifecycle commands (devices, boot, shutdown, screenshot, install, launch, openurl, appearance) and the approval prompt.
3. Input and live view through a helper (snapshot, tap, type, swipe, button; MJPEG into the pane at a capped fps that stops when the pane is hidden).
4. Per-session device ownership, cleanup on quit (shut down only devices Berth booted, same rule as child processes in app-lifecycle.md), log streaming.

## Unknowns

- Boot and frame cost on the user's usual machines: one measurement set here, no sustained fps test for the MJPEG path, no memory figure.
- Whether a long-lived AXe or idb session removes the 12 to 14 s first-call setup, and how it behaves when a user also has Simulator.app open on the same device.
- Whether the helper's output should be bundled (licence, notarization) or stay user-installed; AXe's licence and idb's maintenance status were not checked.
- Device ownership policy: one device per Claude session, or one shared. Parallel worktrees building different apps would fight over a shared one.
- Text input beyond ASCII, hardware keyboard routing and gestures (pinch, multi-touch) were not tried.
- Whether the user wants the pane to take pointer input directly (draw a tap where the user clicks) or only mirror what the agent does. Direct input needs phase 3 and a hit-test mapping from pane points to device points.
