# LogoCore

The Swift library behind LogoLight: control the glowing Apple logo on the OLED MacBook Pro from your own code.

Same requirements and disclaimer as the [app](../../README.md): tested on MacBook Pro M5 Pro with macOS 27.2 only, and
it relies on undocumented macOS interfaces. The API may change between 0.x releases.

## Add it

```swift
// Package.swift
platforms: [.macOS("27.0")],
dependencies: [.package(url: "https://github.com/jaxmef/LogoLight", from: "0.2.0")],   // resolves to the latest 0.x

// your target
dependencies: [.product(name: "LogoCore", package: "LogoLight")],
```

Your app must not be sandboxed: the App Sandbox blocks the calls LogoCore makes.

## Use it

```swift
import LogoCore

let logo = try LogoController()           // throws on unsupported hardware
try logo.setBrightness(percent: 40)       // 0–100; 0 is the dimmest glow
try logo.setOff()
try logo.setDefault()                     // hand the logo back to macOS
```

## Good to know

- **You own the logo until you call `setDefault()`.** `setOff()` and `setBrightness` stay in effect after your
  process exits, also across restarts. Call `setDefault()` when you're done.
- **Lid and sleep are up to you.** While you control the logo, macOS doesn't turn it off when the lid closes or the Mac
  sleeps. Call `setOff()` then; `LogoController.isLidClosed()` helps.
- **Calls block briefly.** `init` can take up to 2.5 s right after macOS changed the logo, and `setDefault()` about
  0.3 s. Keep them off the main thread if that matters.
- **Brightness is capped** at what macOS itself uses. There's no way around it through this API.
