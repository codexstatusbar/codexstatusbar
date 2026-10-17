# App icon

Generated with the built-in imagegen tool on 2026-10-17. `AppIcon.png` is the
transparent source; `AppIcon.icns` contains 16, 32, 128, 256 and 512 point images
at 1x and 2x resolution. Native `sips` resized the source and `iconutil` packaged
the representations. `scripts/build-app.sh` copies the ICNS into the app bundle;
`Info.plist` selects it through `CFBundleIconFile`.

## Flat revision prompt

Edited the existing icon using the built-in imagegen tool:

Edit this app icon into a truly flat minimal vector-style icon. Preserve the centered rounded-square tile, white C-shaped ring and three ascending token bars, same recognizable composition and transparent outer margin. Replace every glossy material, gradient, bevel, rim, highlight, texture and shadow with completely uniform solid fills. Tile solid restrained cobalt blue #3157D5; C solid white; three bars one uniform light cyan #73DDEB. Crisp clean antialiased edges, smooth geometrically simple curves, no speckles or glow outside the tile. No 3D, lighting, shadows, gradients, text or additional objects. Standalone production macOS icon.
