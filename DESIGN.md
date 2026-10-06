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

**Conventions embraced.** Menu-bar accessory idiom; Settings scene at ⌘, with toolbar tabs; the
standard About window, Help menu (manual, Keyboard Shortcuts, Welcome) and app menu; standard shortcuts
(⌘R refresh, ⌘Q quit, Return = primary action, Esc = back); right-click context menus
that act on the selection; Finder integration (Reveal in Finder); multi-representation copy
(runner name, repo URL); `SMAppService` login item; light/dark/high-contrast; VoiceOver labels.

**Intentional departures.**
- **A menu bar only while a window is open.** A `MenuBarExtra` accessory app has no persistent
  menu bar; the panel + context menus + Settings scene carry the command model. While any window is
  open (the main window, Settings, About, the manual) the app joins the Dock and shows the standard
  app, File, Edit, View, Window and Help menus, then leaves again when the last window closes.
- **`gh` CLI as the credential broker.** Rather than a bespoke OAuth flow or a PAT text field
  (entering credentials into an app is exactly what we must not do), the app reuses the user's
  existing `gh` authentication. This is more secure and more Mac-pragmatic.

---

## 2. Affordance map

| Element | Native control/API | Selection | Keyboard | Copy/paste | Drag/drop | Context menu | State saved | Accessibility |
|---|---|---|---|---|---|---|---|---|
| Menu-bar glyph | `MenuBarExtra` label (SF Symbol) | — | Click/return opens panel | — | — | — | — | Labelled: "runner online / busy / none" |
| Onboarding | Account-choice cards + discovery `List` | Multi-select discovered runners | Full keyboard; Continue/Back | — | — | — | Completion, execution mode, imported folders | Native buttons, checkboxes, labels |
| Runner list | `ScrollView` + selectable button cards | Single-select (click/Space) | Tab/Shift-Tab focus; Return = start/stop selected | Copy name / repo URL (context) | — (future: drag folder out) | Start/Stop, Open on GitHub, Copy URL/Name, Reveal in Finder, Unregister, Remove | Selected runner id | Selection exposes `.isSelected` and a combined label; Start/Stop is a separate button |
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
| Check updates | Action bar + detail | — | needs a selected runner |
| Update now | Updates screen | Return (confirm dialog) | disabled unless hash verifiable (or override) |
| Open on GitHub | Context + detail | — | needs configured repo |
| Reveal in Finder | Context menu | — | always |
| Copy repo URL / runner name | Context menu | — | always |
| Install/remove launchd service | Detail | — | configured runners |
| Unregister from GitHub | Context menu | — | configured + repo/org scope |
| Settings | Footer gear | ⌘, | always |
| Quit | Footer | ⌘Q | always |
| About, Help, Keyboard Shortcuts | App and Help menus, About button in Settings | ⌘? for shortcuts | always |

Every important action is reachable from a labelled control or a menu — never an unlabeled icon only
(icons carry `.help()` tooltips and accessibility labels).

---

## 4. Window / document plan

- **Status panel** (`MenuBarExtra`, `.window` style, fixed 388 pt width, scrolls vertically).
- **In-panel screens** (home ⇄ register ⇄ updates ⇄ log) via a `Route` enum + Back button, so nothing
  relies on sheets inside a popover.
- **Settings window** — standard `Settings` scene, ⌘,, with General, Runners, Accounts and Updates
  tabs on the shared surface scaffold.
- **About, manual and Keyboard Shortcuts** — the shared fixed-size windows, opened from the app and
  Help menus and from About in Settings.
- No documents: correct for a status utility.

---

## 5. Interoperability plan

- **`gh` CLI** for all GitHub reads/writes (repos, tokens, runners, releases) — reuses the user's auth.
- **Runner scripts** (`run.sh`, `svc.sh`, `config.sh`) driven as subprocesses — the app is a controller,
  not a reimplementation, so it stays compatible with GitHub's runner.
- **launchd** (`svc.sh` → LaunchAgent) for a persistent, login-starting runner.
- **Finder** — Reveal in Finder for runner folders and log files.
- **Pasteboard** — copy runner name / repo URL; all values selectable.
- **`SMAppService`** — the app itself as a login item.
- **App-bundled `SMAppService` LaunchDaemon** — the read-only Runner Agent runs as the standard
  `runner` account and serves an authenticated privileged Mach service.
- **`NSXPCConnection`** — versioned health and discovery messages; both peers apply code-signing
  requirements before the connection is activated.
- **GitHub web** — Open on GitHub / release notes via `NSWorkspace`.

The cross-user redesign introduces a signed, standard-account Runner Agent behind a semantic
execution backend. See [Cross-user runner architecture](docs/CROSS_USER_ARCHITECTURE.md).

---

## 6. Settings & state plan

Persisted in `UserDefaults` (and `SMAppService`):
- Runner directories (the managed set) · refresh interval · start method (run.sh vs launchd) ·
  `gh` path · login-item state · onboarding completion · execution-account mode · unresolved registration cleanup notices.

Session state: the registration draft, progress, and recoverable error live in `RunnerStore`, so closing
or changing panels does not discard them. Drafts reset after success or explicit Discard Draft.
Lifecycle, service, registration, and update work share one lock per runner; Start/Stop remain
unavailable until starting/stopping settles. Ownership and dedicated-mode capabilities apply in every
surface and batch action. Runner update phases reflect the actual download, verification, idle check,
stop, installation, and restart.

Window state: the detail tab, log source, and follow setting survive runner selection changes.
Transient (not persisted): selected runner, operations, banners, current panel route, and window state.
Runner Agent registration status, health, and discovered records are also refreshed rather than persisted.

Reset behavior: removing a folder only forgets it in the app; it never deletes the runner directory.

---

## 7. Accessibility plan

- Menu-bar glyph has a state-describing `accessibilityLabel`.
- Runner cards group a labelled selection button with a separate Start/Stop button; selection
  exposes `.isSelected` without hiding the action from VoiceOver.
- All stat values and log lines are `.textSelection(.enabled)` and VoiceOver-readable.
- Every icon-only button has both `.help()` and an `accessibilityLabel`.
- Uses system colors / SF Symbols → dark mode, increased contrast, and Dynamic-Type-ish sizing come
  for free; status is never conveyed by color alone (glyph shape + text label always accompany it).

---

## 8. QA checklist

### Interaction feedback

System buttons, menus, sidebar selection, text fields, toggles, pickers, and disclosures keep their
native macOS feedback. Custom cards, job rows, and compact actions use `RunnerButtonStyle`:
semantic hover shading, a brief pressed highlight and compression, and an accent focus outline.
Runner selection is a real button, with Start/Stop as a separate sibling button so both remain
keyboard-accessible and one action cannot accidentally activate the other. Selection, setup steps,
panel routes, detail tabs, inline confirmations, banners, and label edits use short local transitions.

Press feedback starts immediately (80 ms) and releases in 160 ms; hover uses 120 ms, content changes
180 ms. These animations retarget on rapid input and never delay an action. Disabled controls show
neither hover nor press feedback. Reduce Motion removes custom scaling, transitions, and status
pulses while retaining static hover/pressed/selected/focus cues. Increased Contrast strengthens
hover and pressed fills. Live statistics and log streams are never animated as interaction feedback.

See [README.md](README.md#manual-qa-checklist). The environment can run macOS, and the app was
compiled and launched; runtime behavior of GitHub-mutating actions (register/unregister/update)
should be exercised manually against a test repo before relying on them.
