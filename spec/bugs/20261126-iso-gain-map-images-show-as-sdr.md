# An image with an ISO 21496-1 gain map shows as SDR in the image viewer

**Status:** fixed 2026-11-27
**Fixed:** 2026-11-27

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

## Fix note

Triage run on 2026-11-27.

- `OpenedImage` now also asks for the ISO gain map. `hasGainMap` is true for either format, so the HDR decode runs for
  both.
- The regression test `PixelRendererTests.testAnISOGainMapDecodesAsHDR` builds a HEIC from flat colors with CoreImage's
  `.hdrImage` option. It failed before the fix, because the gain map was not noticed. It passes now, and the half-float
  pixels carry values above 1.5.
- `PixelRendererTests.testAnAppleGainMapDecodesAsHDR` covers Apple's older format. It builds a JPEG with CoreImage's
  `.hdrGainMapImage` option and writes a headroom of 4 into the map's metadata, as the hand-check generator does. It
  passes on the code before and after the fix. It fails when the detection drops Apple's type.
- Files: `Packages/UnitermKit/Sources/ImageDecoding/OpenedImage.swift` and
  `Packages/UnitermKit/Tests/ImageDecodingTests/PixelRendererTests.swift`.

Corrected later on 2026-11-27. The first fix guarded the ISO check for macOS 15, and this note said an ISO image still
shows as SDR on macOS 14. Both were wrong. The package and the app target macOS 26, so the guard was dead code and is
gone. The note also said no test of Apple's format could be built. It could, and it now exists.
