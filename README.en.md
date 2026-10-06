# tuidock

[한국어](README.md)

Wraps a terminal TUI program as a macOS Dock app — like Fluid did for web pages: drop a binary, pick an emoji icon, get a `.app`.

The window lives in the terminal you pick (Terminal, iTerm2, Ghostty or the built-in terminal); the app makes that window behave like a standalone app:

- Its own Dock icon, running dot and Cmd+Tab entry. Clicking the Dock icon or picking it with Cmd+Tab brings the window to the front. When the program exits, the app quits too.
- Window size (in character cells) and font size are remembered and reused next time. The first time, the window nearly fills the screen.
- `Cmd+H` hides only that window (other terminal windows stay). `Cmd+W` hides it too (closing a window hides it, like other apps; iTerm2 minimizes). `Cmd+Q` quits just that app (the terminal stays; the leftover empty window is closed). Terminal shortcuts (`Cmd+T` new tab, `Cmd+N` new window …) are blocked in that window, except the standard copy and paste (`Cmd+C`, `Cmd+V`). A [connected](#connecting-your-program) program receives Cmd shortcuts itself.
- If the program speaks the [protocol](#connecting-your-program), Cmd shortcuts (`Cmd+Q`, `Cmd+V`, `Cmd+F` …) go to the program instead of the terminal while its window is focused — even with a composing input method (Korean, etc.) active.

Per tool it costs a Terminal window (~9-14MB) plus the launcher (~14MB), on top of Terminal.app itself (~115MB). Ghostty can't hide a single window, so each app runs its own Ghostty, costing about 70-100MB more per app.

With the [built-in terminal](#built-in-terminal) the app draws its own window and no terminal app runs. Table and border lines stay joined at any line height.

## Install

Open [TUIDock.dmg](https://github.com/zidell/tuidock/releases/latest/download/TUIDock.dmg) and drag TUIDock to Applications. Or from the terminal (also installs the `tuidock` command; run again to update):

```sh
curl -fsSL https://zidell.github.io/tuidock/install.sh | bash
```

Installed from the DMG and want the `tuidock` command too? `ln -sf /Applications/TUIDock.app/Contents/Resources/tuidock ~/.local/bin/tuidock`.

macOS 14+, Apple Silicon & Intel. Home page: https://zidell.github.io/tuidock/

## Make an app

The TUIDock window has an icon, a dashed drop box and, below them, the terminal to run in.

- Click the icon to pick an emoji in the macOS emoji picker; the emoji itself becomes the icon, with no backdrop. Without one, the name's first letter is used (right-click for its background color).
- To use an image instead, drop it onto the icon (PNG, JPG …; non-square images get transparent padding).
- Drop an executable onto the box (or click it to choose) and the app is made right away, named after the file with its first letter capitalized (`htop` → `Htop`). Changing the icon afterwards remakes it.
- Pick the built-in terminal or an installed one (Terminal, iTerm2, Ghostty); the built-in one is the default. Changing it remakes the app.

The app goes into `/Applications` (or `~/Applications` if that isn't writable) and is pinned to the Dock. With Terminal or iTerm2, allow "control Terminal" (or iTerm) on first launch (the built-in terminal and Ghostty don't ask). The executable isn't copied — the app runs it from its path — so rebuilding your program needs no new app. If you move or delete the file, make the app again.

To build and install from source (needs the Xcode command line tools):

```sh
git clone https://github.com/zidell/tuidock.git
cd tuidock && scripts/build-app.sh --install
```

This also links the `tuidock` command into `~/.local/bin`.

### Quick make from the command line

```sh
tuidock htop 😁                  # a command name on PATH
tuidock ~/Sites/foo/bin/foo 🦊   # a path
tuidock foo                      # no emoji: picks one at random
```

Like the GUI, it installs into `/Applications` (or `~/Applications` if not writable) and pins to the Dock (`--no-dock` to skip). The name is the file name with its first letter capitalized (override with `--name`).

- The executable is not copied; the app runs it from its path. Rebuilding the program doesn't require remaking the app.
- An app with the same name is overwritten. Without an emoji, the existing icon is kept. Identical content gives an identical signature, so no new permission prompt — safe to call from another program's build script.
- Shell aliases and functions don't work (the command can't see them). Use a file on PATH or a path.
- `--terminal builtin|terminal|iterm2|ghostty` picks the terminal (default builtin). Without it, an existing app's choice is kept, and so are the built-in terminal's `--font`, `--font-size` and `--line-height`.
- `--color`, `--icon`, `--arg` and `--id` work as in `make`.

### From the command line (for build scripts)

```sh
tuidock make --name "Calendar TUI" --embed ./calendar --icon icon.png --out dist
tuidock install "dist/Calendar TUI.app"     # copy to /Applications and pin to the Dock
```

| Option | |
|---|---|
| `--name` | App name (required) |
| `--embed FILE` | Put the executable inside the app |
| `--command PATH` | Executable outside the app, used first if present. Handy while developing: swap the binary without re-signing the app (no new permission prompt). `~` allowed |
| `--arg ARG` | Program argument (repeatable) |
| `--emoji EMOJI`, `--color '#RRGGBB'` | Emoji icon (as is, no backdrop). Default: the name's first letter, on the `--color` background |
| `--icon IMAGE` | Image icon: PNG, JPG or ICNS. Non-square images get transparent padding |
| `--terminal NAME` | Terminal to run in: `builtin` (built-in terminal, default), `terminal`, `iterm2`, `ghostty` |
| `--font NAME` · `--font-size PT` · `--line-height X` | Built-in terminal only: font (PostScript name, e.g. `Menlo-Regular`; default D2Coding), size (default 13), line height (1-3 times the font's, default 1.3) |
| `--id BUNDLE_ID` | Default `local.tuidock.<name>`. Window size memory is keyed by it |
| `--version`, `--resource FILE`, `--out DIR`, `--universal` | Version, extra file to bundle, output folder, Apple Silicon + Intel launcher |

The command builds the launcher with the Xcode command line tools (`swiftc`, `clang`) as it goes (`launcher/build.sh`; the command inside the GUI app uses its prebuilt launcher).

## Built-in terminal

With `--terminal builtin` ("Built-in" in the GUI) the app owns its window and runs your program in it (libvterm).

- No Terminal.app or iTerm2 is started, and no control permission is asked.
- Box-drawing characters (`│ ─ ┼ ╭ █` …) are drawn as shapes filling the cell instead of font glyphs, so lines stay joined at line height 1.5 (in Terminal.app they break into dashes).
- The window, menu bar and Cmd shortcuts are the app's own: `Cmd+C`/`Cmd+V` copy and paste (drag to select), `Cmd +`/`Cmd -`/`Cmd 0` change the font size, `Cmd+W` and the close button hide the window, `Cmd+Q` quits. A [connected](#connecting-your-program) program gets the same Cmd shortcuts as with a terminal.
- The program starts through your login shell (same PATH as a Terminal window). If it ends with an error, the message stays in the window until you press a key.
- The default font is [D2Coding](https://github.com/naver/d2codingfont) (NAVER, SIL Open Font License 1.1, `Resources/fonts/OFL.txt` in the app), bundled in the app. Only that app uses it; nothing is installed system-wide.
- Colors: the default text and background follow light/dark mode, and the 16 colors match Terminal.app's "Basic". By default the program's colors are drawn as they are; raising "Contrast" in the settings makes text brighter (dark mode), lowering it fades it.
- Settings: `Cmd+,` opens a settings window (font, size, line height, appearance, contrast). Sliders update the window behind while you drag; changes apply at once and are saved to `~/Library/Application Support/<bundle ID>/config.toml`; "Open File…" opens that file in your text editor, and saving it applies at once too. Each key has its meaning, type, default and range in a comment right above it. `font_family` (empty: D2Coding), `font_size`, `line_height` (multiple of the font's line height, default 1.3), `theme` (`auto` follows the system, `dark`, `light`), `contrast` (-100 to 100%, default 0 leaves the program's colors as they are). When the program asks for the background color (OSC 11) it gets this appearance's color, so TUIs that pick dark or light colors that way match (programs that turn on dark/light notifications, mode 2031, follow a change at once; others need a restart to update their own colors). `Cmd +`/`Cmd -` also change `font_size` in this file. Missing or invalid values come from `--font`, `--font-size`, `--line-height` given when making the app, then the defaults.
- For agents and scripts (following [agent-discoverable-config](https://github.com/zidell/agent-discoverable-config)): `Contents/Resources/readme.txt` in the app explains where and how, and the executable `Contents/MacOS/launcher` takes `--help`, `--config-path` (the settings file's path), `--print-default-config` (defaults with explanations), `--init-config` (creates it if missing, never overwrites) and `--check-config` (bad lines and allowed values, exit code 1 if any). None of them opens a window.
- Memory (measured 2026-10-06): 48MB per app for a 160×45 window at line height 1.5, 25MB of it the window's backing buffer, which scales with the window size. A Terminal window of the same size costs 14MB (line height 1) but needs Terminal.app itself (~115MB) running.
- No scrollback, tabs or splits (it's a window for one TUI). The wheel sends up/down arrows on a TUI screen.

## Connecting your program

Without it you still get the Dock, Cmd+H, Cmd+W, Cmd+Q and window size memory. With it, your program receives Cmd shortcuts.

The launcher starts the program with `TUIDOCK` set to a socket folder holding two Unix datagram sockets. Messages are one line of text.

| Direction | Socket | Messages |
|---|---|---|
| launcher → program | `app.sock` (the program binds it) | `key cmd+a`, `key cmd+shift+=`, `key cmd+left`; `ping` (answer with `hello`); `ok` (answer to `bye`) |
| program → launcher | `launcher.sock` | `hello <pid>` (at start), `focus 1`/`focus 0` (on every terminal focus event), `hide`, `font +1`/`font -1`, `bye` (just before exiting) |

- Key names use the unshifted character: `cmd+shift+/` is `Cmd+?`. Arrows are `left` `right` `up` `down`; also `enter`, `backspace`.
- Not forwarded: `Cmd+H`/`Cmd+W` (the launcher hides the window), `Cmd+M` (minimize), `` Cmd+` `` (cycle windows), screenshots (`Cmd+Shift+3…6`), log out (`Cmd+Shift+Q`). System shortcuts like `Cmd+Tab` and `Cmd+Space` can't be intercepted anyway.
- Keys arrive only between `focus 1` and `focus 0`. Get focus events from terminal focus reporting (`ESC[?1004h`).
- `Cmd+Q` (quit) and `Cmd+V` (paste) come to the program too; handle them.

### Go

```go
import "github.com/zidell/tuidock"

p := tea.NewProgram(m, tea.WithReportFocus())
dock := tuidock.Open(func(key string) { p.Send(cmdKeyMsg{key}) })

// in Update
case tea.FocusMsg: dock.Focus(true)
case tea.BlurMsg:  dock.Focus(false)
case cmdKeyMsg:    // "cmd+q" → quit, "cmd+v" → tuidock.Paste() …

// when exiting (while the window still exists)
dock.Close()
```

Run directly from a terminal, `Open` returns nil and the nil methods do nothing.

## Limits

- Terminal.app, iTerm2, Ghostty and the built-in terminal only.
- iTerm2 can't hide a single window, so `Cmd+W`/`Cmd+H` minimize it. Font size isn't remembered.
- Ghostty runs once per app: about 70-100MB more memory each, and a Ghostty entry per app in the Dock and Cmd+Tab. Font size isn't remembered.
- The menu bar is the terminal's (except the built-in terminal); choosing a menu item with the mouse runs the terminal's command.
- Remaking an app with a different icon or program path changes its signature, so macOS may ask for permissions again (controlling Terminal, or for the built-in terminal whatever the program uses, such as Calendars).

## License

GPLv3 (`LICENSE`). Only the Go binding `tuidock.go` is MIT (`LICENSE.MIT`), so programs under any license can import it. The launcher runs the program as a separate process, so wrapping a program with tuidock doesn't affect that program's license.
