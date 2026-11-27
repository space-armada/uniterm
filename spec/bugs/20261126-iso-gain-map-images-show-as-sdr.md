# An image with an ISO 21496-1 gain map shows as SDR in the image viewer

**Status:** open
**Validation:** not confirmed in the running app; traced in the code, and ImageIO decodes the fixture to 4.0× when asked for HDR

**Estimate:** small; no open design decisions.

## Observed

UTERM-006 M1's As built says "The HDR path decodes a source that carries a gain map or an HDR color space into
extended-linear Display P3 half-float pixels." An image whose gain map uses the ISO 21496-1 format does not take that
path. It shows with SDR highlights. CoreImage writes this format when asked for an HDR HEIC, and current cameras and
editors produce it too. Apple's older gain-map format still takes the HDR path.

## Cause

`Packages/UnitermKit/Sources/ImageDecoding/OpenedImage.swift:57-59` sets `hasGainMap` only when
`CGImageSourceCopyAuxiliaryDataInfoAtIndex` finds `kCGImageAuxiliaryDataTypeHDRGainMap`. It never asks for
`kCGImageAuxiliaryDataTypeISOGainMap`.

`PixelRenderer.swift:68` picks the HDR decode only when `hasGainMap` is true. Any other source goes through
`CGImageSourceCreateThumbnailAtIndex` without `kCGImageSourceDecodeToHDR`, so the gain map is never applied.

## Repro

1. Make a HEIC with an ISO gain map, such as with CoreImage's `.hdrImage` write option. The hand-check bundle's
   `fixtures/uterm-006/hdr-gain-map-iso.heic` is one, built by `make-images.swift` beside it.
2. Open it in uniterm's image viewer and in Preview, side by side, on an HDR display.
3. Expected: uniterm's highlights go above SDR white, as Preview's do. Actual, by the code: they stop at SDR white.

## Fix

Also check for `kCGImageAuxiliaryDataTypeISOGainMap` when setting `hasGainMap`. Add a decode test with a real ISO
gain-map file that checks values above 1.0 survive. Keep that file synthetic, made by the generator above. The
existing tests decode no real gain-map file of either kind, so add one for Apple's format too.
