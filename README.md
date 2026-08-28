# Fire

*[한국어](README.ko.md)*

A tiny macOS menu bar app that sorts menu bar icons into two zones: the **main menu bar**
and the **Fire Bar**.

When there are too many icons for the bar to hold, the ones you rarely need get folded away
and come back only when you ask for them.

1.3 MB on disk, 74 MB resident. No Dock icon — it lives in the menu bar only.

## Download

**[Get Fire 0.1.0 (dmg)](https://github.com/kimhung910924/fire-menubar/releases/latest)**

- macOS 14 Sonoma or later
- Notarized by Apple, so it opens without a Gatekeeper warning
- Open the dmg and drag Fire to `Applications`

On first launch it asks for **Accessibility** and **Screen Recording**. They are used to
move menu bar icons and to read what they look like. Screen contents are never stored or
transmitted.

## Contact

[rrllab.com](https://rrllab.com) · contact@rrllab.com

---

## First-time setup

1. Launch the app. The settings window opens.
2. Grant **Accessibility** — System Settings › Privacy & Security › Accessibility
3. Grant **Screen Recording** — System Settings › Privacy & Security › Screen Recording
4. Relaunch Fire after granting them.
5. In settings, drag the icons you want folded away into the `Show in Fire Bar` zone. Fire
   positions the separator itself.
6. If any icon is marked orange, hold `⌘` and drag **that icon itself** in the menu bar to
   fix its order. See "OS constraints" below for why.

## Controls

| Action | How |
|---|---|
| Open / close the Fire Bar | Click empty menu bar space, or `⌥⌘F` |
| Open settings | Click the flame icon, or `⌥⌘,` |
| Close the Fire Bar | Click outside / `Esc` / 5 seconds idle |

## Build and run

```bash
./build.sh release
```

That produces `.build/app/Fire.app`:

```bash
open .build/app/Fire.app
```

Diagnostic mode, which only reports what the scan found and never shows a GUI:

```bash
./.build/app/Fire.app/Contents/MacOS/Fire --dump
```

### Ship a release

```bash
./scripts/release.sh            # Developer ID signing, notarization, dmg
./scripts/release.sh --publish  # and upload to GitHub Releases
```

## OS constraints — read this

Everything below was measured on macOS 26 while building the app.

### 1. You cannot hide or reorder another app's status item

No public API does that. The one technique every menu bar organizer uses, Ice and Bartender
included, is to **own a status item (the separator) and stretch its width to the width of
the screen**, pushing everything to its left off the display. Fire does the same
([ControlItemCoordinator.swift](Sources/Fire/StatusItem/ControlItemCoordinator.swift)).

The consequence: **hiding only works on a contiguous run of the menu bar**, because
everything to the left of the separator goes at once.

### Fire moves the separator itself

macOS stores a status item's position in **that app's own** user defaults.

```
key:    NSStatusItem Preferred Position <autosaveName>
value:  distance in pt from the right edge of the screen holding the menu bar
```

Another app's item belongs to that app's defaults and is untouchable, but **Fire's own
separator is not**. So you never drag the separator by hand — change the classification and
Fire recomputes the boundary.

The relationship between the stored value and the resulting placement was pinned down by
measurement. The separator inserts itself **immediately to the left of whichever item
contains** the coordinate `(screen right − value)`.

```
value 458 → 3390-458 = 2932  (boundary between Owly and pizzaClip) → inserts left of Owly      (Owly not hidden)
value 445 → 3390-445 = 2945  (inside pizzaClip)                    → inserts left of pizzaClip (Owly hidden)
value 420 → 3390-420 = 2970  (inside TextInput)                    → hides through pizzaClip
```

So you aim at the **middle** of the first item you want to keep, not at the boundary between
items. Aiming at a boundary is a coin flip over which side it lands on, and it comes out one
slot off.

One more trap: removing a status item makes macOS **erase** the stored position. The order
has to be `remove → record the value → recreate`. Doing it the other way around loses the
value you just recorded.

### What is still not fixable

If the classification does not line up with a contiguous run of the menu bar, it cannot be
satisfied, because Fire cannot change the physical order of anyone else's icon.

- an item marked FIRE_BAR that sits right of the boundary, so it stays visible
- an item marked MAIN that sits left of the boundary, so it gets hidden along with the rest

Both are flagged orange in settings. The fix is for you to `⌘`-drag **the icon itself** in
the menu bar.

### Settings shows the real menu bar order

The saved `order` is only the order you wanted when you dragged things around. What actually
gets hidden is decided by physical position, so showing the wished-for order would disagree
with the menu bar in front of you. The list is always sorted by the measured physical order.

The mechanism itself is verified by measurement:

```bash
./.build/app/Fire.app/Contents/MacOS/Fire --verify-hide
# or: open -n .build/app/Fire.app --args --verify-hide
```

```
before separator expands : 18 items
after separator expands  : 16 items
hidden                   : 2 items
after restore            : 18 items (restored cleanly)
```

A new status item always appears at the far left of the menu bar, so right after install
there is nothing to the separator's left. Move the separator right before anything can hide.

### 2. The owning PID of a status item cannot be trusted

On macOS 26, `kCGWindowOwnerPID` for every status item window points at **Control Center**.
The real owner is resolved in this order
([MenuBarScanner.swift](Sources/Fire/MenuBar/MenuBarScanner.swift)):

1. Enumerate Accessibility `AXExtrasMenuBar` — most accurate, needs Accessibility permission
2. The bundle identifier embedded in `kCGWindowName` — readable without permission, but some
   items only ever report `Item-0`
3. Relative order from the right edge of the menu bar — last resort

Two traps here, both measured.

- **The bundle identifier in `kCGWindowName` is sometimes the neighbor's.** So for items
  where Accessibility already told us the owner, the window name is not used to decide
  ownership — only to tell apart several items belonging to one app, like `WiFi`, `Battery`,
  and `Clock`.
- **Accessibility calls default to a 6 second timeout**, which makes a full sweep of every
  app stall for more than 20 seconds. `AXUIElementSetMessagingTimeout` cuts it to 0.25 s and
  brings the sweep under 2 seconds.
- Accessibility titles (`Battery 62%`, `Itsycal, August 1`) keep changing, so they are shown
  to the user but never used as part of an identifier.

### Identifiers must not depend on permission state

A bundle identifier is only knowable with Accessibility permission. Preferring it means the
identifier for the same item changes whenever permission is toggled, and the entire saved
layout evaporates.

So the priority is inverted: **an item's own name (`WiFi`, `Battery`, `Clock`) is preferred
over the bundle identifier.** Names are readable without permission, so both states produce
the same identifier. Verified:

```bash
# with permission (running the bundle) and without (running the binary from a shell)
# must produce the same result
open -n .build/app/Fire.app --args --dump && cat ~/Library/Application\ Support/Fire/dump.txt
./.build/app/Fire.app/Contents/MacOS/Fire --dump
```

### Captured icons cannot be used as-is

- Menu bar glyphs capture as white against their background, which makes them invisible on a
  light settings window. When a capture is detected as a single color, only its alpha is
  kept and it is repainted in `labelColor`
  ([MenuBarIconRenderer.swift](Sources/Fire/MenuBar/MenuBarIconRenderer.swift)).
- A good number of third-party apps capture as a **fully transparent image**, apparently
  because the drawing happens on the Control Center side. Those fall back to the owning
  app's icon.

### 3. Every display gets its own menu bar windows

The same item is duplicated once per display, and the copies for secondary displays carry
`Clone` in the name. The scanner groups windows into rows by screen, filters out clones and
off-screen windows, and takes the row with the most items as the reference.

## Layout

```
Sources/Fire/
├── App/              entry point, wiring, diagnostic modes
├── StatusItem/       the Fire icon and the separator (the hiding mechanism)
├── MenuBar/          scanning, identification, applying zones, click proxying
├── FireBar/          the panel, icon views, placement
├── Events/           empty-area detection, global clicks, shortcuts, system events
├── Stability/        rebuild coordinator, watchdog
├── Settings/         settings window, storage
├── Permissions/      Accessibility, Screen Recording
└── LoginItem/        SMAppService
```

Data lives in `~/Library/Application Support/Fire/`. PIDs, window numbers, display numbers,
screen coordinates, and captured images are never stored.

## Status

| Phase | State |
|---|---|
| 1 App skeleton | Done — accessory app, no Dock icon, status item, settings, login item, shortcuts |
| 2 Menu bar scanning | Done — measured (16 items scanned exactly) |
| 3 Two-zone management | Done, within the limits of "OS constraints 1" above |
| 4 Fire Bar | Done — panel, click proxy, auto-close, drag to reorder |
| 5 Empty menu bar click | Done — global monitor that does not consume the click |
| 6 Stability | Done — rebuild state machine, delayed verification, watchdog, manual recovery |
| 7 Real-world verification | In progress — see below |
| 8 Packaging | Done — Developer ID signing, notarization, dmg, GitHub release (`scripts/release.sh`) |

## When permissions do not stick

If System Settings lists Fire as enabled but the app says it has no permission, **the
signature changed**. TCC binds permissions to the code signing identity. An ad-hoc signature
(`-`) has no identity, so it is remembered by binary hash and every rebuild invalidates the
grant.

`build.sh` finds and uses an `Apple Development` certificate automatically. With a
certificate the identity is pinned by team identifier and survives rebuilds. To use a
different one:

```bash
FIRE_SIGN_IDENTITY="Developer ID Application: ..." ./build.sh release
```

If it was ever built ad-hoc, **remove the existing Fire entry in System Settings and add it
again**.

## Not yet verified

Items that need a real environment with permissions granted.

- [x] Owner identification through Accessibility — all 16 items identified exactly (`--dump`)
- [x] Real hiding via separator expansion, and clean restore (`--verify-hide`)
- [ ] Fire Bar icon clicks opening the original app's menu (Google Drive, Dropbox, VPN,
      clipboard managers, input methods, Control Center)
- [ ] Left and right empty-area clicks not interfering with the Apple menu or app menus
- [ ] Coordinate handling around the notch
- [ ] Automatic recovery after 20 external display connect/disconnect cycles
- [ ] Automatic recovery after 10 sleep/wake cycles
- [ ] Entering and leaving clamshell mode

## The name

There is a public project of the same name built on Ice, so the name is up for review.

The original planning document is
[Fire_맥_메뉴바_앱_기획안.md](Fire_맥_메뉴바_앱_기획안.md) (Korean).
