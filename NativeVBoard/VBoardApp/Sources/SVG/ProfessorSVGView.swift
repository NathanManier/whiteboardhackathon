import UIKit

/// Demand-driven professor renderer. Paths are parsed once into world-space
/// layers; camera movement only changes a GPU-composited container transform.
final class ProfessorSVGView: UIView {
    private let contentLayer = CALayer()
    private var entries: [String: Entry] = [:]
    private var index = SpatialIndex()
    private var visibleIDs = Set<String>()
    private var document: SVGDocument?
    private var importedTransforms: [String: ObjectTransform] = [:]
    private var composition: SceneComposition?
    private var isInteracting = false

    #if DEBUG
    var onStats: ((RenderStats) -> Void)?
    #endif

    private struct Entry {
        let bounds: CGRect
        let layer: CAShapeLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        contentLayer.anchorPoint = .zero
        contentLayer.position = .zero
        layer.addSublayer(contentLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ document: SVGDocument, transform: WorldScreenTransform,
                 importedTransforms: [String: ObjectTransform] = [:],
                 composition: SceneComposition? = nil) {
        if self.document != document || self.importedTransforms != importedTransforms {
            rebuild(document: document, importedTransforms: importedTransforms, composition: composition)
        } else {
            self.composition = composition
        }
        updateCamera(transform, interacting: false)
    }

    func updateCamera(_ transform: WorldScreenTransform, interacting: Bool) {
        isInteracting = interacting
        contentLayer.frame = bounds
        contentLayer.setAffineTransform(transform.affineTransform)
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

    private func rebuild(document: SVGDocument, importedTransforms: [String: ObjectTransform], composition: SceneComposition?) {
        self.document = document
        self.importedTransforms = importedTransforms
        self.composition = composition
        entries.removeAll(keepingCapacity: true)
        index = SpatialIndex(cellSize: max(document.viewBox.width, document.viewBox.height) / 32)
        visibleIDs.removeAll(keepingCapacity: true)
        contentLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        #if DEBUG
        let start = CACurrentMediaTime()
        var cacheHits = 0
        var cacheMisses = 0
        #endif
        for item in SceneComposition.canonicalProfessorPaths(document.paths) {
            guard let id = item.id, importedTransforms[id]?.deleted != true else { continue }
            do {
                var worldTransform = CGAffineTransform.identity
                if let imported = importedTransforms[id] {
                    worldTransform = worldTransform
                        .translatedBy(x: CGFloat(imported.x), y: CGFloat(imported.y))
                        .scaledBy(x: CGFloat(imported.scaleX ?? 1), y: CGFloat(imported.scaleY ?? 1))
                }
                let parsed = try SVGPathParser.cachedPath(from: item.d, hits: {
                    #if DEBUG
                    cacheHits += 1
                    #endif
                }, misses: {
                    #if DEBUG
                    cacheMisses += 1
                    #endif
                })
                let path = parsed.copy(using: &worldTransform) ?? CGPath(rect: .zero, transform: nil)
                let shape = CAShapeLayer()
                shape.path = path
                shape.fillColor = item.fill.cgColor
                shape.fillRule = item.fillRule
                shape.contentsScale = window?.screen.scale ?? UIScreen.main.scale
                shape.isHidden = true
                applyProvenance(id: id, to: shape)
                contentLayer.addSublayer(shape)
                entries[id] = Entry(bounds: path.boundingBoxOfPath, layer: shape)
                index.insert(id: id, bounds: path.boundingBoxOfPath)
            } catch {
                #if DEBUG
                print("[VBoard] SVG path skipped id=\(id) error=\(error)")
                #endif
            }
        }
        #if DEBUG
        var stats = RenderStats(state: "idle", indexedObjects: entries.count,
                                newPathsCreated: entries.count, cacheHits: cacheHits,
                                cacheMisses: cacheMisses)
        stats.frameMilliseconds = (CACurrentMediaTime() - start) * 1000
        RenderPerformance.shared.record(stats)
        onStats?(stats)
        #endif
    }

    private func refine(transform: WorldScreenTransform) {
        guard !entries.isEmpty else { return }
        let started = CACurrentMediaTime()
        let visibleRect = transform.camera.cgRect.expanded(by: max(transform.camera.width, transform.camera.height) * 0.15)
        let candidates = index.query(visibleRect)
        let changed = visibleIDs.symmetricDifference(candidates)
        for id in changed { entries[id]?.layer.isHidden = !candidates.contains(id) }
        visibleIDs = candidates
        #if DEBUG
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

    private func applyProvenance(id: String, to layer: CALayer) {
        #if DEBUG
        if let node = composition?.nodes.first(where: { $0.sourceID == id && ($0.sourceKind == .professorSVG || $0.sourceKind == .importedTransform) }) {
            layer.name = node.debugLabel
            layer.setValue(node.logicalID, forKey: "vboard.logicalID")
            layer.setValue(node.sourceKind.rawValue, forKey: "vboard.sourceKind")
            layer.setValue(node.sourceID, forKey: "vboard.sourceID")
            layer.setValue(node.renderLayer, forKey: "vboard.renderLayer")
        }
        #endif
    }
}

private extension CameraRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private extension CGRect {
    func expanded(by amount: CGFloat) -> CGRect { insetBy(dx: -amount, dy: -amount) }
}
