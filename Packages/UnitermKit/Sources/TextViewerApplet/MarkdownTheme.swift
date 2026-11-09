import Theme

/// The CSS variables the Markdown page reads, generated from the palette the host pushes through
/// `apply(_:)`. The page sets them with the CSS object model, which the page's policy does not
/// govern, so no inline style is needed.
enum MarkdownTheme {
  static func variables(for palette: ThemePalette) -> [String: String] {
    [
      "--um-background": palette[.base].hexString,
      "--um-surface": palette[.mantle].hexString,
      "--um-text": palette[.text].hexString,
      "--um-muted": palette.secondaryText.hexString,
      "--um-border": palette[.surface1].hexString,
      "--um-link": palette[.blue].hexString,
      "--um-mark": palette[.yellow].hexString,
      "--um-code": palette[.red].hexString,
    ]
  }

  static func payload(for palette: ThemePalette) -> [String: Any] {
    ["variables": variables(for: palette), "dark": palette.flavor.isDark]
  }
}
