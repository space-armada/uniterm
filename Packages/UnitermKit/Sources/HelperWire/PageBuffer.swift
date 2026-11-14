import Darwin
import Foundation

/// Zero-filled buffers for bitmaps and the messages that carry them.
///
/// A buffer this large comes from the kernel in whole pages and goes back to it when the last
/// reference ends. The allocator keeps a freed block of this size for reuse and counts it against
/// the process, which would hold a bitmap that was already sent in the helper's footprint, and a
/// tile the app dropped in the app's.
public enum PageBuffer {
  /// Smaller buffers use the allocator, where a cache costs little.
  public static let threshold = 256 * 1024

  public static func data(count: Int) -> Data {
    guard count >= threshold else { return Data(count: count) }

    guard let base = mmap(nil, count, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
      base != MAP_FAILED
    else { return Data(count: count) }

    return Data(bytesNoCopy: base, count: count, deallocator: .unmap)
  }
}
