# App lifecycle: alerts, updates and process hygiene

Moved from CLAUDE.md. Release steps are in docs/RELEASING.md.

## Child processes

Child processes survive the app exiting (claude ignores the pty hangup), so `applicationWillTerminate` sends SIGHUP then SIGTERM to every descendant, waits up to 1 s and SIGKILLs survivors (Claude sessions resumed at launch once outlived a quit as orphans). Closing a tab does the same for its own tree: libghostty-spm's `foregroundPid`/`ttyName` are stubs and `login` (root) argv is unreadable, so `Store.close` snapshots Berth's descendants (pid + start time) before removing the tab and, 1 s later, hangs up those that are still alive but no longer descend from Berth (the closed tab's orphans).

## AutoFill heuristic controller

`BerthApp.init` registers `NSAutoFillHeuristicControllerEnabled = false`. On macOS 26 the controller's `_showPasswordAutoFillIfNecessaryForView:` walks `previousValidKeyView`, and SwiftUI's `FocusNavigationSequence.next()` looped forever in the Browser address field (214 s hang after ⌘T; Chromium and Electron disable it for the same reason). WKWebView's own AutoFill and password managers are unaffected.

## Needs-you alerts

Needs-you alerts (`NeedsYouAlerts`, run from `Store.refreshLive`): the Dock badge counts live `waiting` sessions open in a Berth tab (`NeedsYou.update(inBerth:)`); a notification fires only when such a session enters `waiting` (identifier = session id), not on the first scan after launch, and not when Berth is active with that session's tab selected, or when Settings > General turns `notifiesWhenSessionNeedsYou` off (default on). Authorization is requested on the first post. `AppDelegate` is the notification centre delegate: foreground banners are allowed, and a click activates Berth and runs `Store.activate(.session)` after the first scan (opens or selects the tab; a session locked elsewhere scrolls to its row and shows the notice).

## Updates

Updates: `AppUpdater` (tape's, owned by `Store`) checks GitHub releases of `gustaferiksson/berth` for `Berth-<version>.zip`; Berth ▸ Check for Updates… is `AppAction.checkForUpdates`, status and install live in Settings > About. A downloaded update installs when Berth is idle (`Store.isIdle`: no Claude tab working, no key for 30 s, no terminal running a command; checked every 2 s) after a 15 s `RestartBanner` countdown (Not Now postpones), or on quit (`installOnQuit`). Installing by hand while sessions work asks first.

`Store.isIdle` requires every Claude tab's live session to be plain `idle` (`Store.busySessionCount`: busy, waiting and shell count, so background shells hold the restart; background agents and Monitors don't yet), and the Install and Relaunch warning counts the same sessions. The swap helper starts through a backgrounded `/bin/sh -c '… &'`, so it is orphaned to launchd and `applicationWillTerminate`'s descendant hang-up never reaches it. Once Berth has quit, every failure reopens the installed app (`open` or `open -g`; not after a quit-to-install), or the moved-aside copy if restoring failed, and records the reason in `updateSwapFailure`; the next launch shows it in Settings > About, skips the launch check and installs only on quit.

Releasing: `docs/RELEASING.md`, `SHIPPING.md`.
