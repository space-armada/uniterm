# The image viewer's load messages say "image" twice

**Status:** fixed 2026-11-27
**Fixed:** 2026-11-27
**Estimate:** small; no open design decisions. Make `formatName` a short name with no noun, since it is used only in
these three messages and a type that falls back to its extension would read badly with the noun dropped instead.

## Observed

A PNG with a valid signature and garbage after it shows "This PNG image image has no usable size." in the pane and the
status bar. The word "image" appears twice.

## Cause

`UTType.formatName` in `Packages/UnitermKit/Sources/ImageDecoding/SourceFile.swift` returns `localizedDescription`
first. For PNG that reads "PNG image", so the name already carries the word. Three messages append "image" after it:

- `OpenedImage.swift`: "This \(formatName) image is damaged and cannot be shown."
- `OpenedImage.swift`: "This \(formatName) image has no usable size."
- `PixelRenderer.swift`: "This \(image.formatName) image could not be decoded."

Only the "no usable size" message was seen on screen. The other two use the same name and the same wording around it.
Whether every type's `localizedDescription` ends in "image" was not checked. The fallbacks, the uppercased extension and
the identifier, do not.

## Repro

1. Write a file named `broken.png` that holds the eight PNG signature bytes and 64 bytes of garbage.
2. Open it in the image viewer.
3. Expected: "This PNG image has no usable size." Actual: "This PNG image image has no usable size."

Reproduced on 2026-11-27 in a package test of the image viewer, which printed the pane's message.

## Fix

Choose how the messages read once. The options are to drop the trailing "image" from the three messages, so a type with
a fallback name reads "This PNG has no usable size", or to make `formatName` return a short name with no noun, such as
the type's extension, and keep "image" in the messages. A test checks each message against a type whose description
ends in "image" and one that falls back to its extension.

## Fix note

Fixed on 2026-11-27 with the second option.

- `UTType.formatName` in `ImageDecoding/SourceFile.swift` now returns the uppercased file extension, and the identifier
  when the type has none. It no longer reads the localized description. Nothing else used the name, so only the three
  messages change. A corrupt PNG now reads "This PNG image has no usable size."
- `PixelRendererTests.testALoadFailureNamesTheFormatWithTheWordImageOnce` feeds a PNG with only its signature and a
  truncated PNG through the open and the render. It failed before the fix on "This PNG image image has no usable size."
- Not covered: both inputs reach the "no usable size" message. The "damaged" and "could not be decoded" messages share
  the fix but have no test, since no input was found that reaches them.
- The fallback to the identifier is untested.
