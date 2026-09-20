# Horizon

![Horizon](Resources/logo.png)

A macOS app for inverting scanned colour negatives and printing them the way a minilab would.

Feed it raw captures from whatever you're scanning with, and it does the density inversion, film-base subtraction, exposure, tone, and colour balance, then sends the result through either a built-in RA-4-style print curve, a loaded ICC profile, or a `.cube` LUT. It's not tied to any particular rig — as long as you're getting raw frames in, Horizon doesn't care how they got there.

The name's a nod to the old Fuji Frontier scanners — same mount-and-minilab lineage as the Noritsu machines, that whole era of scanning hardware — which is where the look and the workflow take their cues from, not a rebrand of anything.

## How it works

One pipeline, one of three ways to finish it:

```
raw captures
  → invert           density conversion, film-base subtraction, border detection
  → Cineon master     16-bit TIFF, cached next to your captures
  → levels            stretch to the frame's own black and white points
  → expose            density control, placing the frame's exposure on its aim
  → shape             contrast/tone as a slope pivoted on that aim
  → balance           C/M/Y as a printer-light-style offset
  → print emulation   built-in curve, or a .cube LUT, or an ICC profile
  → sRGB              (with an optional luma collapse for black and white)
```

Density, contrast, and colour are kept fully independent of each other — moving one doesn't quietly shift the others, which is normally the annoying part of grading a scan by hand.

There's also a roll-level colour cast meter (⌘K to measure, ⇧⌘K to apply) and a review grid (⌘G) for checking a whole roll at a consistent size before you commit to a look.

## Building it

You'll need macOS 14 or later and a Swift toolchain (Xcode is easiest). Then:

```
./make-app.sh
```

This compiles the Swift package in release mode, regenerates the app icon if you've changed `Resources/icon-1024.png`, and assembles everything into `Horizon.app` — copying the binary, icon, and LUTs into a proper bundle with an `Info.plist`, since without one SwiftUI will happily run the process and never show you a window.

Drag the resulting `Horizon.app` wherever you keep your apps.

## LUTs

Horizon expects Cineon-encoded log input for its LUTs, so anything meant for a printed film look — the kind of `.cube` files DaVinci Resolve exports, or that you'd use for a Cineon-to-print conversion — will work as expected.

Two ways to use them:

**Bundle them in.** Drop your `.cube` files into `Resources/luts/` before running `make-app.sh`, and they'll get copied into the app bundle at build time.

**Load them at runtime.** From the app, use Settings ▸ Load .cube… to point at a LUT file directly, no rebuild needed. This is the faster way to try something out; bundling is for LUTs you want shipped with the app permanently.

Either way, only one print method is active at a time — picking a LUT, an ICC profile, or the built-in curve turns the other two off. There's no "none" option; the app always terminates through something.
