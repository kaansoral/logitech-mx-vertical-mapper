# Logitech MX Vertical Button Remapper for macOS

A lightweight, open-source macOS menu bar app that remaps the extra buttons on the **Logitech MX Vertical** ergonomic mouse to custom keyboard shortcuts — no Logi Options+ required.

Built natively in Swift using `CGEventTap` and the **Logitech HID++ 2.0 protocol** via IOKit. Single file, zero dependencies, under 600 lines.

## Button Mappings

| Button | Location | Action |
|--------|----------|--------|
| Side back | Thumb area (rear) | Screenshot region to clipboard (`Cmd+Ctrl+Shift+4`) |
| Side front | Thumb area (front) | Paste (`Ctrl+V`) |
| Top / DPI button | Top of mouse, near LED indicators | Mission Control |

The side buttons are intercepted via `CGEventTap`. The DPI/top button requires **HID++ 2.0 protocol communication** because it's handled by the mouse firmware and doesn't produce a standard mouse event — the app diverts it using the `REPROG_CONTROLS_V4` HID++ feature so it reports to macOS instead of cycling DPI.

## Connection Types

| Connection | Status |
|------------|--------|
| USB cable (wired) | Tested, works |
| 2.4 GHz USB receiver (Unifying/Bolt) | Tested, works |
| Bluetooth | Untested |

The app supports both **USB cable** and **2.4 GHz wireless receiver** connections and can switch between them on the fly. Bluetooth is untested — Logitech's Bluetooth implementation has always been jittery, so the 2.4 GHz receiver or USB cable is recommended.

If you switch connection types (e.g., unplug cable and switch to receiver), use the **"Reconnect HID++"** button in the menu bar to reinitialize the HID++ connection.

## Why This Exists

The Logitech MX Vertical is a great ergonomic mouse, but customizing its buttons on macOS typically requires **Logi Options+** — a bloated Electron app that installs background services and kernel extensions.

This app replaces all of that with a ~20KB native binary. It:

- Runs as a **menu bar icon** (no dock icon, no window)
- Starts at login automatically
- Reconnects after sleep/wake
- Uses **zero CPU** when idle (event-driven, no polling)
- Works with **USB cable** and **2.4 GHz receiver (Unifying/Bolt)**
- Requires only **Accessibility** permission (no kernel extensions, no drivers)

## Requirements

- macOS 13 Ventura or later
- Logitech MX Vertical mouse
- Xcode Command Line Tools (`xcode-select --install`)

## Build & Install

```bash
git clone https://github.com/kaansoral/logitech-mx-vertical-mapper.git
cd logitech-mx-vertical-mapper
./build.sh
cp -r build/LogitechVerticalMXMapper.app /Applications/
```

Then launch the app:

```bash
open /Applications/LogitechVerticalMXMapper.app
```

## Granting Accessibility Permission

On first launch, the app will prompt you to grant **Accessibility** access. This is required for intercepting mouse button events.

1. The app will show a dialog — click **"Open Settings"**
2. In **System Settings > Privacy & Security > Accessibility**, find **LogitechVerticalMXMapper**
3. Toggle it **ON**
4. The app will detect the permission automatically and start working

> If you rebuild the app, macOS invalidates the permission (the binary signature changes). You'll need to **remove and re-add** the app in Accessibility settings, or toggle it off and on.

## Menu Bar Controls

Click the mouse icon in the menu bar to access:

| Menu Item | Description |
|-----------|-------------|
| **Reconnect HID++** (Cmd+R) | Reinitializes the HID++ connection to the mouse. Use this when switching between USB cable and wireless receiver, or if the DPI button stops responding. |
| **Start at Login** | Toggle automatic launch at login. Enabled by default on first launch. |
| **Quit** (Cmd+Q) | Exit the app. |

## Customizing Button Mappings

Edit `AppDelegate.swift` and modify the `eventTapCallback` function for side buttons, or the `handleDivertedButtonEvent` function for the DPI button.

Key codes and modifier flags:

```swift
// Common virtual key codes
// V = 0x09, C = 0x08, 4 = 0x15, Up = 0x7E, F3 = 0x63

// Modifier flags
// .maskCommand, .maskControl, .maskShift, .maskAlternate
```

After editing, rebuild with `./build.sh` and re-copy to `/Applications/`.

## How It Works

### Side Buttons (CGEventTap)

The two thumb buttons generate standard `otherMouseDown` events with button numbers 3 and 4. A `CGEventTap` intercepts these events, suppresses the original mouse event, and posts synthetic keyboard events via `CGEvent`.

### DPI / Top Button (HID++ 2.0)

The top button is a DPI switch handled by the mouse firmware — it never generates a mouse event visible to macOS. To capture it, the app:

1. Opens the Logitech **vendor-specific HID interface** (usage page `0xFF00`) via IOKit
2. Discovers the mouse on the Unifying/Bolt receiver by probing device indices
3. Queries **IRoot** (HID++ feature `0x0000`) to find the **REPROG_CONTROLS_V4** feature (`0x1B04`)
4. Sends a **setCidReporting** command to divert CID `0x00FD` (the DPI button) from firmware to host
5. Listens for **divertedButtonsEvent** notifications on a background thread
6. Fires the configured action when the button is pressed

The diversion uses the `persist` flag so it survives mouse power cycles. The app automatically reconnects after sleep/wake or USB reconnection.

## Debugging

Logging is enabled by default. Logs are written to `~/.mxmapper.log` and reset on each app launch.

To disable logging, change line 16 in `AppDelegate.swift`:

```swift
private let loggingEnabled = false
```

## Project Structure

```
AppDelegate.swift    # Entire app — event tap, HID++, menu bar, login item
Info.plist           # Bundle metadata (LSUIElement = true for menu bar only)
build.sh             # Compiles, bundles, and ad-hoc signs the .app
```

## Adapting for Other Logitech Mice

This approach works for any Logitech mouse that supports **HID++ 2.0** and the **REPROG_CONTROLS_V4** feature. To adapt:

1. Find your button's **Control ID (CID)** — check the logs after connecting, or enumerate controls via HID++ function 1 on the REPROG feature
2. Update `CID_DPI_BUTTON` with your button's CID
3. Update the action in `handleDivertedButtonEvent`

Compatible mice include: MX Master 3/3S, MX Anywhere 3, MX Ergo, MX Vertical, and most modern Logitech wireless mice.

## Acknowledgments

The HID++ 2.0 protocol implementation was informed by the [Mouser](https://github.com/TomBadash/Mouser) project, which demonstrates HID++ button diversion for Logitech mice using hidapi. This project's approach to feature discovery, button diversion via `REPROG_CONTROLS_V4`, and diverted event parsing was invaluable as a reference. Thank you!

## License

MIT
