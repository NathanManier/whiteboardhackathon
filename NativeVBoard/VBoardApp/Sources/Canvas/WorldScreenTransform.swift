import CoreGraphics
import UIKit

/// The single coordinate-space boundary for canvas input and rendering.
/// UIKit events are first converted into the root canvas view's untransformed
/// local coordinates, then mapped through the authoritative CameraRect.
struct CanvasCoordinateMapper {
    static func viewPointToWorld(_ point: CGPoint, from sourceView: UIView, in canvasView: UIView, camera: CameraRect) -> CGPoint {
        let canvasPoint = sourceView.convert(point, to: canvasView)
        return WorldScreenTransform(camera: camera, viewport: canvasView.bounds.size).worldPoint(for: canvasPoint)
    }

    static func worldToViewPoint(_ point: CGPoint, in canvasView: UIView, camera: CameraRect) -> CGPoint {
        WorldScreenTransform(camera: camera, viewport: canvasView.bounds.size).screenPoint(for: point)
    }
}

enum CameraMutationReason: String {
    case boardInitialFit
    case restorePersistedViewport
    case handPan
    case touchPan
    case pinch
    case keyboardZoom
    case explicitFitBoard
    case explicitReset
}

enum CameraResolver {
    static func fitBoard(boardRect: CGRect, viewport: CGSize, screenPadding: CGFloat = 32) -> CameraRect {
        guard boardRect.width > 0, boardRect.height > 0, viewport.width > 0, viewport.height > 0 else {
            return CameraRect(x: boardRect.minX, y: boardRect.minY, width: max(boardRect.width, 1), height: max(boardRect.height, 1))
        }
        let aspect = viewport.width / viewport.height
        let paddingWorld = max(boardRect.width, boardRect.height) * 0.04 + screenPadding / max(viewport.width / boardRect.width, viewport.height / boardRect.height)
        let contentWidth = boardRect.width + paddingWorld * 2
        let contentHeight = boardRect.height + paddingWorld * 2
        let width: CGFloat
        let height: CGFloat
        if aspect >= contentWidth / contentHeight {
            height = contentHeight; width = height * aspect
        } else {
            width = contentWidth; height = width / aspect
        }
        let center = CGPoint(x: boardRect.midX, y: boardRect.midY)
        return CameraRect(x: Double(center.x - width / 2), y: Double(center.y - height / 2), width: Double(width), height: Double(height))
    }

    static func isFiniteAndPositive(_ camera: CameraRect) -> Bool {
        camera.x.isFinite && camera.y.isFinite && camera.width.isFinite && camera.height.isFinite && camera.width > 0 && camera.height > 0
    }

    static func resolve(persisted: CameraRect, boardRect: CGRect, contentBounds: CGRect, viewport: CGSize) -> (camera: CameraRect, reason: CameraMutationReason?) {
        let fallback = fitBoard(boardRect: boardRect, viewport: viewport)
        guard isFiniteAndPositive(persisted) else { return (fallback, .boardInitialFit) }
        // A viewport saved on another device can have a very different
        // aspect ratio (for example, a landscape web viewport restored into
        // the portrait iPad canvas). That camera is numerically valid but
        // makes the board appear off-screen. Zooming preserves the aspect
        // ratio, so this check does not interfere with an intentional zoom.
        guard viewport.width > 0, viewport.height > 0,
              boardRect.width > 0, boardRect.height > 0 else {
            return (fallback, .boardInitialFit)
        }
        let persistedRect = persisted.cgRect
        let viewportAspect = viewport.width / viewport.height
        let persistedAspect = persistedRect.width / persistedRect.height
        let aspectRatio = max(persistedAspect / viewportAspect, viewportAspect / persistedAspect)
        let aspectMismatch = !aspectRatio.isFinite || aspectRatio > 1.75

        // The board is the source of truth for the initial view. A historical
        // viewport that no longer intersects it is treated as stale even if
        // it happens to contain an off-board user stroke.
        let missesBoard = !persistedRect.intersects(boardRect)

        // Reject only genuinely absurd extents. A normal zoom may be much
        // smaller than the board, while a wide canvas with legitimate
        // off-board content can still be restored as long as it is not
        // orders of magnitude larger than the persisted scene.
        let sceneWidth = max(max(boardRect.width, contentBounds.width), 1)
        let sceneHeight = max(max(boardRect.height, contentBounds.height), 1)
        let absurdlyLarge = persistedRect.width > sceneWidth * 12 || persistedRect.height > sceneHeight * 12

        if missesBoard || aspectMismatch || absurdlyLarge {
            return (fallback, .boardInitialFit)
        }
        return (persisted, nil)
    }
}

struct WorldScreenTransform: Equatable {
    let camera: CameraRect
    let viewport: CGSize

    var scale: CGFloat { min(viewport.width / CGFloat(camera.width), viewport.height / CGFloat(camera.height)) }
    var contentSize: CGSize { CGSize(width: CGFloat(camera.width) * scale, height: CGFloat(camera.height) * scale) }
    var origin: CGPoint { CGPoint(x: (viewport.width - contentSize.width) / 2, y: (viewport.height - contentSize.height) / 2) }
    /// Affine transform applied to world-space display layers. Keeping paths in
    /// world coordinates lets pan/zoom use Core Animation composition rather
    /// than rebuilding every path for each camera sample.
    var affineTransform: CGAffineTransform {
        CGAffineTransform(translationX: origin.x - CGFloat(camera.x) * scale,
                          y: origin.y - CGFloat(camera.y) * scale)
            .scaledBy(x: scale, y: scale)
    }

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

    mutating func setCamera(_ camera: CameraRect) { self.camera = camera }

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

    /// Applies a complete pinch from immutable gesture-start state. Using the
    /// total recognizer scale and the current midpoint avoids cumulative drift
    /// and keeps the world point under the fingers anchored while the midpoint
    /// translates. Pan and pinch therefore share one CameraRect mutation path.
    mutating func pinch(startCamera: CameraRect,
                        startMidpoint: CGPoint,
                        currentMidpoint: CGPoint,
                        magnification: CGFloat,
                        viewport: CGSize) {
        guard magnification.isFinite, magnification > 0,
              viewport.width > 0, viewport.height > 0,
              startCamera.width > 0, startCamera.height > 0 else { return }

        let startTransform = WorldScreenTransform(camera: startCamera, viewport: viewport)
        let anchoredWorld = startTransform.worldPoint(for: startMidpoint)
        let startZoom = max(1.0 / startTransform.scale, .leastNonzeroMagnitude)
        let targetZoom = min(max(startZoom / Double(magnification), Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let ratio = targetZoom / startZoom

        var candidate = CameraRect(x: startCamera.x,
                                   y: startCamera.y,
                                   width: startCamera.width * ratio,
                                   height: startCamera.height * ratio)
        let candidateTransform = WorldScreenTransform(camera: candidate, viewport: viewport)
        let scale = max(candidateTransform.scale, .leastNonzeroMagnitude)
        // Solve the camera origin directly so the original world anchor stays
        // under the moving midpoint. This includes translation and scale in a
        // single atomic camera update.
        candidate.x = anchoredWorld.x - Double((currentMidpoint.x - candidateTransform.origin.x) / scale)
        candidate.y = anchoredWorld.y - Double((currentMidpoint.y - candidateTransform.origin.y) / scale)
        camera = candidate
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
