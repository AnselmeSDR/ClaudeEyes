<p align="center">
  <img src="docs/icon.png" width="128" alt="Claude Eyes icon">
</p>

<h1 align="center">Claude Eyes</h1>

<p align="center">
  macOS robot eyes reacting to every Claude Code session.<br>
  <b>English</b> · <a href="README.fr.md">Français</a>
</p>

---

When you run several Claude Code sessions at once, it is hard to tell which one is thinking, which one is done and which one is waiting for you. Claude Eyes gives each session its own little robot, randomly built, with robot eyes in the spirit of Cozmo, Vector or Emo: they focus while Claude writes code, look around while it reads, get nervous during tests, smile when the turn is over and turn orange when a session needs you.

![Expressions](docs/expressions.png)

## Features

- **Robots**: one robot per session, generated from a seed: tracks, wheels, legs, springs or hovering, head shape, antennas, ears, arms, colors... no two alike. They stroll at the bottom of every screen, get on top of the windows that have room above them (driving up the side, flying, bouncing off it, hand over hand or with a grappling hook, depending on their parts) and walk on them, move from one screen to another, and fall asleep when their session does. They meet too: they say hello, visit each other, play tag, cheer along when a session finishes, and find a sleeping robot asleep. While Claude works, its robot holds the tool in use (a magnifier to read, a keyboard to write code, a wrench for a command, a smoking test tube for the tests), throws confetti when the tests pass and gives off sparks on an error; each subagent runs around it as a small copy of it. Sessions in the same repository carry the same pennant (one color and the initial of the repository), stick together, follow each other in a line and high-five when they meet. Robots sit on the edge of windows with their legs dangling, follow your pointer with their eyes, like being petted (move the pointer gently over them), get dizzy when you shake them, and dress for the season (pumpkin, Santa hat, beanie) with a headlamp at night. When a session waits for you, its robot knocks on its terminal's window when it is on your screen, otherwise it comes to your pointer and jumps around. Click a robot to jump to its terminal, drag it to put it elsewhere (it falls where you drop it), right-click it for its menu (sound, a new robot). Hover it to see its session and what Claude is doing; this bubble also shows for a few seconds when the session changes state.
- **Dock**: either one animated icon showing the session that matters most (badge = sessions waiting for you), or **one Dock icon per session**, named after the session.
- **Menu bar**: a static icon listing every session, showing or calling back the robots, the robot lab (random robots going through every motion: pick a step, a mood or an eye color, pick them up, throw, shake, pet or click them) and the settings.
- **Your names and colors**: the title set with `/rename` and the color set with `/color` in Claude Code are picked up automatically. Calm moods use the session color, alerts keep theirs (orange waiting, red error, green done) and pulse so you never miss them.
- **Sounds**: a short robot chirp when a session starts waiting for you or finishes its turn (a sad one on an error). Mute every sound or any single session from the menu bar, a right-click on its robot or its Dock icon.
- **Every session found**: sessions are reported by a Claude Code hook; running sessions that have not triggered any hook yet are found in the process table and shown asleep.
- **Works with your terminal**: clicking a robot brings back the exact tab of that session in Ghostty, Terminal, iTerm2 and WezTerm, and brings any other terminal app to the front. In Ghostty and iTerm2, the tab's progress bar follows Claude's state: it no longer disappears during long thinking, and stays orange as long as a session waits for your answer.
- **Light**: robots and faces drawn by the GPU, walks run by the render server, window positions read only while a robot stands on a window: about 2 to 3% CPU for the app with three robots, and 0.5 to 2% per Dock icon.

![Session colors](docs/colors.png)

![Robots](docs/robots.png)

*A few robots out of the generator.*

*Calm moods take the `/color` of the session; the last row is a session waiting for you: it stays orange and pulses.*

## How it works

```
Claude Code ── hook event ──▶ hooks/claude-state.sh ──▶ ~/.claude/eyes/sessions/<session>.json ──▶ Claude Eyes.app
                                       │
                                       └──▶ tab progress bar in Ghostty and iTerm2 (OSC 9;4)
```

Claude Code runs the hook on every event (prompt sent, tool started or finished, permission asked, turn ended…). The hook writes the state of the session to a small JSON file, and the app watches that folder. It turns the state, the tool in use and what the tool output revealed (failed tests, errors, large edits) into an expression. Claude Code's own live status tells when a dialog waits for you and when you answered it, even while subagents keep working.

| Expression | When |
|---|---|
| Neutral | Session open, nothing going on |
| Attentive | You just sent a message |
| Thinking | No event for a few seconds |
| Curious | Reading files, searching the code or the web |
| Focused | Writing code, running a command or an agent |
| Nervous | Running tests, linters or type checks |
| Surprised | Just wrote a large edit |
| Happy | Turn finished, or tests passed |
| Waiting for you | Permission prompt, question or plan to validate |
| Sad | A tool failed, or tests are red |
| Annoyed | Auto mode denied an action |
| Failed | The turn ended on an API error |
| Tired | Compacting the conversation |
| Asleep | No activity for a while |

## Requirements

- macOS 14 or later, Apple Silicon
- [`jq`](https://jqlang.org) (`brew install jq`), used by the hook
- Claude Code 2.1 or later
- Any terminal; see [Terminal support](#terminal-support) for what each one adds
- To build from source: Xcode or the Command Line Tools (`swiftc`, `iconutil`, `codesign`)

## Install

### From a release

1. Download `ClaudeEyes-<version>.zip` from the [latest release](https://github.com/AnselmeSDR/ClaudeEyes/releases/latest), unzip it and move **Claude Eyes** to your Applications folder.
2. Open it. The app is not notarized, so macOS blocks its first launch: click **Open Anyway** in **System Settings → Privacy & Security** (or run `xattr -dr com.apple.quarantine "/Applications/Claude Eyes.app"` once).
3. The app offers to install its Claude Code hook: it copies it to `~/.claude/hooks/claude-state.sh` and registers it in `~/.claude/settings.json`. **Settings → Claude Code** does it too.

Updates: once a day the app looks for a newer release on GitHub and offers it (menu bar, Dock menu or **Settings → Mises à jour**, where the daily check can be turned off; it is the app's only network access). It downloads the zip, checks its SHA-256 and signature, replaces itself and relaunches; the hook is updated with it.

### From source

```bash
git clone https://github.com/AnselmeSDR/ClaudeEyes.git
cd ClaudeEyes
./build.sh --install     # builds "Claude Eyes.app", copies it to ~/Applications and launches it
hooks/install.sh         # links the hook and registers it in ~/.claude/settings.json
```

Update with `git pull` and `./build.sh --install`: the app leaves a linked hook alone.

### The hook

Both ways back up your settings to `~/.claude/settings.json.bak-claude-eyes`, register the hook on every event it handles and turn off Claude Code's own terminal progress bar (`terminalProgressBarEnabled: false`), which the hook replaces in Ghostty and iTerm2. Turning the hook's bar off in the settings gives Claude Code its own bar back. Sessions started before the hook was installed only show up once restarted.

Running sessions show up right away; they wake up at their next event. The first click on a face asks for permission to control your terminal app.

To start the app at login, open **Settings** from the menu bar icon and enable **Lancer à l'ouverture de session**.

## Terminal support

| Terminal | Click on a face | Tab progress bar |
|---|---|---|
| [Ghostty](https://ghostty.org) | Exact tab or split | Yes, 1.2 or later |
| iTerm2 | Exact tab | Yes, 3.6.6 or later |
| Terminal | Exact tab | No |
| WezTerm | Exact pane | No |
| VS Code, Cursor, Warp, kitty, others | The app comes to the front | No |

The terminal of each session is detected automatically, from its process tree; sessions inside tmux bring back the terminal app they were started from. The progress bar is only sent to the terminals where Claude Code itself enables it: elsewhere the same escape sequence can show up as a notification. Turn it off in **Settings → Terminal** and Claude Code's own bar comes back; in Ghostty, `progress-style = false` hides every progress bar, whatever the app.

## Settings

Open them from the menu bar icon (**Réglages…**):

- **Robots**: show or hide, climbing windows on or off, hide when no session, call them back to the current screen, the robot lab.
- **Dock**: animated icon on or off, one icon for the most important session or one icon per session.
- **Behavior**: how long the happy face stays after a turn, after how long a session falls asleep.
- **Sounds**: when a session waits for you, when it is done, when it stops on an error, volume.
- **Claude Code**: whether the hook is installed and up to date, install or reinstall it.
- **Terminal**: the terminals detected for your sessions, tab progress bar on or off.
- **System**: launch at login.
- **Updates**: installed version, daily check on or off, check now.
- **Expressions**: a live gallery of every expression and what triggers it.

## Files

| Path | Content |
|---|---|
| `~/.claude/eyes/sessions/` | One JSON file per session, written by the hook |
| `~/.claude/sessions/<pid>.json` | Claude Code's own registry, read for `/rename` titles and to know when a session waits for you |
| `~/.claude/projects/…/<session>.jsonl` | Transcripts, read incrementally for `/color` |
| `~/Library/Application Support/Claude Eyes/Docks/` | Copies of the app used for per-session Dock icons |
| `com.anselme.claude-eyes` | Preferences (`defaults read com.anselme.claude-eyes`) |

## Development

```bash
./build.sh                                   # build into build/
./build.sh --install                         # build, install and relaunch
./build.sh --zip                             # also pack build/ClaudeEyes-<version>.zip and its .sha256 (release assets, built by GitHub Actions on a version tag)
"build/Claude Eyes.app/Contents/MacOS/ClaudeEyes" --render-gallery build/gallery.png      # every expression
"build/Claude Eyes.app/Contents/MacOS/ClaudeEyes" --render-color-tiles build/colors.png   # every /color
"build/Claude Eyes.app/Contents/MacOS/ClaudeEyes" --render-sounds build/sounds           # every sound, as WAV
"build/Claude Eyes.app/Contents/MacOS/ClaudeEyes" --render-robots build/robots.png         # 30 random robots
"build/Claude Eyes.app/Contents/MacOS/ClaudeEyes" --robot-lab [grimpe]                    # animated robots, alone (optional first step)
```

Plain Swift compiled with `swiftc` (AppKit, SwiftUI, Core Animation), no Xcode project. See [CLAUDE.md](CLAUDE.md) for the architecture.

## Uninstall

```bash
pkill -x ClaudeEyes
rm -rf ~/Applications/"Claude Eyes.app" /Applications/"Claude Eyes.app" ~/Library/Application\ Support/Claude\ Eyes ~/.claude/eyes
rm ~/.claude/hooks/claude-state.sh
defaults delete com.anselme.claude-eyes
```

Then remove the `claude-state.sh` entries from the `hooks` section of `~/.claude/settings.json` (or restore `settings.json.bak-claude-eyes`) and the `terminalProgressBarEnabled` line if you want Claude Code's progress bar again (turning the bar off in the settings before uninstalling does it for you).

## License

[AGPL-3.0](LICENSE) © 2026 Anselme SDR — free to use, modify and share; any modified version that is distributed or offered as an online service must remain open source under the same license. A commercial license is available for closed-source use: anselme8@icloud.com.

Claude Eyes is an independent project, not affiliated with, endorsed or sponsored by Anthropic, Digital Dream Labs or Living AI. Claude and Claude Code are trademarks of Anthropic; Cozmo and Vector of Digital Dream Labs; Emo of Living AI.
