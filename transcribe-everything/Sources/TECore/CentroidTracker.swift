/// Online speakers for one source: running-mean centroids, and a new speaker only after sustained disagreement,
/// so a laugh or noise cannot spawn one. Labels are 1-based; windows before any centroid exists are Speaker 1.
public actor CentroidTracker {
    private var sums: [[Double]] = [], pending: [[Double]] = []
    public private(set) var previous = 1

    public init() {}

    public func assign(window embedding: [Float], threshold: Double, confirmWindows: Int) -> Int {
        let e = unit(embedding.map(Double.init))
        let sims = sums.map { zip(e, unit($0)).reduce(0) { $0 + $1.0 * $1.1 } }
        if let best = sims.max(), best >= threshold {
            let k = sims.firstIndex(of: best)!
            sums[k] = zip(sums[k], e).map(+)
            pending = []
            previous = k + 1
        } else {
            pending.append(e)
            if pending.count >= confirmWindows {
                sums.append(pending.reduce([Double](repeating: 0, count: e.count)) { zip($0, $1).map(+) })
                pending = []
                previous = sums.count
            }
        }
        return previous
    }

    private func unit(_ v: [Double]) -> [Double] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / n }
    }
}
