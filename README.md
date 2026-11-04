# Sightline

![Sightline](Resources/Design/banner.png)

**A clear line of sight into every repo your AI agents touch.**

Sightline is a small, native macOS app for *reviewing* code changes across a workspace made of many git
repos. Point it at a root folder and it finds every nested repo, shows what changed in each one,
lets you read the diffs, stage and commit, jump to any file in any repo, and gives every repo its own
terminal.

It isn't an IDE, and that's on purpose.

## Why I built this

Most of my code is now written by AI agents. My job has shifted from *writing* code to **checking what
the agent did and verifying it**. My workspace is one big root folder with dozens of independent git repos
inside it (services, libraries, apps), and agents happily make changes across many of them at once.

The tools I had didn't fit that workflow:

- **VS Code got slow on the big root.** With a huge multi-repo folder open and agents changing files
  across many repos, VS Code became very laggy and sometimes closed on its own. I didn't need
  extensions, language servers or IntelliSense to *review* changes. I needed something that stays fast.
- **Terminal file explorers stop at one repo.** Tools like Warp have a file explorer, but I couldn't
  search file names across *all* the repos under the root I was working in.
- **GitHub Desktop is one repo at a time, and doesn't speak "AI context".** When you work with an agent
  you constantly hand it precise context: *this file, these lines*. I wanted to copy
  `services/api/src/routes/users.ts:120-148` in one keystroke and paste it straight into the agent.

So Sightline does just those things, quickly.

## What it does

**Made for multi-repo workspaces**
- Scans a root folder and finds every nested git repo (plain nested repos, not only submodules).
- A sidebar with every repo, its branch, ahead/behind counts and number of changed files, all live.
- Changes made by an agent or in a terminal show up immediately (FSEvents watcher, no polling, no manual refresh).
- **⌘P: Go to File across every repo**, fuzzy-matched (≈15k files indexed in ~0.2 s via `git ls-files`).
- **⌘T: jump to a repo**, sorted by folder or by most recently opened.

**Made for reviewing AI changes**
- VS Code-style **diff viewer**: side-by-side or inline, whole-file context, syntax highlighting,
  changed-character highlights, aligned filler rows, ↑/↓ to jump between changes, and an
  **overview strip** that shows where in the file the changes are.
- **⇧⌘C copies `path:line` or `path:from-to`** (relative to the workspace root) for the caret or selection,
  in the editor or the diff. Hover a line number for a one-click copy button. Paste it straight into
  Claude Code, Cursor, Codex or any other agent.
- Stage, unstage and discard per file or per section, then **Commit** or **Commit (No Verify)**. Git hooks
  run with your login-shell `PATH`, so husky/lint-staged find `node`/`npx` even when the app is opened from Finder.
- Branch switching (local and remote) and fetch.

**Just enough to fix things by hand**
- File explorer with git status colors, a plain-text editor (syntax highlighting, find, auto-indent, ⌘S).
- **One terminal per repo**, already `cd`'d into it and kept alive while you switch repos (⌘J to toggle,
  ⌥J to kill and relaunch).

**Light**
- Native SwiftUI/AppKit, about 4 MB, no Electron, no extensions, no language servers, no indexing of `node_modules`.
- GitHub Light/Dark themed (System, Light or Dark).

## Install

Requires macOS 14 (Sonoma) or later, on Apple Silicon or Intel.

Build the app or the DMG from source:

```bash
git clone https://github.com/farhancdr/sightline.git
cd sightline
make install     # builds Sightline.app and copies it to /Applications
# or
make dmg         # universal build/Sightline-<version>.dmg with a drag-to-Applications window
```

You need Xcode 16+ (Swift 6 toolchain). The package builds in Swift 5 language mode.

Builds aren't notarized yet, so the first time you open a downloaded build, macOS blocks it. Allow it once
via **System Settings → Privacy & Security → Open Anyway**, or run
`xattr -dr com.apple.quarantine /Applications/Sightline.app`. Builds you make locally aren't affected.

## Shortcuts

| Key | Action |
|---|---|
| ⌘P | Go to file (all repos) |
| ⌘T | Find repo (⏎ opens the top match, ⎋ clears) |
| ⇧⌘C | Copy `path:line` / `path:from-to` for the caret or selection |
| ⌘B | Show / hide the repo sidebar |
| ⇧⌘B | Show / hide the Changes/Files panel |
| ⌘J | Show / hide the terminal |
| ⌥J | Kill the repo's terminal and start a fresh one |
| ⌃` | Focus the terminal |
| ⌘⏎ | Commit |
| ⌘S | Save file |
| ⌘F | Find in file |
| ⇧⌘T | Cycle theme (System → Light → Dark) |
| ⌘O | Open a root folder |
| ⌘R | Refresh all repos |
| ⇧⌘R | Rescan for repos |

## Development

```bash
make run        # debug build and launch (swift run)
make test       # unit tests
make app        # release .app for this Mac's architecture: build/Sightline.app
make universal  # Apple Silicon + Intel .app
make dmg        # universal DMG (scripts/layout-dmg.sh asks Finder to lay out the window;
                # macOS may ask once to allow it)

# Smoke test against a real workspace:
SIGHTLINE_ROOT=~/path/to/your/workspace swift test --filter LiveRootTests

# Re-render the DMG background and README banner after editing the SVGs in Resources/Design/source:
swift scripts/render-assets.swift
tiffutil -cathidpicheck Resources/dmg-background.png Resources/dmg-background@2x.png -out Resources/dmg-background.tiff
```

```
Sources/Sightline/
  App/            entry point, menu commands, app delegate
  Git/            git process wrapper, status/diff/branch/commit commands, diff model
  Store/          app state, repo scanner, FSEvents watcher, file explorer model, ⌘P index
  Editor/         editor session, line-number gutter, syntax highlighter and language rules
  Terminal/       one SwiftTerm terminal per repo
  Views/          SwiftUI and AppKit views (sidebar, changes, diff, explorer, palette, commit box)
  Support/        GitHub Primer color palette
Resources/        Info.plist, icons, DMG background, welcome illustration, Design/ sources
scripts/          DMG layout and asset rendering
```

### Design notes

- Sightline shells out to your `git` CLI, so hooks, credentials and config behave exactly like in a terminal.
- Status and diff reads run with `GIT_OPTIONAL_LOCKS=0`, so Sightline never writes `.git/index` itself and never
  triggers its own file watcher.
- `git fetch` runs with `ssh -o BatchMode=yes` (unless `GIT_SSH_COMMAND` is set), so a passphrase prompt fails
  fast instead of hanging.
- Syntax highlighting is a small hand-written scanner, not a parser: fast, with no dependencies, and good enough
  for reviewing.

## Contributing

Issues and pull requests are welcome. Please run `make test` before opening a PR.

## License

[MIT](LICENSE) © Farhan Sadek
