import Foundation

/// The frames a stream sent since its last snapshot, kept on disk so the next open can show them at once,
/// before the host answers. The live snapshot that follows replaces what they built. Writes are coalesced
/// and capped; a cache that fails to read is just empty.
public final class FrameCache: @unchecked Sendable {
  private let url: URL
  private let lock = NSLock()
  private var frames: [JSONValue] = []
  private var bytes = 0
  private var dirty = false
  private var scheduled = false
  /// Past this, the oldest frames after the snapshot go first.
  private let maxBytes: Int

  public init(name: String, maxBytes: Int = 3 * 1024 * 1024) {
    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("orca-streams", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
    url = folder.appendingPathComponent(String(safe) + ".json")
    self.maxBytes = maxBytes
  }

  /// What the last session left, oldest first.
  public func load() -> [JSONValue] {
    guard let data = try? Data(contentsOf: url),
      let frames = try? JSONDecoder().decode([JSONValue].self, from: data)
    else { return [] }
    return frames
  }

  /// Records a frame: a snapshot starts the record over, anything else adds to it.
  public func record(_ frame: JSONValue, isSnapshot: Bool) {
    lock.lock()
    let size = frame.serialized().utf8.count
    if isSnapshot {
      frames = [frame]
      bytes = size
    } else {
      frames.append(frame)
      bytes += size
      // Keep the snapshot; drop the oldest updates after it when over budget.
      while bytes > maxBytes, frames.count > 2 {
        bytes -= frames.remove(at: 1).serialized().utf8.count
      }
    }
    dirty = true
    let schedule = !scheduled
    scheduled = true
    lock.unlock()
    if schedule {
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in self?.flush() }
    }
  }

  private func flush() {
    lock.lock()
    let snapshot = dirty ? frames : nil
    dirty = false
    scheduled = false
    lock.unlock()
    guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
    try? data.write(to: url, options: .atomic)
  }
}
