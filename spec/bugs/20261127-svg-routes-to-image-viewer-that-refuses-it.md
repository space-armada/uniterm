# An SVG file opens in the image viewer, which refuses it as not an image

**Status:** open
**Validation:** not confirmed in the running app. The code path was traced, and a probe showed ImageIO lists no SVG type.

## Observed

The user opens a `.svg` file with File > Open, a drop, or Finder's Open With. uniterm routes it to the image viewer. The
image viewer then refuses it as not an image. No applet in uniterm shows a bare SVG file.

A script that runs `uniterm/send` with a name ending in `.svg` to an image viewer pane gets the same refusal.

## Cause

- `public.svg-image` conforms to `public.image`.
- The image viewer claims `public.image` at owner rank in
  `Packages/UnitermKit/Sources/ImageViewerApplet/ImageViewerCommands.swift`. `App/Info.plist` declares the same type for
  Finder. No other applet claims SVG, so the router picks the image viewer.
- The viewer checks the file against `SupportedImageTypes` in
  `Packages/UnitermKit/Sources/ImageViewerModel/SourceLoader.swift` before it decodes. That list comes from
  `CGImageSourceCopyTypeIdentifiers()` in the decoder helper. ImageIO lists no SVG type, so the check fails with
  `notAnImage`.

The router claims a type that the viewer cannot open.

## Repro

1. Write a small valid SVG file named `d.svg`.
2. Open it in uniterm with File > Open.
3. Expected: the drawing shows, or uniterm says up front that no applet opens SVG. Actual: an image viewer pane opens and
   reports that the file is not an image.

## Fix

This needs a design call. The options:

- The image viewer decodes SVG in its sandboxed helper. `NSImage(data:)` decodes SVG in a plain process. Whether it
  works inside the helper's sandbox is not checked. External references in the SVG must load nothing.
- The text viewer owns SVG and shows it as an `<img>` in its WebKit view, as it already does for an SVG that Markdown
  embeds.
- The image viewer narrows its claim to the types its helper lists, so uniterm no longer routes SVG anywhere.

UTERM-010's review asks which applet shows a program-sent SVG. Its answer settles this bug too.

## Workarounds

Embed the SVG in a Markdown file next to it, as `![](d.svg)`, and open the Markdown file in the text viewer.
