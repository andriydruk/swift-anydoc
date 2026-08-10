/// Clustering drawn rectangles into candidate tables, ported from the
/// foundation of pdf-inspector's `tables/detect_rects.rs`.
///
/// Many PDFs draw a table by stroking one `re` per cell. A page with a table
/// typically carries a hundred or more rectangles where a page without one
/// carries under thirty — but they arrive as an unordered heap, so the first
/// job is to work out which rectangles belong to the same drawing. That is a
/// connected-components problem over spatial overlap, and the reference
/// solves it with union-find.

/// Beyond this many rectangles a component is a vector illustration or a
/// page-spanning clip path, not a table. No real table has thousands of
/// cells, and the cap is what keeps a chart-heavy page from taking minutes.
private let pdfMaxClusterRects = 2000

/// Disjoint sets over rectangle indices, with component sizes so the cap
/// above can be checked without walking the group.
struct PdfUnionFind {
    private var parent: [Int]
    private var rank: [Int]
    private var size: [Int]

    init(_ count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
        size = Array(repeating: 1, count: count)
    }

    /// The representative of `x`'s set, with path compression.
    ///
    /// Iterative rather than recursive: the reference recurses, and a
    /// pathological page could otherwise drive the stack as deep as the
    /// rectangle count.
    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var current = x
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    /// Merge two sets, by rank.
    mutating func union(_ a: Int, _ b: Int) {
        let rootA = find(a)
        let rootB = find(b)
        if rootA == rootB { return }
        let merged = size[rootA] + size[rootB]
        if rank[rootA] < rank[rootB] {
            parent[rootA] = rootB
            size[rootB] = merged
        } else if rank[rootA] > rank[rootB] {
            parent[rootB] = rootA
            size[rootA] = merged
        } else {
            parent[rootB] = rootA
            size[rootA] = merged
            rank[rootA] += 1
        }
    }

    mutating func componentSize(_ x: Int) -> Int { size[find(x)] }
}

/// Whether two rectangles overlap once each is grown by `tolerance` on every
/// side.
///
/// Rectangles are `(x, y, width, height)` with the origin at the bottom left,
/// as PDF space has it. The tolerance is what lets abutting cell borders —
/// which touch rather than overlap — cluster together.
func pdfRectsOverlap(
    _ a: (x: Float, y: Float, width: Float, height: Float),
    _ b: (x: Float, y: Float, width: Float, height: Float),
    tolerance: Float
) -> Bool {
    let aLeft = a.x - tolerance
    let aRight = a.x + a.width + tolerance
    let aBottom = a.y - tolerance
    let aTop = a.y + a.height + tolerance
    let bLeft = b.x - tolerance
    let bRight = b.x + b.width + tolerance
    let bBottom = b.y - tolerance
    let bTop = b.y + b.height + tolerance
    // Axis-aligned overlap is the negation of separation on either axis.
    return !(aRight < bLeft || bRight < aLeft || aTop < bBottom || bTop < aBottom)
}

/// Group rectangles into spatially connected clusters, keeping only those
/// with at least `minimumSize` members.
///
/// The pairwise loop is quadratic, and stays so — but a rectangle already in
/// an oversized component stops being compared, which makes a page of tens of
/// thousands of illustration rectangles finish in milliseconds rather than
/// minutes. Groups come back ordered by their root index, which is what makes
/// the output deterministic.
func pdfClusterRects(
    _ rects: [(x: Float, y: Float, width: Float, height: Float)],
    tolerance: Float,
    minimumSize: Int
) -> [[Int]] {
    var sets = PdfUnionFind(rects.count)

    for i in 0..<rects.count {
        if sets.componentSize(i) >= pdfMaxClusterRects { continue }
        for j in (i + 1)..<rects.count {
            if pdfRectsOverlap(rects[i], rects[j], tolerance: tolerance) {
                sets.union(i, j)
                if sets.componentSize(i) >= pdfMaxClusterRects { break }
            }
        }
    }

    var groups: [Int: [Int]] = [:]
    for i in 0..<rects.count { groups[sets.find(i), default: []].append(i) }
    return groups.filter { $0.value.count >= minimumSize }
        .sorted { $0.key < $1.key }
        .map(\.value)
}

/// Split a cluster at its widest horizontal gap.
///
/// Two tables side by side, or a table beside a figure, cluster together when
/// their borders happen to abut. This is the fallback when grid detection
/// fails on the whole cluster: find the widest empty column band and cut
/// there, but only if both halves are substantial enough to be tables in
/// their own right.
func pdfSplitWideCluster(
    _ rects: [(x: Float, y: Float, width: Float, height: Float)],
    minimumGap: Float,
    minimumGroupSize: Int
) -> (
    left: [(x: Float, y: Float, width: Float, height: Float)],
    right: [(x: Float, y: Float, width: Float, height: Float)]
)? {
    guard rects.count >= minimumGroupSize * 2 else { return nil }

    // Merge the rectangles' x extents into contiguous bands. A 1pt slack
    // joins bands that merely touch.
    let intervals = rects.map { (start: $0.x, end: $0.x + $0.width) }
        .sorted { $0.start < $1.start }
    var bands: [(start: Float, end: Float)] = []
    for interval in intervals {
        if var last = bands.last, interval.start <= last.end + 1 {
            last.end = max(last.end, interval.end)
            bands[bands.count - 1] = last
        } else {
            bands.append(interval)
        }
    }
    guard bands.count >= 2 else { return nil }

    var bestGap: Float = 0
    var splitX: Float = 0
    for index in 1..<bands.count {
        let gap = bands[index].start - bands[index - 1].end
        if gap > bestGap {
            bestGap = gap
            splitX = (bands[index - 1].end + bands[index].start) / 2
        }
    }
    guard bestGap >= minimumGap else { return nil }

    // A rectangle goes with the side its *centre* falls on.
    let left = rects.filter { $0.x + $0.width / 2 < splitX }
    let right = rects.filter { $0.x + $0.width / 2 >= splitX }
    guard left.count >= minimumGroupSize, right.count >= minimumGroupSize else { return nil }
    return (left, right)
}
