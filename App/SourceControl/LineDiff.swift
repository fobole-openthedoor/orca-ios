import Foundation

/// A line-by-line diff of two texts (Myers), cut into rows the diff screen shows: changes with three lines of
/// context around them, and the unchanged runs between folded away until tapped.
enum LineDiff {
  struct Line: Equatable {
    enum Kind { case context, added, removed }
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
  }

  enum Row: Equatable {
    case line(Line)
    /// Unchanged lines kept out of view; `lines` are what tapping it shows.
    case fold([Line])
  }

  static let context = 3

  static func lines(of text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
  }

  /// Every line of both sides, in order.
  static func diff(original: String, modified: String) -> [Line] {
    let a = lines(of: original)
    let b = lines(of: modified)
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
      suffix += 1
    }
    var ids: [String: Int] = [:]
    func id(_ line: String) -> Int {
      if let existing = ids[line] { return existing }
      ids[line] = ids.count
      return ids.count - 1
    }
    let middleA = a[prefix..<(a.count - suffix)].map(id)
    let middleB = b[prefix..<(b.count - suffix)].map(id)

    var out: [Line] = []
    for i in 0..<prefix { out.append(Line(kind: .context, oldNumber: i + 1, newNumber: i + 1, text: a[i])) }
    let ops = myers(middleA, middleB, maxEdits: 2000) ?? fallback(middleA.count, middleB.count)
    for op in ops {
      switch op {
      case .equal(let i, let j):
        out.append(Line(kind: .context, oldNumber: prefix + i + 1, newNumber: prefix + j + 1, text: a[prefix + i]))
      case .delete(let i):
        out.append(Line(kind: .removed, oldNumber: prefix + i + 1, newNumber: nil, text: a[prefix + i]))
      case .insert(let j):
        out.append(Line(kind: .added, oldNumber: nil, newNumber: prefix + j + 1, text: b[prefix + j]))
      }
    }
    for s in stride(from: suffix, to: 0, by: -1) {
      let i = a.count - s
      let j = b.count - s
      out.append(Line(kind: .context, oldNumber: i + 1, newNumber: j + 1, text: a[i]))
    }
    return out
  }

  /// Rows with unchanged runs longer than the context folded.
  static func rows(_ lines: [Line]) -> [Row] {
    var rows: [Row] = []
    var index = 0
    while index < lines.count {
      guard lines[index].kind == .context else {
        rows.append(.line(lines[index]))
        index += 1
        continue
      }
      var end = index
      while end < lines.count, lines[end].kind == .context { end += 1 }
      let run = Array(lines[index..<end])
      let keepBefore = index == 0 ? 0 : context
      let keepAfter = end == lines.count ? 0 : context
      if run.count > keepBefore + keepAfter + 1 {
        rows += run.prefix(keepBefore).map(Row.line)
        rows.append(.fold(Array(run.dropFirst(keepBefore).dropLast(keepAfter))))
        rows += run.suffix(keepAfter).map(Row.line)
      } else {
        rows += run.map(Row.line)
      }
      index = end
    }
    return rows
  }

  private enum Op {
    case equal(Int, Int), delete(Int), insert(Int)
  }

  private static func fallback(_ n: Int, _ m: Int) -> [Op] {
    (0..<n).map(Op.delete) + (0..<m).map(Op.insert)
  }

  /// Myers' O(ND) diff; nil when it needs more than `maxEdits` edits, which the caller shows as replaced wholesale.
  private static func myers(_ a: [Int], _ b: [Int], maxEdits: Int) -> [Op]? {
    let n = a.count
    let m = b.count
    if n == 0 || m == 0 { return fallback(n, m) }
    let max = n + m
    let offset = max + 1
    var v = [Int](repeating: 0, count: 2 * max + 3)
    // trace[d] holds v[-d...d] as it stood before step d.
    var trace: [[Int]] = []
    var found = false
    outer: for d in 0...min(max, maxEdits) {
      trace.append(Array(v[(offset - d)...(offset + d)]))
      for k in stride(from: -d, through: d, by: 2) {
        var x =
          (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
        var y = x - k
        while x < n, y < m, a[x] == b[y] {
          x += 1
          y += 1
        }
        v[offset + k] = x
        if x >= n, y >= m {
          found = true
          break outer
        }
      }
    }
    guard found else { return nil }

    var ops: [Op] = []
    var x = n
    var y = m
    for d in stride(from: trace.count - 1, through: 0, by: -1) {
      if d == 0 {
        while x > 0, y > 0 {
          ops.append(.equal(x - 1, y - 1))
          x -= 1
          y -= 1
        }
        break
      }
      let previous = trace[d]
      func at(_ k: Int) -> Int { previous[k + d] }
      let k = x - y
      let previousK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1
      let previousX = at(previousK)
      let previousY = previousX - previousK
      while x > previousX, y > previousY {
        ops.append(.equal(x - 1, y - 1))
        x -= 1
        y -= 1
      }
      ops.append(x == previousX ? .insert(y - 1) : .delete(x - 1))
      x = previousX
      y = previousY
    }
    return ops.reversed()
  }
}
