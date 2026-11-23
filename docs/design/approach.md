# How orca-ios looks and behaves

Two references, each for what it is good at.

## Content: the official Orca app, pixel for pixel

What a screen says and how its content is laid out comes from the official Orca mobile app
(`stablyai/orca`, `mobile/`). That covers copy, colours, type sizes, spacing, radii, icons, row
layouts, cards and states.

- Tokens are copied value for value into `App/Design/Theme.swift` from `mobile/src/theme/mobile-theme.ts`.
- Copy uses the official keys and translations. `scripts/generate-strings.mjs` builds
  `App/Resources/Localizable.xcstrings` from `mobile/src/i18n/locales`.
- Icons are the same Lucide glyphs at the same size and stroke width. `scripts/generate-lucide-icons.mjs`
  emits the ones the official app imports.
- Text is laid out with TextKit 1, configured as React Native's Fabric does on iOS (`TextLabel`), so CJK
  punctuation, wrapping and line heights match.
- Each screen is checked against a screenshot of the official app on the same simulator with
  `scripts/compare.swift`.

## Chrome and interaction: native, with Liquid Glass

The official app draws its own tab bar, header buttons, floating buttons, sheets and menus. orca-ios uses
the system's instead (iOS 26):

| Official, self-drawn | orca-ios |
| --- | --- |
| Home bottom tabs | `UITabBarController` with `UITab`; minimises on scroll |
| Screen titles and round header buttons | Navigation bar, or 44 pt `.glass()` capsule buttons on the session screen |
| Primary buttons | `.prominentGlass()` |
| Floating +, bottom search and filter bars | Toolbar items and the system search bar |
| Action sheets and long-press menus | `UIMenu` and context menus |
| Drawers | `UISheetPresentationController` |
| Composer box | A `UIGlassEffect` surface in a `UIGlassContainerEffect`, resting as a pill and opening into a card |
| Scroll-to-bottom | A glass circle above the composer |
