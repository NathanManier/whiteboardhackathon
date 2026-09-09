import CoreGraphics
import Foundation

/// A bounded-complexity uniform grid. It is intentionally small and
/// deterministic: paths keep their canonical IDs while the grid only stores
/// references used to reduce viewport/hit-test candidates.
struct SpatialIndex: Sendable {
    let cellSize: CGFloat
    private var cells: [Cell: Set<String>] = [:]
    private var boundsByID: [String: CGRect] = [:]

    init(cellSize: CGFloat = 512) {
        self.cellSize = max(cellSize, 1)
    }

    mutating func insert(id: String, bounds: CGRect) {
        guard !bounds.isNull, !bounds.isEmpty else { return }
        boundsByID[id] = bounds
        for cell in cells(for: bounds) {
            cells[cell, default: []].insert(id)
        }
    }

    func query(_ rect: CGRect) -> Set<String> {
        guard !rect.isNull, !rect.isEmpty else { return [] }
        var candidates = Set<String>()
        for cell in cells(for: rect) {
            candidates.formUnion(cells[cell] ?? [])
        }
        // The grid is a candidate index, not an approximation. Exact bounds
        // intersection preserves correct visibility at cell boundaries.
        return candidates.filter { boundsByID[$0]?.intersects(rect) == true }
    }

    var count: Int { boundsByID.count }

    private func cells(for rect: CGRect) -> [Cell] {
        let minX = Int(floor(rect.minX / cellSize))
        let maxX = Int(floor((rect.maxX - CGFloat.ulpOfOne) / cellSize))
        let minY = Int(floor(rect.minY / cellSize))
        let maxY = Int(floor((rect.maxY - CGFloat.ulpOfOne) / cellSize))
        guard minX <= maxX, minY <= maxY else { return [] }
        return (minX...maxX).flatMap { x in (minY...maxY).map { y in Cell(x: x, y: y) } }
    }

    private struct Cell: Hashable, Sendable {
        let x: Int
        let y: Int
    }
}

#if DEBUG
struct RenderStats: Equatable, Sendable {
    var state: String = "idle"
    var visibleObjects = 0
    var candidateObjects = 0
    var indexedObjects = 0
    var pathsDrawn = 0
    var newPathsCreated = 0
    var cacheHits = 0
    var cacheMisses = 0
    var frameMilliseconds: Double = 0

    var overlayText: String {
        String(format: "VBoard • %@ • %.1f ms\nvisible %d / candidates %d / indexed %d\npaths %d • cache %d/%d",
               state, frameMilliseconds, visibleObjects, candidateObjects,
               indexedObjects, pathsDrawn, cacheHits, cacheMisses)
    }
}

final class RenderPerformance {
    static let shared = RenderPerformance()
    private(set) var last = RenderStats()

    func record(_ stats: RenderStats) {
        last = stats
        #if DEBUG
        print(String(format: "[VBoard][PERF] FRAME state=%@ visibleObjects=%d candidateObjects=%d indexedObjects=%d pathsDrawn=%d newPathsCreated=%d cacheHits=%d cacheMisses=%d frameMs=%.2f",
                     stats.state, stats.visibleObjects, stats.candidateObjects,
                     stats.indexedObjects, stats.pathsDrawn, stats.newPathsCreated,
                     stats.cacheHits, stats.cacheMisses, stats.frameMilliseconds))
        #endif
    }
}
#endif
