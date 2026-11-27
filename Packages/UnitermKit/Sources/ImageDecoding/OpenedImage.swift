import Foundation
import ImageIO
import ImageWire
import UniformTypeIdentifiers

/// One image source the helper holds: the mapped file, ImageIO's source over it, and what the
/// header says. Every ImageIO call in the product starts here or in `PixelRenderer`.
final class OpenedImage {
  let mapping: FileMapping
  let source: CGImageSource
  let info: SourceInfo
  let formatName: String
  let hasGainMap: Bool

  /// The EXIF orientation, 1 through 8, of the stored pixels.
  let orientation: Int

  /// The most pixels along a side the helper reads from a header. A header past it is hostile.
  static let maxSourceDimension = 1 << 20

  init(mapping: FileMapping, sourceID: UInt32) throws {
    self.mapping = mapping

    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]

    guard let source = CGImageSourceCreateWithData(mapping.data as CFData, options as CFDictionary),
      let typeID = CGImageSourceGetType(source) as String?
    else {
      throw SourceFailure(kind: .unsupported, text: "uniterm cannot show this file as an image.")
    }

    let type = UTType(typeID)
    formatName = type?.formatName ?? typeID
    self.source = source

    guard CGImageSourceGetStatus(source) == .statusComplete || CGImageSourceGetCount(source) > 0
    else {
      throw SourceFailure(
        kind: .unreadable, text: "This \(formatName) image is damaged and cannot be shown.")
    }

    guard CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0, height > 0, width <= Self.maxSourceDimension, height <= Self.maxSourceDimension
    else {
      throw SourceFailure(
        kind: .unreadable, text: "This \(formatName) image has no usable size.")
    }

    let stored = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let orientation = (1...8).contains(stored) ? stored : 1
    self.orientation = orientation
    let swapped = (5...8).contains(orientation)

    hasGainMap =
      CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
      || Self.hasISOGainMap(source)

    let dpiWidth = Self.dpi(properties[kCGImagePropertyDPIWidth])
    let dpiHeight = Self.dpi(properties[kCGImagePropertyDPIHeight])

    info = SourceInfo(
      source: sourceID, width: UInt32(swapped ? height : width),
      height: UInt32(swapped ? width : height), frameDelays: Self.delays(of: source),
      dpiX: swapped ? dpiHeight : dpiWidth, dpiY: swapped ? dpiWidth : dpiHeight)

    #if DEBUG
      regionFault = Self.regionFault(in: properties)
    #endif
  }

  /// True when the first image carries a gain map in the ISO 21496-1 format. Apple's older format
  /// has its own auxiliary type, and the system names the ISO one only from macOS 15.
  private static func hasISOGainMap(_ source: CGImageSource) -> Bool {
    guard #available(macOS 15.0, *) else { return false }

    return CGImageSourceCopyAuxiliaryDataInfoAtIndex(
      source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
  }

  #if DEBUG
    /// A fault the test fixtures ask for in a PNG description, which the helper performs when a
    /// region request arrives. A file cannot carry the file-level marker and still be an image.
    let regionFault: String?

    private static func regionFault(in properties: [CFString: Any]) -> String? {
      guard let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
        let text = png[kCGImagePropertyPNGDescription] as? String,
        text.hasPrefix("UNITERM-REGION-FAULT ")
      else { return nil }

      return String(text.dropFirst("UNITERM-REGION-FAULT ".count))
    }
  #endif

  /// A declared resolution as whole dots per inch, or zero when it is missing or out of range.
  private static func dpi(_ value: Any?) -> UInt16 {
    guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, number >= 1,
      number <= Double(UInt16.max)
    else { return 0 }

    return UInt16(number.rounded())
  }

  /// The delay of each frame in milliseconds, for a source that animates. A still image, or a
  /// container with several images and no animation, reports one frame.
  private static func delays(of source: CGImageSource) -> [UInt32] {
    let count = min(CGImageSourceGetCount(source), ImageLimits.maxFrames)

    guard count > 1 else { return [0] }

    var delays: [UInt32] = []

    for index in 0..<count {
      guard
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
        let seconds = animationDelay(in: properties)
      else {
        return [0]
      }

      let milliseconds = (seconds * 1000).rounded()
      delays.append(milliseconds <= 10 ? 100 : UInt32(min(milliseconds, 60_000)))
    }

    return delays
  }

  private static func animationDelay(in properties: [CFString: Any]) -> Double? {
    let candidates: [(dictionary: CFString, unclamped: CFString, clamped: CFString)] = [
      (
        kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime,
        kCGImagePropertyGIFDelayTime
      ),
      (
        kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime,
        kCGImagePropertyAPNGDelayTime
      ),
      (
        kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime,
        kCGImagePropertyWebPDelayTime
      ),
      (
        kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime,
        kCGImagePropertyHEICSDelayTime
      ),
    ]

    for candidate in candidates {
      guard let dictionary = properties[candidate.dictionary] as? [CFString: Any] else {
        continue
      }

      if let value = (dictionary[candidate.unclamped] as? NSNumber)?.doubleValue
        ?? (dictionary[candidate.clamped] as? NSNumber)?.doubleValue
      {
        return value
      }
    }

    return nil
  }
}
