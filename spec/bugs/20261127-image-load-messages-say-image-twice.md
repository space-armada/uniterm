# The image viewer's load messages say "image" twice

**Status:** open

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
