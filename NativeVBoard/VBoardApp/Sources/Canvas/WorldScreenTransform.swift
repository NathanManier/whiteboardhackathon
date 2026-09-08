import CoreGraphics

struct WorldScreenTransform: Equatable {
    let camera: CameraRect
    let viewport: CGSize

    var scale: CGFloat { min(viewport.width / CGFloat(camera.width), viewport.height / CGFloat(camera.height)) }
    var contentSize: CGSize { CGSize(width: CGFloat(camera.width) * scale, height: CGFloat(camera.height) * scale) }
    var origin: CGPoint { CGPoint(x: (viewport.width - contentSize.width) / 2, y: (viewport.height - contentSize.height) / 2) }

    func screenPoint(for world: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + (world.x - camera.x) * scale, y: origin.y + (world.y - camera.y) * scale)
    }

    func worldPoint(for screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - origin.x) / scale + camera.x, y: (screen.y - origin.y) / scale + camera.y)
    }
}

struct CameraController: Equatable {
    static let zoomRange = 0.04...64.0
    private(set) var camera: CameraRect

    init(camera: CameraRect) { self.camera = camera }

    mutating func pan(screenTranslation: CGPoint, viewport: CGSize) {
        let transform = WorldScreenTransform(camera: camera, viewport: viewport)
        camera.x -= Double(screenTranslation.x / transform.scale)
        camera.y -= Double(screenTranslation.y / transform.scale)
    }

    mutating func zoom(by magnification: CGFloat, anchoredAt screen: CGPoint, viewport: CGSize) {
        guard magnification > 0 else { return }
        let old = WorldScreenTransform(camera: camera, viewport: viewport)
        let anchor = old.worldPoint(for: screen)
        let oldZoom = 1 / old.scale
        let newZoom = min(max(oldZoom / Double(magnification), Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let ratio = newZoom / oldZoom
        camera.width *= ratio; camera.height *= ratio
        let updated = WorldScreenTransform(camera: camera, viewport: viewport)
        let newAnchor = updated.worldPoint(for: screen)
        camera.x += anchor.x - newAnchor.x; camera.y += anchor.y - newAnchor.y
    }

    mutating func resizeViewport(from old: CGSize, to new: CGSize) {
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0 else { return }
        let center = camera.center
        let oldAspect = old.width / old.height
        let newAspect = new.width / new.height
        if newAspect > oldAspect { camera.width = camera.height * Double(newAspect) }
        else { camera.height = camera.width / Double(newAspect) }
        camera.x = center.x - camera.width / 2; camera.y = center.y - camera.height / 2
    }
}
