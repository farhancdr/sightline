# Sightline

Native macOS app (SwiftUI + AppKit, SwiftPM, macOS 14+) for reviewing what AI agents changed across a
workspace of many nested git repos: repo discovery with live status, side-by-side/inline diffs, staging and
commit, ⌘P file search across repos, `path:line` references, file explorer + plain-text editor, branch
switching, and one terminal per repo. User-facing docs: `README.md`.

## Commands

```bash
make run          # debug build + launch (swift run)
make test         # swift test (all unit tests; LiveRootTests skips without SIGHTLINE_ROOT)
make app          # release .app for this Mac's arch → build/Sightline.app
make universal    # arm64 + x86_64 .app (built per arch, merged with lipo)
make dmg          # universal DMG with the drag-to-Applications window → build/Sightline-<version>.dmg
make install      # build/Sightline.app → /Applications
SIGHTLINE_ROOT=~/some/workspace swift test --filter LiveRootTests   # smoke test on a real multi-repo root
swift scripts/render-assets.swift   # re-render DMG background + README banner from Resources/Design/source SVGs
scripts/next-version.sh             # version CI would release next
```

Run `make test` after every change. Build warnings in `Sources/` should stay at zero.

## Layout

```
Sources/Sightline/
  App/SightlineApp.swift   entry, menu commands + shortcuts, AppDelegate (activation, theme, quit prompt)
  Git/                     Git.swift (Process wrapper), GitCommands.swift (status/diff/branches/stage/commit/
                           ls-files + porcelain v2 parser), DiffDocument.swift (diff → aligned rows), Models.swift
  Store/                   AppStore.swift (@Observable @MainActor singleton: all app state), RepoScanner,
                           FileWatcher (FSEvents), ExplorerModel (lazy tree), FileIndex (⌘P fuzzy search)
  Editor/                  EditorSession/EditorController (NSTextView editor), LineNumberRuler,
                           SyntaxHighlighter + Language (hand-written scanner, no parser)
  Terminal/                TerminalManager (one SwiftTerm LocalProcessTerminalView per repo)
  Views/                   SwiftUI views + AppKit-backed views (DiffTextView.swift holds the diff columns,
                           gutter, overview ruler)
  Support/Palette.swift    GitHub Primer light/dark colors (UI, git status, diff, terminal)
Tests/SightlineTests/      XCTest; LiveRootTests is opt-in via SIGHTLINE_ROOT
Resources/                 Info.plist, AppIcon/VolumeIcon .icns, DMG background, welcome SVGs, Design/ sources
scripts/                   layout-dmg.sh (Finder layout), render-assets.swift, next-version.sh
.github/workflows/release.yml   push to main (app paths) → test, build DMG, publish next patch release
```

## Conventions

- Swift 5 language mode (`swift-tools-version:5.10`) on a Swift 6 toolchain. SwiftTerm's delegates aren't
  Sendable-annotated; don't switch to Swift 6 mode casually.
- No resources in the SwiftPM target: the generated `Bundle.module` accessor `fatalError`s inside a packaged
  .app. App resources are copied into `Contents/Resources` by the Makefile (`APP_RES`) and loaded via
  `Bundle.main`, with a fallback for `swift run`.
- Git is always the `git` CLI (hooks/credentials/config behave like the terminal), never libgit2.
- Colors come from `Palette` / `Color.gh*`, never hardcoded system colors.
- Persisted preferences live in `UserDefaults` (bundle id `io.github.farhancdr.sightline`).
- Commits: short imperative subject. Releases are automatic; bump `CFBundleShortVersionString` in
  `Resources/Info.plist` only to start a new major/minor series (CI bumps the patch from the latest tag).

## Gotchas (learned the hard way)

- **Git process I/O:** drain stdout and stderr concurrently (`Git.run`), or big diffs/fetches deadlock.
  Reads run with `GIT_OPTIONAL_LOCKS=0` so status/diff never write `.git/index` and re-trigger the watcher.
- **PATH:** GUI apps get a minimal PATH. `Git.loginShellPath` (from `$SHELL -ilc`) is used for git so hooks
  (husky → node/npx via nvm) work when launched from Finder. Resolve the git binary explicitly.
- **FileWatcher relevance:** inside `.git/` only HEAD, index, refs, packed-refs and *_HEAD matter; ignore
  objects/, logs/, `*.lock`, node_modules, .build.
- **Terminals:** keep every terminal view in the container and toggle `isHidden`; removing views zeroes their
  size and sends SIGWINCH storms. Don't `makeFirstResponder` on repo switch (steals sidebar arrow keys).
  Interactive zsh ignores SIGTERM: send SIGHUP after `terminate()`.
- **SwiftUI TextField + `.onKeyPress` in an overlay** stopped updating its binding after the first keystroke.
  The ⌘P palette uses `PaletteSearchField` (NSTextField + delegate commands) instead.
- **Menu shortcuts:** don't put `.disabled(...)` on Commands that depend on `@Observable` state; menus may not
  re-evaluate. Make the action a no-op instead.
- **Text views:** TextKit 1 (`NSTextView(frame:textContainer:)`) with a 1e7-wide container for horizontal
  scrolling. Full-width line backgrounds are drawn in `DiffLayoutManager.drawBackground` using the text
  view's width (not the visible width, or fills end mid-screen when scrolled).
- **Diff alignment:** both columns always have the same row count (fillers); per-row file line numbers live in
  `DiffSide.numbers` and drive `path:line` copying.
- **DMG:** Finder's layout pass deletes `.VolumeIcon.icns` and clears the custom-icon flag, so the volume icon
  is applied after it. Stage the DMG under `/tmp/sightline-dmg` because `.DS_Store` stores a bookmark to
  the image it was laid out in (it would embed the checkout path). Layout failure is non-fatal for CI.
- **Release builds:** `RELEASE_FLAGS` remaps source paths (`-Xswiftc -file-prefix-map -Xswiftc …`, two
  tokens) and `strip -S -x` removes debug maps, so binaries don't embed local absolute paths.
  The combined `--arch arm64 --arch x86_64` build fails; build each arch and `lipo`.
- **SVG text:** macOS's SVG renderer ignores font-weight/letter-spacing/tspan colors; `render-assets.swift`
  strips `<text>` and draws it with the system font.
- **Tests must not touch user state:** use injected `NSPasteboard(name:)` and temp git repos.
