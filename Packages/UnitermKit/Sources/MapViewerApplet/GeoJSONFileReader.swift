import Darwin
import Foundation
import GeoData
import MapKit
import SourceAccess

/// The most a GeoJSON file may hold, as the file layer's own bounds. Command layers get their own
/// caps, so the two never share a number.
struct GeoJSONLimits: Sendable, Equatable {
  /// The largest file the map reads. `MKGeoJSONDecoder` builds the whole document in memory, and
  /// it cannot stop part way, so the bound is on the bytes before the decoder sees them.
  var maxBytes = 32 << 20

  /// The most pins a file layer takes. A file past it loads its first points and says so.
  var maxPoints = 10_000
}

/// Why a GeoJSON file did not load.
enum GeoJSONFileError: Error, Equatable, Sendable, LocalizedError {
  case access(SourceAccessError)
  case tooLarge(path: String, bytes: Int, limit: Int)
  case invalid(path: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .access(let error):
      return error.errorDescription

    case .tooLarge(let path, let bytes, let limit):
      let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
      let cap = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)

      return
        "\u{201C}\(SourceAccessError.name(of: path))\u{201D} is \(size). "
        + "The map reads GeoJSON files up to \(cap), so it did not open this one."

    case .invalid(let path, let reason):
      return "\u{201C}\(SourceAccessError.name(of: path))\u{201D} is not valid GeoJSON: \(reason)"
    }
  }
}

/// Reads a GeoJSON file into a file layer, off the main thread.
///
/// The file is opened without blocking and must be a regular file, so a pipe or a device never
/// stalls the read. Its size is checked against the bound before and during the read. Then
/// `MKGeoJSONDecoder` parses it, and the decoded objects are reduced to plain values before they
/// leave this type. Only point shapes become pins.
enum GeoJSONFileReader {
  @concurrent
  static func read(_ file: URL, limits: GeoJSONLimits = GeoJSONLimits()) async -> Result<
    GeoFileLayer, GeoJSONFileError
  > {
    readBlocking(file, limits: limits)
  }

  static func readBlocking(_ file: URL, limits: GeoJSONLimits = GeoJSONLimits()) -> Result<
    GeoFileLayer, GeoJSONFileError
  > {
    switch bytes(of: file, limit: limits.maxBytes) {
    case .failure(let error):
      return .failure(error)

    case .success(let data):
      return layer(from: data, path: file.path, limits: limits)
    }
  }

  /// Reads the file and keeps its bytes beside the layer, so the map can edit and save it.
  @concurrent
  static func readDocument(_ file: URL, limits: GeoJSONLimits = GeoJSONLimits()) async -> Result<
    (layer: GeoFileLayer, bytes: Data), GeoJSONFileError
  > {
    switch bytes(of: file, limit: limits.maxBytes) {
    case .failure(let error):
      return .failure(error)

    case .success(let data):
      return layer(from: data, path: file.path, limits: limits).map { ($0, data) }
    }
  }

  /// Builds the layer for bytes the map already holds, such as an edited document, off the main
  /// thread.
  @concurrent
  static func layer(of data: Data, path: String, limits: GeoJSONLimits = GeoJSONLimits()) async
    -> Result<GeoFileLayer, GeoJSONFileError>
  {
    layer(from: data, path: path, limits: limits)
  }

  /// Decodes `data` and builds the layer. The fuzzer calls this to run the decoder as shipped.
  static func layer(from data: Data, path: String, limits: GeoJSONLimits) -> Result<
    GeoFileLayer, GeoJSONFileError
  > {
    let objects: [MKGeoJSONObject]

    do {
      objects = try MKGeoJSONDecoder().decode(data)
    } catch {
      let reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)

      return .failure(.invalid(path: path, reason: reason.isEmpty ? "it does not parse." : reason))
    }

    var builder = GeoFileLayerBuilder(maxPoints: limits.maxPoints)

    for object in objects {
      builder.add(
        feature(from: object, room: builder.remaining + 1, wantsProperties: !builder.isFull))
    }

    return .success(builder.layer)
  }

  private static func bytes(of file: URL, limit: Int) -> Result<Data, GeoJSONFileError> {
    switch RegularFile.readAll(path: file.path, limit: limit) {
    case .success(let data):
      return .success(data)

    case .failure(.access(let error)):
      return .failure(.access(error))

    case .failure(.tooLarge(let path, let bytes, let limit)):
      return .failure(.tooLarge(path: path, bytes: bytes, limit: limit))
    }
  }

  /// The plain values of one decoded object. At most `room` points are copied, one more than the
  /// layer takes, so the builder can tell a file that ends at the bound from one that passes it.
  /// Properties are skipped once the layer is full, since no pin will use them.
  private static func feature(from object: MKGeoJSONObject, room: Int, wantsProperties: Bool)
    -> GeoFeatureInput
  {
    var properties: Data?
    var shapes: [MKShape] = []

    if let feature = object as? MKGeoJSONFeature {
      properties = wantsProperties ? feature.properties : nil
      shapes = feature.geometry
    } else if let shape = object as? MKShape {
      shapes = [shape]
    }

    var points: [GeoCoordinate] = []
    var skipped = shapes.isEmpty ? 1 : 0

    for shape in shapes {
      if shape is MKPolyline || shape is MKPolygon {
        skipped += 1
      } else if let point = shape as? MKPointAnnotation {
        if points.count < room {
          points.append(
            GeoCoordinate(
              latitude: point.coordinate.latitude, longitude: point.coordinate.longitude))
        }
      } else if let multi = shape as? MKMultiPoint {
        let count = min(multi.pointCount, max(0, room - points.count))
        var coordinates = [CLLocationCoordinate2D](
          repeating: CLLocationCoordinate2D(), count: count)

        if count > 0 {
          coordinates.withUnsafeMutableBufferPointer {
            multi.getCoordinates($0.baseAddress!, range: NSRange(location: 0, length: count))
          }
        }

        points += coordinates.map {
          GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
      } else {
        skipped += 1
      }
    }

    return GeoFeatureInput(propertiesJSON: properties, points: points, skippedShapes: skipped)
  }
}
