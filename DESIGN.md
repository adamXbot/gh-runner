# Runner Menu — Mac-Arsed Design Document

This document records the product, interaction, architecture, accessibility, and QA decisions for
Runner Menu.

---

## 1. Mac identity statement

**Category.** A **menu-bar utility** — a lightweight, always-available background helper, the
native Mac shape for "manage a daemon on this machine." It lives in the status bar, shows a panel
on click, has no document model, and stays out of the Dock (`LSUIElement`).

**Primary Mac workflows.**
- Glance at the menu-bar glyph to see whether a runner is online / busy without opening anything.
- Click to open a panel: start/stop a runner, watch its live stats, tail its log.
- Register a runner against a repo you administer, in a few clicks, without ever pasting a token.
- Keep the runner current: check GitHub, verify the download's SHA-256, update in place.

**Why the window model fits macOS.** A runner manager is ambient and status-oriented, not
document-oriented. The correct Mac form is a `MenuBarExtra` panel plus a standard **Settings**
window (⌘,) — not an app window you have to find and manage. Longer flows (register, updates, log)
are in-panel "screens" with a Back affordance rather than modal sheets, because a menu-bar popover
is transient and sheets on an `NSPanel` behave poorly.

**Conventions embraced.** Menu-bar accessory idiom; Settings scene at ⌘,; standard shortcuts
(⌘R refresh, ⌘U updates, ⌘Q quit, Return = primary action, Esc = back); right-click context menus
that act on the selection; Finder integration (Reveal in Finder); multi-representation copy
(runner name, repo URL); `SMAppService` login item; light/dark/high-contrast; VoiceOver labels.

**Intentional departures.**
- **No traditional app menu bar.** A `MenuBarExtra` accessory app has no persistent menu bar; the
  panel + context menus + Settings scene carry the command model instead. This is the accepted
  idiom for this app shape (the skill's "real menu bar" rule is satisfied by the status item's
  panel and menus, not by an empty top menu bar).
- **`gh` CLI as the credential broker.** Rather than a bespoke OAuth flow or a PAT text field
  (entering credentials into an app is exactly what we must not do), the app reuses the user's
  existing `gh` authentication. This is more secure and more Mac-pragmatic.

---

## 2. Affordance map

| Element | Native control/API | Selection | Keyboard | Copy/paste | Drag/drop | Context menu | State saved | Accessibility |
|---|---|---|---|---|---|---|---|---|
| Menu-bar glyph | `MenuBarExtra` label (SF Symbol) | — | Click/return opens panel | — | — | — | — | Labelled: "runner online / busy / none" |
| Runner list | `ScrollView` + selectable cards | Single-select (tap) | Arrow/tab focus; Return = start/stop selected | Copy name / repo URL (context) | — (future: drag folder out) | Start/Stop, Open on GitHub, Copy URL/Name, Reveal in Finder, Unregister, Remove | Selected runner id | Cards expose `.isSelected`, combined label |
| Runner detail | `VStack` of `StatRow`s | reflects list selection | Return primary; buttons focusable | All stat values `.textSelection` | — | (inherits row) | — | Each stat is a combined label |
| Recent jobs | list rows w/ result glyph | — | — | selectable text | — | — | — | icon + name + relative time |
| Register screen | `Form`-like, `Picker`, repo `List`, `TextField`s | repo row select | Field tab order; Esc back | native text fields | — | — | typed values (session) | labelled fields |
| Live log | `ScrollViewReader` + monospaced rows | text selection | Esc back | Copy whole log; per-line select | — | — | source (Runner/Worker), auto-scroll | monospaced, selectable |
| Updates screen | stat card + disclosure + button | — | Esc back; Return confirm | hash `.textSelection` | — | — | — | shield icon states labelled |
| Settings | `Form(.grouped)` + `Toggle`/`Picker`/`Stepper` | — | full keyboard | — | — | — | **all** persisted (UserDefaults + SMAppService) | standard controls |

---

## 3. Command / menu plan

Commands are reachable from the panel, from row **context menus**, and via **keyboard**:

| Command | Where | Shortcut | Validation |
|---|---|---|---|
| Refresh | Header | ⌘R | always (home only) |
| Start runner | Row + detail + context | Return (selected) | disabled if not configured / in-flight |
| Stop runner | Row + detail + context | Return (selected) | only when running |
| Force stop | Context menu | — | only when running |
| Add / Register | Footer + empty state | — | needs `gh` auth |
| Check updates | Footer + detail | ⌘U | needs a selected runner |
| Update now | Updates screen | Return (confirm dialog) | disabled unless hash verifiable (or override) |
| Open on GitHub | Context + detail | — | needs configured repo |
| Reveal in Finder | Context menu | — | always |
| Copy repo URL / runner name | Context menu | — | always |
| Install/remove launchd service | Detail | — | configured runners |
| Unregister from GitHub | Context menu | — | configured + repo/org scope |
| Settings | Footer | ⌘, | always (`SettingsLink`) |
| Quit | Footer | ⌘Q | always |

Every important action is reachable from a labelled control or a menu — never an unlabeled icon only
(icons carry `.help()` tooltips and accessibility labels).

---

## 4. Window / document plan

- **Status panel** (`MenuBarExtra`, `.window` style, fixed 388 pt width, scrolls vertically).
- **In-panel screens** (home ⇄ register ⇄ updates ⇄ log) via a `Route` enum + Back button, so nothing
  relies on sheets inside a popover.
- **Settings window** — the one real window, standard `Settings` scene, ⌘,.
- No documents, no multi-window: correct for a status utility.

---

## 5. Interoperability plan

- **`gh` CLI** for all GitHub reads/writes (repos, tokens, runners, releases) — reuses the user's auth.
- **Runner scripts** (`run.sh`, `svc.sh`, `config.sh`) driven as subprocesses — the app is a controller,
  not a reimplementation, so it stays compatible with GitHub's runner.
- **launchd** (`svc.sh` → LaunchAgent) for a persistent, login-starting runner.
- **Finder** — Reveal in Finder for runner folders and log files.
- **Pasteboard** — copy runner name / repo URL; all values selectable.
- **`SMAppService`** — the app itself as a login item.
- **GitHub web** — Open on GitHub / release notes via `NSWorkspace`.

The cross-user redesign introduces a signed, standard-account Runner Agent behind a semantic
execution backend. See [Cross-user runner architecture](docs/CROSS_USER_ARCHITECTURE.md).

---

## 6. Settings & state plan

Persisted in `UserDefaults` (and `SMAppService`):
- Runner directories (the managed set) · refresh interval · start method (run.sh vs launchd) ·
  `gh` path · selected runner · login-item state.

Transient (not persisted): download progress, in-flight action set, banners, current panel route.

Reset behavior: removing a folder only forgets it in the app; it never deletes the runner directory.

---

## 7. Accessibility plan

- Menu-bar glyph has a state-describing `accessibilityLabel`.
- Runner cards combine children into one labelled, selectable element and expose `.isSelected`.
- All stat values and log lines are `.textSelection(.enabled)` and VoiceOver-readable.
- Every icon-only button has both `.help()` and an `accessibilityLabel`.
- Uses system colors / SF Symbols → dark mode, increased contrast, and Dynamic-Type-ish sizing come
  for free; status is never conveyed by color alone (glyph shape + text label always accompany it).

---

## 8. QA checklist

See [README.md](README.md#manual-qa-checklist). The environment can run macOS, and the app was
compiled and launched; runtime behavior of GitHub-mutating actions (register/unregister/update)
should be exercised manually against a test repo before relying on them.
