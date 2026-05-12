# AGENTS.md

Guidance for AI coding assistants working in this repo. Read this before doing anything else.

## Repo identity — this is a fork

| | |
|---|---|
| Working repo (issues + PRs land here) | `marknutter/BrightXDR` |
| Upstream (do **not** file against) | `starkdmi/BrightXDR` |

`gh` may default-resolve to the upstream because the local `origin` is the fork but the upstream is reachable. Either run once per checkout:

```bash
gh repo set-default marknutter/BrightXDR
```

…or pass `--repo marknutter/BrightXDR` on every `gh issue`, `gh pr`, `gh project` invocation. Issue numbering on the fork is independent of the upstream — do not assume an issue number you saw on `starkdmi/BrightXDR` exists on the fork.

## Architecture (1-minute orientation)

- Swift/Cocoa **LSUIElement** (menu-bar-only) app.
- Entry: `BrightXDR/main.swift` → lifecycle: `BrightXDR/AppDelegate.swift` → rendering: `BrightXDR/MetalView.swift`.
- A transparent, click-through, borderless `NSWindow` sits at `CGShieldingWindowLevel() + 19`, full-screen on `NSScreen.main`. Inside it is an `MTKView` with `colorPixelFormat = .rgba16Float`, `wantsExtendedDynamicRangeContent = true`, and `compositingFilter = "multiplyBlendMode"`. It renders a static white `CIImage` through a `CIColorControls` filter — the multiply blend pushes the underlying display into EDR mode, brightening everything visible.
- "Brightness" = the `CIColorControls` brightness multiplier (default 1.5, range 0.5–2.5). The menu-bar slider re-tunes the filter live via `MetalView.setBrightness(_:)` without rebuilding the view.
- `window.sharingType = .none` excludes the overlay from screen captures so screenshots don't come out washed-out.

## Suppress logic — the part most bugs revolve around

`MetalView.draw(in:)` decides every frame whether the overlay is visible:

```swift
suppress = !userEnabled || (capturing && !captureOverrideActive)
window.alphaValue = suppress ? 0.0 : 1.0
```

- **`userEnabled`** — the Boost toggle. Backed by `UserDefaults` (key `boostEnabledKey`). Flipped by the menu item and the ⌃⌥⌘B Carbon hotkey, both routing through `AppDelegate.toggleBoostState()`.
- **`capturing`** — `isScreencaptureuiShowingInteractiveUI()`: true when `com.apple.screencaptureui` owns at least one on-screen window larger than 200×200. Reads `CGWindowListCopyWindowInfo` with `bounds` + `ownerPID` only — **never window titles** — so it works without the macOS 13+ Screen Recording TCC prompt. The 200px threshold separates real capture UI (selection rect, cmd-shift-5 panel, recording session) from the lingering screenshot thumbnail (~140×100).
- **`captureOverrideActive`** — manual escape hatch added in issue #8. Set true when the user toggles Boost **on**; auto-cleared on the next frame `capturing` reads false. Without it, a stuck `capturing == true` state (e.g. screencaptureui leaving a window resident after the screenshot thumbnail is dragged out) leaves no recovery short of quitting the app.

### Invariants — break these and brightness behavior regresses

1. **Never stop rendering when suppressed.** The code sets `window.alphaValue = 0` instead of returning early in `draw`. If you stop presenting drawables, macOS de-engages EDR on that layer and ramps back up over 0.5–2s when the overlay returns — visible as a "screen takes a beat to brighten" lag.
2. **Hotkey must stay Carbon.** ⌃⌥⌘B is registered via `RegisterEventHotKey`, not `NSEvent.addGlobalMonitorForEvents`. Carbon doesn't need Accessibility permission and survives focus changes — critical when the overlay has whited out the screen and no app can take focus to surface a permission prompt.
3. **The detector must not read window titles.** Doing so triggers the Screen Recording TCC prompt on macOS 13+. Bounds + ownerPID + layer + alpha are all available without it.
4. **Manual override clears automatically.** Anything that gates `captureOverrideActive` must reset it when `capturing` naturally returns false, or the next genuine cmd-shift-4 will white out.

## Diagnostic logging

`MetalView` emits `NSLog` lines on `capturing` state transitions (not every frame). Visible in **Console.app with filter `BrightXDR`**. The "capturing detected" log records bounds, window layer, and alpha for every screencaptureui window large enough to trigger suppression — use this to refine the 200px detector. The open follow-up to issue #8 is to use this data to tighten the heuristic so the drag-out doesn't trigger suppression in the first place.

## Workflow

- **Single-branch convention.** No `develop`. Feature branches off `main` and PR back to `main`.
- **Branch names must start with the issue number.** `{number}-short-description`. The user's stop-hook reads the issue number off the branch name to verify acceptance criteria.
- **File issues on the fork.** `gh issue create --repo marknutter/BrightXDR …` — and after `gh repo set-default`, `--repo` becomes optional.
- The "Report affected app…" menu item in the app posts pre-filled issues to `marknutter/BrightXDR/issues/new` (see `AppDelegate.reportAffectedApp(_:)`). Keep that URL in sync if the fork ever moves.

## Building

- `xcodebuild` requires `/Applications/Xcode.app`, not Command Line Tools. The agent's environment typically has `xcode-select` pointing to `/Library/Developer/CommandLineTools`; setting `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` is the workaround.
- The Xcode license must have been accepted by the user via `sudo xcodebuild -license` — an agent **cannot** accept it non-interactively.
- If you can't build from the agent's environment, say so explicitly — never claim build-success based on SourceKit diagnostics alone. SourceKit in this checkout sometimes reports stale "cannot find MetalView in scope" type errors that don't reflect reality; trust an actual compile or the user's Xcode build.

## Files of note

| Path | Purpose |
|---|---|
| `BrightXDR/main.swift` | App entry; instantiates `AppDelegate` |
| `BrightXDR/AppDelegate.swift` | Window setup, status bar menu, Boost toggle, Carbon hotkey, brightness slider |
| `BrightXDR/MetalView.swift` | MTKView subclass; suppress logic, screencaptureui detector, `CIColorControls` filter, `setBrightness`, `setCaptureOverride` |
| `BrightXDR/Info.plist` | `LSUIElement` = YES (menu-bar-only) |
| `BrightXDR/BrightXDR.entitlements` | Sandbox/permission entitlements |

## Things future-you will probably forget

- The fork's `origin` is `marknutter/BrightXDR` but `gh` may still resolve to the upstream — check `gh repo view --json nameWithOwner` if in doubt.
- The detector returning `true` on `CGWindowListCopyWindowInfo` failure is intentional (fail-closed so a real capture isn't whited out) — don't "fix" it.
- The text overlay that says "Bright XDR" for 1.5s on launch is rendered by the same Metal pipeline; the brightness multiplier applies to it too.
- `window.collectionBehavior` includes `.canJoinAllSpaces` and `.fullScreenAuxiliary` — required for the overlay to follow the user across Spaces and into full-screen apps.
