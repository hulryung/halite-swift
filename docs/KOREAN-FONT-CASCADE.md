# Korean font cascade handling

damson renders via NSTextView + NSAttributedString (a design requirement of the
DamsonTerminal package for cmux integration). macOS's system font fallback chain
handles *language* glyphs (Hangul/Hanzi, etc.) automatically, but the automatic
fallback doesn't always land on the Korean font we want. The fallback priority
also varies subtly across macOS versions, which can cause line height differences.

→ `fontWithNerdFallback(family:size:)` in `Sources/DamsonTerminal/FontCascade.swift`
   is called at every font creation point and **explicitly** pins the Korean
   fallback into the NSFontDescriptor's `cascadeList`.

## Cascade order

```
1. Primary           = the font the user picked in Settings → Font → Family
                       (default: Menlo)
2. Nerd Font         = any one Nerd Font Mono installed on the system — for
                       Powerline glyphs (PUA U+E0A0+). Skipped if the primary
                       is already a Nerd Font.
3. Korean monospace  = tried in the order below, first installed one wins:
                         - D2Coding
                         - D2CodingLigature
                         - D2Coding Nerd Font Mono
                         - D2Coding Nerd Font
                         - D2CodingLigature Nerd Font Mono
                         - D2CodingLigature Nerd Font
                         - NanumGothicCoding
4. Apple SD Gothic Neo = only if none of 3. is installed. Present on every macOS
                         system. Not monospace, though, so Hangul glyph widths
                         may vary slightly.
```

## Why D2Coding first

| Aspect | D2Coding | Apple SD Gothic Neo |
|---|---|---|
| **monospace** | ✅ Uniform Hangul glyph width. Aligns exactly to the cell grid | ❌ Proportional. Width varies slightly per Hangul glyph |
| **Developer readability** | ✅ The Korean developer standard. Designed for coding by NHN/Naver | ❌ A UI/document font |
| **Free + installation** | ⚠️ Requires separate install (most Korean developers already have it) | ✅ Ships with macOS |

Because D2Coding is monospace, it matches the terminal's cell grid → alignment
doesn't drift when mixing Korean and English. Most Korean developers already have
it installed, so putting it at the top of the fallback order is the sensible
choice. On systems without it, Apple SD Gothic Neo serves as a minimal safety net.

## Variant names

D2Coding has many variants. The names explicitly enumerated (the `koreanMono` array):

| Name | Description |
|---|---|
| `D2Coding` | Base |
| `D2CodingLigature` | Includes coding ligatures (==, !=, =>) |
| `D2Coding Nerd Font` | Nerd Font patch (includes Powerline glyphs) |
| `D2Coding Nerd Font Mono` | + forced single-cell width (guarantees glyph alignment) |
| `D2CodingLigature Nerd Font` | Ligature + Nerd Font |
| `D2CodingLigature Nerd Font Mono` | Ligature + Nerd Font + single-cell width |
| `NanumGothicCoding` | Naver's previous-generation Korean coding font |

The **first hit** among installed fonts is selected. Even if the user's system has
multiple variants, only one goes into the cascade.

## Caveats when adding / changing

`fontWithNerdFallback` is called from three places in DamsonSurfaceView:

- `init` (initial window creation)
- `applyConfig` (hot-reload on font change in Settings)
- `setZoom` (Cmd+= / - / 0)

Any new font creation path must go through this helper to keep the Korean cascade
intact. Calling `NSFont(name:size:)` directly skips the fallback, causing a
regression where Hangul is drawn in a different font after a font change.

## Future candidates

- Add a picker so users can choose the Korean fallback font themselves in Settings
  (D2Coding / Nanum / SD Gothic Neo / Pretendard Mono / ...)
- Dedicated fallbacks for Hanzi / Japanese (Hiragana/Katakana) can be added with
  the same pattern
