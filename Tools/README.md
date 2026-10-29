# DMG artwork and layout

`layout-dmg.applescript` configures only the mounted installer window. Its
640×420 point content area contains 104-point icons centered at (170, 210)
and (470, 210). Finder saves these settings in the volume's `.DS_Store`.
The build applies the layout on a writable image before creating the final
compressed, read-only image; there is no Finder automation during installation.
`verify-dmg-layout.applescript` reopens the final read-only image and checks the
saved window dimensions, icon positions, and view options during the build.

`render-dmg-background.swift` draws the bilingual instructions and connecting
arrow using AppKit. Regenerate the checked-in Retina TIFF with:

```sh
xcrun swift Tools/render-dmg-background.swift Assets/installer/background.tiff
```

The background is original project artwork. It contains no user or account data.
