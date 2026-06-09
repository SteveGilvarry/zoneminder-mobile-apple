import CoreGraphics

/// Justified-rows wall layout — the photo-gallery algorithm adapted to a fixed (non-scrolling)
/// container. Each row is justified to the full width while honoring every camera's true aspect
/// ratio (a portrait camera simply takes less width than a landscape one), so there's no
/// letterboxing *between* tiles and the wall fills the screen far better than a uniform grid.
///
/// Geometry note: with fixed aspect ratios you can match per-row width OR total height exactly, not
/// both, without distortion. So we justify each row to width, then if the stack is taller than the
/// container we scale it down uniformly to fit (leaving small side margins); if shorter, we centre
/// it vertically. The row count is chosen to make the stack height as close to the container as
/// possible, minimizing leftover margin.
public enum WallLayout {
    public struct Cell: Equatable { public let index: Int; public let width: CGFloat; public let height: CGFloat }
    public struct Row: Equatable { public let cells: [Cell] }
    public struct Result: Equatable { public let rows: [Row]; public let topInset: CGFloat }

    /// A camera placed at an absolute rect within the container.
    public struct Placement: Equatable { public let index: Int; public let rect: CGRect }

    // MARK: - Slicing-tree optimizer (2D, mixed horizontal/vertical splits)

    /// Recursive binary-partition ("slicing floorplan") layout. Unlike `justified` (flat rows), this
    /// can place a tall element beside a stacked column, etc. It searches slicing trees and picks the
    /// one whose composite aspect best matches the container, then realizes it to absolute rects —
    /// filling the screen far better for mixed portrait/landscape sets while keeping true aspects.
    ///
    /// Cameras are considered in aspect-sorted order with contiguous groupings (a tractable subset of
    /// all slicings that still finds the strong layouts). Each tile is letterboxed within its cell.
    public static func optimal(aspects rawAspects: [CGFloat], in size: CGSize, gap: CGFloat) -> [Placement] {
        let n = rawAspects.count
        guard n > 0, size.width > 1, size.height > 1 else { return [] }
        let containerAR = size.width / size.height

        // Sort indices by aspect so contiguous groups are natural (portraits together, etc).
        let order = (0..<n).sorted { rawAspects[$0] < rawAspects[$1] }
        let asp = order.map { rawAspects[$0] }

        let tree = solve(0, n, target: containerAR, aspects: asp).node
        // Fill the whole container edge-to-edge (no outer margin) so tiles are as large as possible.
        // Cells take their share of the screen; each video fits its cell, touching one pair of edges
        // (full-width or full-height per its aspect). Off-axis bars are inherent to mixed aspects.
        var placements: [Placement] = []
        realize(tree, rect: CGRect(origin: .zero, size: size), order: order, into: &placements)
        // Inset each tile by half the gap so neighbours are `gap` apart.
        let half = gap / 2
        return placements.map { Placement(index: $0.index, rect: $0.rect.insetBy(dx: half, dy: half)) }
    }

    private indirect enum Node {
        case leaf(Int, CGFloat)     // index into the sorted order; the camera's aspect
        case v(Node, Node, CGFloat) // side by side; composite ar
        case h(Node, Node, CGFloat) // stacked; composite ar
        var ar: CGFloat {
            switch self {
            case .leaf(_, let a): return a
            case .v(_, _, let a), .h(_, _, let a): return a
            }
        }
    }

    private struct Solution { let node: Node; let ar: CGFloat; let cost: CGFloat }

    /// Best slicing of sorted items [i, j) trying to hit `target` aspect; minimizes summed leaf
    /// letterbox-mismatch.
    private static func solve(_ i: Int, _ j: Int, target: CGFloat, aspects: [CGFloat]) -> Solution {
        if j - i == 1 {
            let ar = aspects[i]
            return Solution(node: .leaf(i, ar), ar: ar, cost: mismatch(ar, target))
        }
        var best: Solution?
        for k in (i + 1)..<j {
            let fracA = CGFloat(k - i) / CGFloat(j - i)
            // Vertical split (side by side, shared height): child aspects add to target.
            do {
                let tA = max(0.01, target * fracA), tB = max(0.01, target * (1 - fracA))
                let a = solve(i, k, target: tA, aspects: aspects)
                let b = solve(k, j, target: tB, aspects: aspects)
                let node = Node.v(a.node, b.node, a.ar + b.ar)
                let sol = Solution(node: node, ar: a.ar + b.ar, cost: a.cost + b.cost)
                if best == nil || sol.cost < best!.cost { best = sol }
            }
            // Horizontal split (stacked, shared width): inverse aspects add to 1/target.
            do {
                let inv = 1 / target
                let invA = max(0.01, inv * fracA), invB = max(0.01, inv * (1 - fracA))
                let a = solve(i, k, target: 1 / invA, aspects: aspects)
                let b = solve(k, j, target: 1 / invB, aspects: aspects)
                let combined = 1 / (1 / a.ar + 1 / b.ar)
                let node = Node.h(a.node, b.node, combined)
                let sol = Solution(node: node, ar: combined, cost: a.cost + b.cost)
                if best == nil || sol.cost < best!.cost { best = sol }
            }
        }
        return best!
    }

    private static func realize(_ node: Node, rect: CGRect, order: [Int], into out: inout [Placement]) {
        switch node {
        case .leaf(let sortedIdx, _):
            out.append(Placement(index: order[sortedIdx], rect: rect))
        case .v(let a, let b, _):
            // Split width by the children's wanted aspects (same height → width ∝ aspect).
            let wA = rect.width * a.ar / (a.ar + b.ar)
            realize(a, rect: CGRect(x: rect.minX, y: rect.minY, width: wA, height: rect.height), order: order, into: &out)
            realize(b, rect: CGRect(x: rect.minX + wA, y: rect.minY, width: rect.width - wA, height: rect.height), order: order, into: &out)
        case .h(let a, let b, _):
            // Split height by inverse aspects (same width → height ∝ 1/aspect).
            let hA = rect.height * (1 / a.ar) / (1 / a.ar + 1 / b.ar)
            realize(a, rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: hA), order: order, into: &out)
            realize(b, rect: CGRect(x: rect.minX, y: rect.minY + hA, width: rect.width, height: rect.height - hA), order: order, into: &out)
        }
    }

    private static func mismatch(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        guard a > 0, b > 0 else { return 1 }
        return 1 - min(a, b) / max(a, b)
    }

    /// - Parameters:
    ///   - aspects: displayed width/height per tile (portrait cameras pass 9/16, landscape 16/9).
    ///   - size: available container size.
    ///   - gap: spacing between tiles.
    ///   - chrome: fixed extra height added to every tile for its toolbar strip (0 if hidden).
    public static func justified(aspects: [CGFloat], in size: CGSize, gap: CGFloat, chrome: CGFloat = 0) -> Result {
        let n = aspects.count
        guard n > 0, size.width > 1, size.height > 1 else { return Result(rows: [], topInset: 0) }

        // Pick the row count whose resulting stack height is closest to the container height.
        var bestPartition: [[Int]] = [Array(0..<n)]
        var bestScore = CGFloat.greatestFiniteMagnitude
        for r in 1...n {
            let parts = partition(aspects, into: r)
            let h = stackHeight(parts, aspects: aspects, width: size.width, gap: gap, chrome: chrome)
            let score = abs(h - size.height)
            if score < bestScore { bestScore = score; bestPartition = parts }
        }

        // Realize: justify each row to full width.
        var rows: [Row] = []
        for part in bestPartition {
            let aspectSum = part.reduce(CGFloat(0)) { $0 + aspects[$1] }
            guard aspectSum > 0 else { continue }
            let avail = size.width - gap * CGFloat(part.count - 1)
            let videoH = max(1, avail / aspectSum)            // justified video height for this row
            let rowH = videoH + chrome
            let cells = part.map { Cell(index: $0, width: videoH * aspects[$0], height: rowH) }
            rows.append(Row(cells: cells))
        }

        var contentH = rows.reduce(CGFloat(0)) { $0 + ($1.cells.first?.height ?? 0) } + gap * CGFloat(max(rows.count, 1) - 1)

        // If too tall, scale the whole stack down to fit (keeps aspect; small horizontal margins).
        if contentH > size.height, contentH > 0 {
            let scale = size.height / contentH
            rows = rows.map { row in
                Row(cells: row.cells.map { Cell(index: $0.index, width: $0.width * scale, height: $0.height * scale) })
            }
            contentH = size.height
        }

        let topInset = max(0, (size.height - contentH) / 2)
        return Result(rows: rows, topInset: topInset)
    }

    /// Space-filling variant: covers the container **completely** (equal-height rows, each cell's
    /// width proportional to its camera's aspect) and chooses the row count that **minimizes total
    /// cropping**. Coverage is fixed at 100%, so this optimizes the only remaining freedom — how
    /// much each tile must be cropped to fill its cell. Tiles are expected to render crop-to-fill.
    public static func filled(aspects: [CGFloat], in size: CGSize, gap: CGFloat, chrome: CGFloat = 0) -> Result {
        let n = aspects.count
        guard n > 0, size.width > 1, size.height > 1 else { return Result(rows: [], topInset: 0) }

        var bestPartition: [[Int]] = [Array(0..<n)]
        var bestCrop = CGFloat.greatestFiniteMagnitude
        for r in 1...n {
            let parts = partition(aspects, into: r)
            let crop = totalCrop(parts, aspects: aspects, size: size, gap: gap, chrome: chrome)
            if crop < bestCrop { bestCrop = crop; bestPartition = parts }
        }

        let r = bestPartition.count
        let rowH = (size.height - gap * CGFloat(r - 1)) / CGFloat(r)
        let videoH = max(1, rowH - chrome)
        var rows: [Row] = []
        for part in bestPartition {
            let aspectSum = part.reduce(CGFloat(0)) { $0 + aspects[$1] }
            guard aspectSum > 0 else { continue }
            let availW = size.width - gap * CGFloat(part.count - 1)
            let cells = part.map { Cell(index: $0, width: availW * (aspects[$0] / aspectSum), height: rowH) }
            rows.append(Row(cells: cells))
        }
        _ = videoH
        return Result(rows: rows, topInset: 0)
    }

    /// Sum of per-tile crop fractions for a filled (equal-height, width-by-aspect) partition.
    private static func totalCrop(_ parts: [[Int]], aspects: [CGFloat], size: CGSize, gap: CGFloat, chrome: CGFloat) -> CGFloat {
        let r = parts.count
        let rowH = (size.height - gap * CGFloat(r - 1)) / CGFloat(r)
        let videoH = max(1, rowH - chrome)
        var total: CGFloat = 0
        for part in parts {
            let aspectSum = part.reduce(CGFloat(0)) { $0 + aspects[$1] }
            guard aspectSum > 0 else { continue }
            let availW = size.width - gap * CGFloat(part.count - 1)
            for i in part {
                let cellW = availW * (aspects[i] / aspectSum)
                let cellAR = cellW / videoH
                let vidAR = aspects[i]
                // Crop fraction when covering: 1 - smaller/larger aspect ratio (0 = perfect fit).
                let frac = 1 - min(cellAR, vidAR) / max(cellAR, vidAR)
                total += frac
            }
        }
        return total
    }

    // Stack height for a partition with rows justified to width.
    private static func stackHeight(_ parts: [[Int]], aspects: [CGFloat], width: CGFloat, gap: CGFloat, chrome: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for part in parts {
            let aspectSum = part.reduce(CGFloat(0)) { $0 + aspects[$1] }
            guard aspectSum > 0 else { continue }
            let avail = width - gap * CGFloat(part.count - 1)
            total += max(1, avail / aspectSum) + chrome
        }
        return total + gap * CGFloat(max(parts.count, 1) - 1)
    }

    /// Partition the item sequence into `k` contiguous rows, balancing each row's aspect-sum so the
    /// justified row heights come out as even as possible (classic "painter's partition" DP, which
    /// minimizes the maximum row aspect-sum). Items stay in their given order.
    static func partition(_ aspects: [CGFloat], into k: Int) -> [[Int]] {
        let n = aspects.count
        if k <= 1 { return [Array(0..<n)] }
        if k >= n { return (0..<n).map { [$0] } }

        // prefix sums of aspects
        var prefix = [CGFloat](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + aspects[i] }
        func rangeSum(_ a: Int, _ b: Int) -> CGFloat { prefix[b] - prefix[a] }  // [a, b)

        // dp[i][j] = min possible max-row-sum splitting first i items into j rows.
        let big = CGFloat.greatestFiniteMagnitude
        var dp = Array(repeating: Array(repeating: big, count: k + 1), count: n + 1)
        var cut = Array(repeating: Array(repeating: 0, count: k + 1), count: n + 1)
        dp[0][0] = 0
        for i in 1...n {
            for j in 1...min(k, i) {
                var p = j - 1
                while p < i {
                    let cost = max(dp[p][j - 1], rangeSum(p, i))
                    if cost < dp[i][j] { dp[i][j] = cost; cut[i][j] = p }
                    p += 1
                }
            }
        }

        // Reconstruct row boundaries.
        var bounds: [Int] = [n]
        var i = n, j = k
        while j > 0 {
            let p = cut[i][j]
            bounds.append(p)
            i = p; j -= 1
        }
        bounds.sort()
        var rows: [[Int]] = []
        for idx in 1..<bounds.count {
            let lo = bounds[idx - 1], hi = bounds[idx]
            if hi > lo { rows.append(Array(lo..<hi)) }
        }
        return rows.isEmpty ? [Array(0..<n)] : rows
    }
}
