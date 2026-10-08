# Third-party assets

Bundled by `Sources/AgentreDesign/Resources/`; the license texts live here, outside every build target.

| Asset | Files | Source | License |
|---|---|---|---|
| Inter 4.1 | `Fonts.xcassets/Inter-{Regular,Medium,SemiBold,Bold}` | https://github.com/rsms/inter/releases/tag/v4.1 (`extras/ttf/`) | SIL OFL 1.1 — `Inter-OFL-1.1.txt` |
| JetBrains Mono 2.304 | `Fonts.xcassets/JetBrainsMono-{Regular,SemiBold}` | https://github.com/JetBrains/JetBrainsMono/releases/tag/v2.304 (`fonts/ttf/`) | SIL OFL 1.1 — `JetBrainsMono-OFL-1.1.txt` |
| Lucide icons | `Icons.xcassets/*` except `github` | npm `lucide-static@1.48.0` (`icons/`) | ISC — `lucide-static-1.48.0-ISC.txt` |
| Lucide `github` icon | `Icons.xcassets/github` | npm `lucide-static@0.577.0` (`icons/`); brand icons were removed in 1.0 | ISC — `lucide-static-0.577.0-ISC.txt` |

The icon SVGs are unmodified except `stroke="currentColor"` → `#000000`: the asset catalog renders them as template images, so the stroke color is replaced by the tint at draw time.
