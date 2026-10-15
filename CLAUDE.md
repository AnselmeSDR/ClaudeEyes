# Claude Eyes

macOS app (Swift, AppKit + SwiftUI, no Xcode project) showing robot eyes that react to the state of every running Claude Code session: a transparent floating panel (one face per session), an animated Dock icon (most important session + badge for sessions waiting for input) and a static menu bar icon (session list, settings).

## Data flow

```
Claude Code hook events ─▶ ~/.claude/hooks/claude-state.sh ─▶ ~/.claude/eyes/sessions/<session_id>.json ◀─ app watches the folder
```

- The hook source is `hooks/claude-state.sh`; `hooks/install.sh` symlinks `~/.claude/hooks/claude-state.sh` to it and registers it on 14 events in `~/.claude/settings.json` (idempotent, backup `settings.json.bak-claude-eyes`, sets `terminalProgressBarEnabled: false`). The hook also drives Ghostty's tab progress bar (OSC 9;4) with a keepalive loop (Ghostty hides the bar after 15s without update). The loop stops 4s after `done` or after 30 min without event, never while `waiting` (the orange bar stays until the user answers).
- JSON fields: `sessionId, cwd, pid, tty, state, event, tool, command, signal, terminalApp, at, stateSince`.
  - `state`: `idle | working | toolError | waiting | done | failed` (file removed on `SessionEnd`).
  - `signal`: what a `PostToolUse` revealed: `testsFailed | testsPassed` (summary lines of PHPUnit, Pest, Jest, Vitest, pytest, RSpec, Mocha, go test, cargo test, swift test), `errorOutput` (well-known error formats: Python traceback, `fatal:`, compiler errors, JS/PHP errors, panics, `command not found`, npm), `bigEdit` (Write > 150 lines, Edit > 60 lines). Only the last 8000 characters of a command's output are searched; jq anchors `^`/`$` to the whole text, hence the `(?m)` prefix.
- The app drops sessions whose `pid` is dead.

## Sources

- `Face.swift`: `Mood` (14 expressions, colors, labels), `EyeParams`/`FaceParams`, `FaceAnimator` (easing, blinks, gaze styles, bounces), `FaceRenderer.eyesPath` (single geometry source, lids carved with `CGPath.subtracting`), `FaceLayer` (GPU rendering, glow = CA shadow), app/menu icons, offscreen `Snapshot`.
- Performance: never draw the glow with a CPU shadow at 30 fps (it cost ~35% CPU). Panel and settings previews use `FaceLayer`; the Dock tile is CPU-drawn but skips frames where `FaceFrame.isClose(to:)` (~5% CPU total).
- `Sessions.swift`: `SessionRecord` (JSON), `Session` (mood/priority/French status text derived from state + event + tool + elapsed time), `SessionStore`.
- Live status: Claude Code writes `status` (`busy | idle | waiting`), `waitingFor` and `statusUpdatedAt` (ms) to its registry `~/.claude/sessions/<pid>.json` whenever its UI changes. `Session.state` (and the hook's `resolveState`) correct the hook state with it: a dialog waiting for the user wins over hook events from subagents or parallel tools, and a `waiting` hook state followed by a later `busy`/`idle` means the user answered (no hook fires then). `waitingFor: "dialog open"` is a dialog the user opened (`/config`…), not Claude waiting.
- `FloatingPanel.swift`: borderless non-activating `NSPanel` anchored bottom-right, `CrewView` draws faces at 30 fps, click focuses terminal, drag moves. Optional backdrop: `NSVisualEffectView` (dark `.hudWindow`, always full blur) + black veil whose opacity is the user setting. Panel size is rounded to whole points, otherwise the layout loop re-anchors the panel every tick and breaks dragging.
- `DockAndMenus.swift`: `DockTileController` (one face per Dock icon, 10 fps, skips still frames, badge), shared menu builder (menu bar + Dock), `StatusMenuController`.
- `DockPerSession.swift`: "one Dock icon per session" mode. A Dock icon = one process, so `DockHelperManager` launches the same binary once per session (`--dock-session <id> --parent <pid>`) from a per-session bundle copy in `~/Library/Application Support/Claude Eyes/Docks/<title>.app` (own `CFBundleName` so the Dock shows the session title, re-signed ad hoc, rebuilt when the main binary is newer, folder wiped at launch). Helpers (`SessionDockDelegate`) quit when their session or the main app disappears, and ask the main app to focus the terminal through a distributed notification (so only the main app needs the Ghostty Automation permission). Helpers read the main app's defaults through `UserDefaults(suiteName:)`. In this mode the main app has no Dock icon (menu bar only).
- `SessionLook.swift`: session title (`/rename`) and color (`/color`). Title from Claude Code's live registry `~/.claude/sessions/<pid>.json` (`name` when `nameSource != "derived"`), else the transcript's last `custom-title` entry. Color from the transcript's last `agent-color` entry (`TranscriptScan` reads only appended bytes after the first pass). `SessionColor` holds Claude Code's palette; calm moods draw the eyes in its light variant (`eyeComponents`), alert moods (`Mood.isAlert`: waiting, sad, annoyed, failed, happy) keep their own color and pulse towards white when the session has a color, so an orange session waiting for input stays recognizable. Tiles and panel stay dark. Per-session Dock helpers are named after the title and relaunched on rename.
- `SessionStore` watches the sessions directory (DispatchSource, the hook writes temp file + rename), each live registry file (Claude Code rewrites them in place, invisible to a directory watcher) plus a 2s timer for dead pids and the process scan; Dock helpers track only their own pid (`start(trackingPid:)`).
- `TerminalFocus.swift`: click on a session = bring back its terminal. Host app = closest regular-app ancestor of the claude pid (parent pids through `sysctl`, `proc_pidinfo` fails on root-owned `login`), else the hook's `terminalApp` (`__CFBundleIdentifier`, covers tmux). Terminal and iTerm2: AppleScript matching the tab/session `tty`; WezTerm: `wezterm cli list` + `activate-pane`; Ghostty: `GhosttyFocus`; anything else: activate the app.
- `Ghostty.swift`: `GhosttyFocus`, through Ghostty's AppleScript API (JXA via `osascript`); Ghostty doesn't expose ttys, so the terminal is identified by temporarily setting a unique title on the session's tty, then restoring it.
- Hook progress bar: only `TERM_PROGRAM` ghostty ≥ 1.2.0 and iTerm.app ≥ 3.6.6, the same rule as Claude Code's own bar (elsewhere OSC 9 may be shown as a notification). Setting "Barre de progression" off = the app creates `~/.claude/eyes/progress-disabled`; the hook then sends nothing and running keepalive loops clear the bar and exit. The keepalive loop forks nothing per second: registry read with `read -d ''` + `[[ =~ ]]`, clock from `SECONDS`, one-second wait = `read -t 1` on a FIFO nobody writes to (fd 9), so the bar turns orange or back as soon as a dialog opens or is answered.
- `Sounds.swift`: robot chirps (`Chirp`: waiting, done, failed) synthesized as WAV at runtime, played by the main app on state transitions (not during the first 3s, at most one per session every 2s, the most urgent when several sessions change). Per-session mute = `mutedSessions` in the shared defaults (ids `pid-<pid>`, pruned at launch), toggled from the menu bar, a face's right-click menu or a session's Dock menu.
- `Settings.swift`: `Prefs` (UserDefaults), SwiftUI settings window with a live expressions gallery, launch at login (`SMAppService`).
- `main.swift`: `AppDelegate`, helper mode `--dock-session`, CLI modes `--render-iconset <dir>`, `--render-gallery <file.png>`, `--render-color-tiles <file.png>`, `--render-sounds <dir>`.
- `docs/`: README images rendered with the CLI modes (`expressions.png`, `colors.png`, `icon.png`). README in English (`README.md`) and French (`README.fr.md`): keep both in sync.
- `CHANGELOG.md`: one short entry per change set under `Unreleased`.

## Build

```bash
./build.sh            # build/Claude Eyes.app
./build.sh --install  # copy to ~/Applications and relaunch
"build/Claude Eyes.app/Contents/MacOS/ClaudeEyes" --render-gallery build/gallery.png  # check expressions visually
```

Compiled with `swiftc -swift-version 5` (Swift 6 strict concurrency not enabled), target macOS 14, arm64, ad-hoc signed.

## Repositories

- GitLab (main): https://gitlab.com/AnselmeSDR/ClaudeEyes
- GitHub (mirror): https://github.com/AnselmeSDR/ClaudeEyes

GitHub is public (MIT, `LICENSE`), GitLab stays private. `origin` has two push URLs: a single `git push` sends to both. Git identity is set locally: `Anselme SDR <anselme8@icloud.com>`.
