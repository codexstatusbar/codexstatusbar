# App icon

Generated with the built-in imagegen tool on 2026-10-17. `AppIcon.png` is the
transparent source; `AppIcon.icns` contains 16, 32, 128, 256 and 512 point images
at 1x and 2x resolution. Native `sips` resized the source and `iconutil` packaged
the representations. `scripts/build-app.sh` copies the ICNS into the app bundle;
`Info.plist` selects it through `CFBundleIconFile`.

## Generation prompt

Use case: logo-brand. Create one production macOS app icon for Codex Hub, a developer tool monitoring token throughput. Square 1024 by 1024 canvas, transparent outside a generously rounded-square blue glass tile occupying 88 percent of canvas, centered straight-on. A single bold luminous white abstract C-shaped ring wrapping three ascending cyan token bars, simple recognizable silhouette at 32px, generous internal spacing. Polished restrained macOS liquid-glass material, deep cobalt and soft indigo, subtle upper-left rim highlight, gentle depth, crisp edges. No words, letters rendered as text, numbers, watermark, mockup, scene, extra icons, or OpenAI knot logo. Final standalone icon asset.
