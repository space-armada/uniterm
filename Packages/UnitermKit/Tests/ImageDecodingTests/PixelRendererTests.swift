import CoreGraphics
import CoreImage
import ImageIO
import ImageTestSupport
import ImageWire
import UniformTypeIdentifiers
import XCTest

@testable import ImageDecoding

/// Decodes generated files through the helper's own code, in process. Each test names a contract
/// of what the viewer shows: the size, the orientation, the color space, and the animation.
final class PixelRendererTests: XCTestCase {
  private func open(_ data: Data, sourceID: UInt32 = 1) throws -> OpenedImage {
    let path = NSTemporaryDirectory() + "uniterm-decode-\(UUID().uuidString)"
    try data.write(to: URL(fileURLWithPath: path))
    defer { unlink(path) }

    let descriptor = Darwin.open(path, O_RDONLY)

    return try OpenedImage(mapping: try FileMapping(descriptor: descriptor), sourceID: sourceID)
  }

  private func pixel(_ image: RenderedImage, _ x: Int, _ y: Int) -> [UInt8] {
    let at = (y * image.width + x) * 4

    return Array(image.pixels[at..<at + 4])
  }

  private func assertColor(
    _ actual: [UInt8], near expected: ImageFixtures.Pixel, tolerance: Int = 40,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line
  ) {
    let wanted = [expected.r, expected.g, expected.b]

    for (got, want) in zip(actual.prefix(3), wanted) {
      XCTAssertLessThanOrEqual(
        abs(Int(got) - Int(want)), tolerance, message, file: file, line: line)
    }
  }

  /// Catches a decode that ignores the requested size. A 400 by 200 image asked for at 100 pixels
  /// comes back 100 by 50, so the app holds a bitmap the size of the pane and not of the file.
  func testADecodeIsDownsampledToTheRequestedSize() throws {
    let source = try open(ImageFixtures.png(width: 400, height: 200))
    let image = try PixelRenderer.render(source, frame: 0, maxPixel: 100)

    XCTAssertEqual(source.info.width, 400)
    XCTAssertEqual(image.width, 100)
    XCTAssertEqual(image.height, 50)
    XCTAssertEqual(image.pixels.count, 100 * 50 * 4)
    XCTAssertEqual(image.space, .sRGB)
  }

  /// Catches a decode that enlarges a small image. Asking for more pixels than the file has
  /// returns the native size, so the app never pays for pixels that add no detail.
  func testARequestPastTheNativeSizeReturnsTheNativeSize() throws {
    let source = try open(ImageFixtures.png(width: 64, height: 32))
    let image = try PixelRenderer.render(source, frame: 0, maxPixel: 4096)
    let native = try PixelRenderer.render(source, frame: 0, maxPixel: 0)

    XCTAssertEqual([image.width, image.height], [64, 32])
    XCTAssertEqual([native.width, native.height], [64, 32])
  }

  /// Catches EXIF orientation being ignored or applied the wrong way. A 16 by 8 picture stored with
  /// orientation 6 shows 8 wide and 16 tall, with its blue corner on top left and its red corner on
  /// top right. The corners of the fixture are told apart by color.
  func testExifOrientationIsAppliedBeforeTheSizeIsReported() throws {
    let data = ImageFixtures.encode(
      ImageFixtures.quadrants(width: 16, height: 8), as: .jpeg,
      properties: [
        kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 1.0,
      ])

    let source = try open(data)

    XCTAssertEqual([source.info.width, source.info.height], [8, 16])

    let image = try PixelRenderer.render(source, frame: 0, maxPixel: 0)

    XCTAssertEqual([image.width, image.height], [8, 16])
    assertColor(pixel(image, 1, 1), near: ImageFixtures.blue, "top left")
    assertColor(pixel(image, 6, 1), near: ImageFixtures.red, "top right")
    assertColor(pixel(image, 6, 14), near: ImageFixtures.green, "bottom right")
    assertColor(pixel(image, 1, 14), near: ImageFixtures.white, "bottom left")
  }

  /// Catches the whole-image decode path, which a gain-map HDR image takes, ignoring EXIF
  /// orientation. ImageIO applies the orientation only when it makes a thumbnail, so this path must
  /// apply it by drawing. For each of the eight orientations the corners and the size must match
  /// what the thumbnail path produces, both unscaled and scaled down. A portrait photo with a
  /// gain map would otherwise report swapped dimensions and be refused as larger than asked for.
  func testTheWholeImageDecodePathAppliesEveryOrientation() throws {
    for orientation in 1...8 {
      let data = ImageFixtures.encode(
        ImageFixtures.quadrants(width: 32, height: 16), as: .jpeg,
        properties: [
          kCGImagePropertyOrientation: orientation,
          kCGImageDestinationLossyCompressionQuality: 1.0,
        ])

      let source = try open(data)

      for maxPixel in [0, 16] {
        let expected = try PixelRenderer.render(source, frame: 0, maxPixel: maxPixel)
        let actual = try PixelRenderer.render(
          source, frame: 0, maxPixel: maxPixel, fullDecode: true)
        let context = "orientation \(orientation), max \(maxPixel)"

        XCTAssertEqual([actual.width, actual.height], [expected.width, expected.height], context)
        if maxPixel == 0 {
          XCTAssertEqual(
            [actual.width, actual.height], [Int(source.info.width), Int(source.info.height)],
            context)
        }

        let corners = [
          (1, 1), (actual.width - 2, 1), (1, actual.height - 2),
          (actual.width - 2, actual.height - 2),
        ]

        for (x, y) in corners {
          XCTAssertEqual(
            lit(actual, x, y), lit(expected, x, y), "\(context) at \(x),\(y)")
        }
      }
    }
  }

  /// Which of red, green, and blue are bright at a pixel, whatever the pixel format.
  private func lit(_ image: RenderedImage, _ x: Int, _ y: Int) -> [Bool] {
    let size = image.space.format.bytesPerPixel
    let at = (y * image.width + x) * size

    return (0..<3).map { channel in
      switch image.space.format {
      case .rgba8:
        return image.pixels[at + channel] > 127

      case .rgbaF16:
        let value = image.pixels.withUnsafeBytes {
          $0.loadUnaligned(fromByteOffset: at + channel * 2, as: Float16.self)
        }

        return value > 0.5
      }
    }
  }

  /// Catches a Display P3 image being converted to sRGB. Values that only P3 can show stay in P3,
  /// so the viewer shows the same color Preview does. The green here is inside P3 and outside sRGB.
  func testADisplayP3ImageStaysInDisplayP3() throws {
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let picture = ImageFixtures.bitmap(width: 8, height: 8, space: p3) { _, _ in (51, 204, 77, 255)
    }
    let source = try open(ImageFixtures.encode(picture, as: .png))
    let image = try PixelRenderer.render(source, frame: 0, maxPixel: 0)

    XCTAssertEqual(image.space, .displayP3)
    XCTAssertEqual(Array(pixel(image, 4, 4).prefix(3)), [51, 204, 77])
  }

  /// Catches an sRGB image being sent in a wider space, which would cost the app nothing visible
  /// and would hide a mix-up of the two.
  func testAnSRGBImageStaysInSRGB() throws {
    let source = try open(ImageFixtures.png())
    let image = try PixelRenderer.render(source, frame: 0, maxPixel: 0)

    XCTAssertEqual(image.space, .sRGB)
  }

  /// Catches the output space mapping drifting. The color spaces named here are the ones ImageIO
  /// reports for HDR content, and each must land in the extended-range space, while ordinary wide
  /// gamut lands in Display P3.
  func testOutputSpacesFollowTheSourceSpace() {
    XCTAssertEqual(
      PixelRenderer.outputSpace(for: CGColorSpace(name: CGColorSpace.itur_2100_PQ), hdr: false),
      .extendedLinearDisplayP3)
    XCTAssertEqual(
      PixelRenderer.outputSpace(for: CGColorSpace(name: CGColorSpace.itur_2100_HLG), hdr: false),
      .extendedLinearDisplayP3)
    XCTAssertEqual(
      PixelRenderer.outputSpace(for: CGColorSpace(name: CGColorSpace.extendedSRGB), hdr: false),
      .extendedLinearDisplayP3)
    XCTAssertEqual(
      PixelRenderer.outputSpace(for: CGColorSpace(name: CGColorSpace.adobeRGB1998), hdr: false),
      .displayP3)
    XCTAssertEqual(
      PixelRenderer.outputSpace(
        for: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2), hdr: false),
      .sRGB)
    XCTAssertEqual(PixelRenderer.outputSpace(for: nil, hdr: false), .sRGB)
    XCTAssertEqual(
      PixelRenderer.outputSpace(for: CGColorSpace(name: CGColorSpace.sRGB), hdr: true),
      .extendedLinearDisplayP3)
  }

  /// Catches HDR values being clipped to one on the way into the extended space. A pixel brighter
  /// than white in extended linear sRGB must come out brighter than 1.0 in half-float pixels.
  func testHDRValuesAboveWhiteSurviveInHalfFloat() throws {
    let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    var floats = [Float16](repeating: 0, count: 4 * 4 * 4)

    for index in stride(from: 0, to: floats.count, by: 4) {
      floats[index] = 3.0
      floats[index + 1] = 3.0
      floats[index + 2] = 3.0
      floats[index + 3] = 1.0
    }

    let data = floats.withUnsafeBytes { Data($0) }
    let picture = CGImage(
      width: 4, height: 4, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 32, space: space,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder16Little.rawValue | CGBitmapInfo.floatComponents.rawValue),
      provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent)!

    let image = try PixelRenderer.draw(
      picture, width: 4, height: 4, space: .extendedLinearDisplayP3)

    XCTAssertEqual(image.pixels.count, 4 * 4 * 8)

    let red = image.pixels.withUnsafeBytes { $0.loadUnaligned(as: Float16.self) }

    XCTAssertGreaterThan(red, 1.5)
  }

  /// Catches an ISO 21496-1 gain map being treated as plain SDR. CoreImage writes that format when
  /// given an HDR image beside the SDR one. The source must report a gain map, and its decode must
  /// carry values above white into the half-float pixels. The file is made here from flat colors.
  func testAnISOGainMapDecodesAsHDR() throws {
    let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
    let sdr = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
    let hdr = CIImage(
      color: CIColor(
        red: 4, green: 4, blue: 4, alpha: 1,
        colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!
    ).cropped(to: extent)

    let data = try XCTUnwrap(
      CIContext().heifRepresentation(
        of: sdr, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        options: [.hdrImage: hdr]))

    let source = try open(data)

    XCTAssertTrue(source.hasGainMap, "the ISO gain map was not noticed")

    let image = try PixelRenderer.render(source, frame: 0, maxPixel: 0)
    let samples = image.pixels.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
    let brightest = samples.enumerated().filter { $0.offset % 4 != 3 }.map(\.element).max() ?? 0

    XCTAssertEqual(image.space, .extendedLinearDisplayP3)
    XCTAssertGreaterThan(brightest, 1.5, "highlights stopped at SDR white")
  }

  /// Catches an animation that reports one frame, loses its delays, or decodes the wrong frame.
  /// The GIF has three solid frames with different delays.
  func testAnAnimatedImageReportsItsFramesAndDecodesEachOne() throws {
    let data = ImageFixtures.animatedGIF(
      colors: [ImageFixtures.red, ImageFixtures.green, ImageFixtures.blue],
      delays: [0.1, 0.2, 0.3])

    let source = try open(data)

    XCTAssertEqual(source.info.frameDelays, [100, 200, 300])

    assertColor(
      pixel(try PixelRenderer.render(source, frame: 0, maxPixel: 0), 2, 2), near: ImageFixtures.red)
    assertColor(
      pixel(try PixelRenderer.render(source, frame: 2, maxPixel: 0), 2, 2), near: ImageFixtures.blue
    )
  }

  /// Catches a still image being reported as animated, which would start a player for nothing.
  func testAStillImageReportsOneFrame() throws {
    XCTAssertEqual(try open(ImageFixtures.png()).info.frameCount, 1)
  }

  /// Catches bytes that are not an image being decoded, or reported with a message that does not
  /// say what happened. Random bytes are unsupported, and a damaged PNG names its format.
  func testNonImagesAndDamagedImagesFailWithAMessageNamingTheFormat() throws {
    XCTAssertThrowsError(try open(Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 31) }))) {
      XCTAssertEqual(($0 as? SourceFailure)?.kind, .unsupported)
    }

    let png = ImageFixtures.png()
    let damaged = png.prefix(png.count / 3)

    do {
      let source = try open(Data(damaged))

      XCTAssertThrowsError(try PixelRenderer.render(source, frame: 0, maxPixel: 0)) {
        XCTAssertTrue(($0 as? SourceFailure)?.text.contains("PNG") ?? false, "\($0)")
      }
    } catch let error as SourceFailure {
      XCTAssertTrue(error.text.contains("PNG"), error.text)
    }
  }

  /// Catches a descriptor that is not a regular file being mapped. The helper re-checks what the
  /// app already checked, since it trusts the app no more than the app trusts it.
  func testAHelperRefusesADescriptorThatIsNotARegularFile() {
    let pipe = Pipe()

    XCTAssertThrowsError(
      try FileMapping(descriptor: dup(pipe.fileHandleForReading.fileDescriptor)))
  }
}
