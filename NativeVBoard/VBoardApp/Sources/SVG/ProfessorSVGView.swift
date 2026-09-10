import UIKit

/// Demand-driven professor renderer. Paths are parsed once into world-space
/// layers. Camera movement is owned by InfiniteCanvasUIView's world
/// container; this view only refines visibility after the camera has settled.
final class ProfessorSVGView: UIView {
    private let contentLayer = CALayer()
    private var entries: [String: Entry] = [:]
    private var index = SpatialIndex()
    private var visibleIDs = Set<String>()
    private var document: SVGDocument?
    private var importedTransforms: [String: ObjectTransform] = [:]
    private var composition: SceneComposition?
    private var isInteracting = false
    private var currentTransform: WorldScreenTransform?
    private var rebuildTask: Task<Void, Never>?
    private var rebuildGeneration = UUID()
    var onProgress: ((Double) -> Void)?

    #if DEBUG
    var onStats: ((RenderStats) -> Void)?
    #endif

    private struct Entry {
        let bounds: CGRect
        let layer: CAShapeLayer
        let isRegionSurface: Bool
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // World-space paths may legitimately extend outside this view's local
        // bounds. The parent world container is the camera/clipping boundary.
        clipsToBounds = false
        contentLayer.anchorPoint = .zero
        contentLayer.position = .zero
        layer.addSublayer(contentLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { rebuildTask?.cancel() }

    func display(_ document: SVGDocument, transform: WorldScreenTransform,
                 importedTransforms: [String: ObjectTransform] = [:],
                 composition: SceneComposition? = nil) {
        if self.document != document || self.importedTransforms != importedTransforms {
            beginProgressiveRebuild(document: document,
                                    importedTransforms: importedTransforms,
                                    composition: composition)
        } else {
            self.composition = composition
        }
        updateCamera(transform, interacting: false)
    }

    func updateCamera(_ transform: WorldScreenTransform, interacting: Bool) {
        isInteracting = interacting
        currentTransform = transform
        // The world container applies `transform.affineTransform`. Keeping
        // this layer untransformed is critical: applying camera math here as
        // well would transform the professor layer twice and make input and
        // visibility appear to disagree with the rendered pixels.
        contentLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        contentLayer.position = .zero
        contentLayer.setAffineTransform(.identity)
        if !interacting { refine(transform: transform) }
    }

    func beginNavigation() {
        isInteracting = true
        #if DEBUG
        var stats = RenderPerformance.shared.last
        stats.state = "interacting"
        RenderPerformance.shared.record(stats)
        onStats?(stats)
        #endif
    }

    func endNavigation(_ transform: WorldScreenTransform) {
        isInteracting = false
        refine(transform: transform)
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat = 12) -> String? {
        let candidates = index.query(CGRect(x: point.x - tolerance, y: point.y - tolerance,
                                            width: tolerance * 2, height: tolerance * 2))
        return candidates.first(where: { entries[$0]?.layer.path?.contains(point, using: .winding, transform: .identity) == true })
    }

    func ids(intersecting rect: CGRect) -> Set<String> { index.query(rect) }

    /// Returns professor contours whose sampled filled area is substantially
    /// inside a board-local lasso. The spatial index is only the candidate
    /// reducer; stable path IDs remain the selection identity.
    func ids(containedBy polygon: [CGPoint], threshold: Double = 0.65) -> Set<String> {
        guard polygon.count >= 3 else { return [] }
        let polygonBounds = polygon.reduce(into: CGRect.null) { result, point in
            result = result.union(CGRect(origin: point, size: .zero))
        }
        var selected = Set<String>()
        for id in index.query(polygonBounds) {
            guard let entry = entries[id], let path = entry.layer.path else { continue }
            if entry.isRegionSurface, entry.bounds.intersects(polygonBounds) {
                selected.insert(id)
                continue
            }
            let bounds = entry.bounds
            var samples: [CGPoint] = []
            let steps = 6
            for yIndex in 0...steps {
                for xIndex in 0...steps {
                    let point = CGPoint(
                        x: bounds.minX + bounds.width * CGFloat(xIndex) / CGFloat(steps),
                        y: bounds.minY + bounds.height * CGFloat(yIndex) / CGFloat(steps)
                    )
                    if path.contains(point, using: entry.layer.fillRule == .evenOdd ? .evenOdd : .winding) {
                        samples.append(point)
                    }
                }
            }
            if samples.isEmpty { samples = [CGPoint(x: bounds.midX, y: bounds.midY)] }
            let contained = samples.filter { Self.polygonContains($0, polygon: polygon) }.count
            if Double(contained) / Double(samples.count) >= threshold { selected.insert(id) }
        }
        return selected
    }

    func bounds(for id: String) -> CGRect {
        entries[id]?.bounds ?? .null
    }

    /// Applies a transient world-space translation to selected professor
    /// paths. The immutable SVG path and its baked imported transform remain
    /// untouched; the affine transform is cleared when the move commits or
    /// is cancelled.
    func previewTranslation(ids: Set<String>, delta: CGPoint) {
        let transform = CGAffineTransform(translationX: delta.x, y: delta.y)
        for id in ids { entries[id]?.layer.setAffineTransform(transform) }
    }

    func clearPreviewTranslation(ids: Set<String>) {
        for id in ids { entries[id]?.layer.setAffineTransform(.identity) }
    }

    /// Applies a transient selection resize while preserving the immutable
    /// professor path. The committed representation remains an imported
    /// transform in editor.json.
    func previewScale(ids: Set<String>, anchor: CGPoint, scale: CGFloat) {
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                          tx: anchor.x * (1 - scale),
                                          ty: anchor.y * (1 - scale))
        for id in ids { entries[id]?.layer.setAffineTransform(transform) }
    }

    func clearPreviewScale(ids: Set<String>) {
        for id in ids { entries[id]?.layer.setAffineTransform(.identity) }
    }

    /// Parses canonical paths away from the frame-critical interaction path
    /// and installs them in bounded batches. A board thumbnail remains visible
    /// while this progresses, then fades as exact contours become available.
    private func beginProgressiveRebuild(document: SVGDocument,
                                         importedTransforms: [String: ObjectTransform],
                                         composition: SceneComposition?) {
        rebuildTask?.cancel()
        rebuildGeneration = UUID()
        let generation = rebuildGeneration
        self.document = document
        self.importedTransforms = importedTransforms
        self.composition = composition
        entries.removeAll(keepingCapacity: true)
        index = SpatialIndex(cellSize: max(document.viewBox.width, document.viewBox.height) / 32)
        visibleIDs.removeAll(keepingCapacity: true)
        contentLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        onProgress?(0)

        let paths = SceneComposition.canonicalProfessorPaths(document.paths).filter {
            guard let id = $0.id else { return false }
            return importedTransforms[id]?.deleted != true
        }
        guard !paths.isEmpty else {
            onProgress?(1)
            return
        }

        #if DEBUG
        let started = CACurrentMediaTime()
        #endif
        rebuildTask = Task { [weak self] in
            let batchSize = 128
            var completed = 0
            while completed < paths.count, !Task.isCancelled {
                let end = min(completed + batchSize, paths.count)
                let definitions = paths[completed..<end].map(\.d)
                let transforms = paths[completed..<end].map { item -> CGAffineTransform in
                    guard let id = item.id, let imported = importedTransforms[id] else { return .identity }
                    return CGAffineTransform.identity
                        .translatedBy(x: CGFloat(imported.x), y: CGFloat(imported.y))
                        .scaledBy(x: CGFloat(imported.scaleX ?? 1),
                                  y: CGFloat(imported.scaleY ?? 1))
                }
                let parsed: [CGPath?] = await Task.detached(priority: .userInitiated) {
                    zip(definitions, transforms).map { definition, transform in
                        guard let source = try? SVGPathParser.cachedPath(from: definition) else { return nil }
                        var transform = transform
                        return source.copy(using: &transform)
                    }
                }.value
                guard let self, !Task.isCancelled,
                      self.rebuildGeneration == generation else { return }

                let displayScale = self.window?.screen.scale ?? UIScreen.main.scale
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for (offset, path) in parsed.enumerated() {
                    guard let path else { continue }
                    let item = paths[completed + offset]
                    guard let id = item.id else { continue }
                    let shape = CAShapeLayer()
                    shape.path = path
                    shape.fillColor = item.fill.cgColor
                    shape.fillRule = item.fillRule
                    shape.contentsScale = displayScale
                    shape.isHidden = true
                    #if DEBUG
                    let node = composition?.nodes.first(where: {
                        ($0.sourceKind == .professorSVG || $0.sourceKind == .importedTransform)
                            && $0.sourceID == id
                    })
                    self.applyProvenance(node, to: shape)
                    #endif
                    let bounds = path.boundingBoxOfPath
                    self.entries[id] = Entry(bounds: bounds, layer: shape,
                                             isRegionSurface: item.dataInk == "pdf-source")
                    self.index.insert(id: id, bounds: bounds)
                    self.contentLayer.addSublayer(shape)
                }
                CATransaction.commit()
                completed = end
                if let transform = self.currentTransform, !self.isInteracting {
                    self.refine(transform: transform)
                }
                self.onProgress?(Double(completed) / Double(paths.count))
                await Task.yield()
            }
            guard let self, self.rebuildGeneration == generation else { return }
            #if DEBUG
            var stats = RenderPerformance.shared.last
            stats.indexedObjects = self.entries.count
            stats.newPathsCreated = self.entries.count
            stats.frameMilliseconds = (CACurrentMediaTime() - started) * 1_000
            RenderPerformance.shared.record(stats)
            self.onStats?(stats)
            print("[VBoard] VECTOR PROGRESS exactReady paths=\(self.entries.count) milliseconds=\(stats.frameMilliseconds)")
            #endif
            self.rebuildTask = nil
        }
    }

    private func refine(transform: WorldScreenTransform) {
        guard !entries.isEmpty else { return }
        let started = CACurrentMediaTime()
        let preloadMargin = max(transform.camera.width, transform.camera.height) * 0.15
        let visibleRect = transform.camera.cgRect.expanded(by: preloadMargin)
        let candidates = index.query(visibleRect)
        let changed = visibleIDs.symmetricDifference(candidates)
        for id in changed { entries[id]?.layer.isHidden = !candidates.contains(id) }
        visibleIDs = candidates
        #if DEBUG
        print("[VBoard] VECTOR VISIBILITY cameraRect=\(transform.camera.cgRect) preloadMargin=\(preloadMargin) queryRect=\(visibleRect) candidates=\(candidates.count) changed=\(changed.count) interacting=\(isInteracting)")
        var stats = RenderPerformance.shared.last
        stats.state = isInteracting ? "interacting" : "refining"
        stats.visibleObjects = visibleIDs.count
        stats.candidateObjects = candidates.count
        stats.indexedObjects = entries.count
        stats.pathsDrawn = visibleIDs.count
        stats.frameMilliseconds = (CACurrentMediaTime() - started) * 1000
        RenderPerformance.shared.record(stats)
        onStats?(stats)
        #endif
    }

    private func applyProvenance(_ node: SceneNode?, to layer: CALayer) {
        #if DEBUG
        if let node {
            layer.name = node.debugLabel
            layer.setValue(node.logicalID, forKey: "vboard.logicalID")
            layer.setValue(node.sourceKind.rawValue, forKey: "vboard.sourceKind")
            layer.setValue(node.sourceID, forKey: "vboard.sourceID")
            layer.setValue(node.renderLayer, forKey: "vboard.renderLayer")
        }
        #endif
    }

    private static func polygonContains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false
        for index in polygon.indices {
            let previous = index == polygon.startIndex ? polygon.index(before: polygon.endIndex) : polygon.index(before: index)
            let a = polygon[index]
            let b = polygon[previous]
            let denominator = b.y - a.y
            if abs(denominator) > .ulpOfOne,
               (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / denominator + a.x {
                inside.toggle()
            }
        }
        return inside
    }
}

private extension CGRect {
    func expanded(by amount: CGFloat) -> CGRect { insetBy(dx: -amount, dy: -amount) }
}
