import CryptoKit
import Foundation
import UIKit

/// Private, account-namespaced memory cache for cheap graph presentations.
/// Images are derived display data only; canonical equations and viewport stay
/// in `GraphObject`, and a cache miss always falls back to native vector drawing.
@MainActor
final class GraphProxyCache {
    static let shared = GraphProxyCache()
    static let maximumPixelEdge = 2_048.0

    private let images = NSCache<NSString, UIImage>()
    private(set) var generation = 0

    init(countLimit: Int = 64, totalCostLimit: Int = 64 * 1_024 * 1_024) {
        images.countLimit = countLimit
        images.totalCostLimit = totalCostLimit
    }

    func image(for graph: GraphObject, size: CGSize, scale: CGFloat,
               appearance: UIUserInterfaceStyle) -> UIImage? {
        images.object(forKey: providerCacheKey(for: graph, appearance: appearance) as NSString)
            ?? images.object(forKey: cacheKey(for: graph, size: size, scale: scale,
                                              appearance: appearance) as NSString)
    }

    @discardableResult
    func nativeImage(for graph: GraphObject, size: CGSize, scale: CGFloat,
                     appearance: UIUserInterfaceStyle) -> UIImage {
        let renderScale = boundedRenderScale(for: size, requestedScale: scale)
        let key = cacheKey(for: graph, size: size, scale: renderScale, appearance: appearance)
        if let providerSnapshot = images.object(
            forKey: providerCacheKey(for: graph, appearance: appearance) as NSString
        ) {
            return providerSnapshot
        }
        if let cached = images.object(forKey: key as NSString) { return cached }

        let localGraph = graph.replacing(frame: GraphFrame(
            x: 0, y: 0, width: Double(max(size.width, GraphFrame.minimumDimension)),
            height: Double(max(size.height, GraphFrame.minimumDimension))
        ))
        let image = GraphFallbackRenderer.image(for: localGraph, scale: renderScale)
        store(image, forKey: key)
        return image
    }

    func store(_ image: UIImage, for graph: GraphObject, size: CGSize, scale: CGFloat,
               appearance: UIUserInterfaceStyle) {
        store(image, forKey: cacheKey(for: graph, size: size, scale: scale,
                                      appearance: appearance))
    }

    /// A provider snapshot describes semantic graph state and viewport, not
    /// the transient screen size at which its web view happened to be mounted.
    /// Passive layers can therefore reuse it after camera and layout changes.
    @discardableResult
    func storeProviderSnapshot(_ image: UIImage, for graph: GraphObject,
                               appearance: UIUserInterfaceStyle,
                               accountNamespace: String? = nil,
                               expectedGeneration: Int? = nil) -> Bool {
        guard expectedGeneration == nil || expectedGeneration == generation else {
            return false
        }
        store(image, forKey: providerCacheKey(
            for: graph, appearance: appearance,
            accountNamespace: accountNamespace
        ))
        return true
    }

    func removeAll() {
        generation &+= 1
        images.removeAllObjects()
    }

    func cacheKey(for graph: GraphObject, size: CGSize, scale: CGFloat,
                  appearance: UIUserInterfaceStyle,
                  accountNamespace: String? = nil) -> String {
        let safeScale = max(1, min(scale, 4))
        let material = KeyMaterial(
            accountNamespace: accountNamespace ?? LocalAccountNamespace.value,
            boardID: graph.owningBoardID,
            graphID: graph.id,
            expressions: graph.expressions,
            viewport: graph.viewport,
            settings: graph.settings,
            pixelWidth: Int(ceil(max(size.width, 1) * safeScale)),
            pixelHeight: Int(ceil(max(size.height, 1) * safeScale)),
            renderVersion: graph.providerMetadata?.renderVersion ?? graph.version,
            appearance: appearance.rawValue
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(material)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func providerCacheKey(for graph: GraphObject,
                          appearance: UIUserInterfaceStyle,
                          accountNamespace: String? = nil) -> String {
        let width = max(graph.frame.width, GraphFrame.minimumDimension)
        let height = max(graph.frame.height, GraphFrame.minimumDimension)
        let aspect = width / height
        let aspectSignature: CGSize
        if aspect >= 1 {
            aspectSignature = CGSize(width: aspect * 1_000, height: 1_000)
        } else {
            aspectSignature = CGSize(width: 1_000, height: 1_000 / max(aspect, 0.000_001))
        }
        return "provider:" + cacheKey(
            for: graph, size: aspectSignature, scale: 1, appearance: appearance,
            accountNamespace: accountNamespace
        )
    }

    func boundedRenderScale(for size: CGSize, requestedScale: CGFloat) -> CGFloat {
        let safeScale = max(1, min(requestedScale, 4))
        let longestEdge = max(size.width, size.height, 1)
        // Large graph frames are legal canonical content.  A fixed minimum
        // scale would let their display-only proxy exceed the memory budget
        // (for example, 10,000 pt at 0.25x is still 2,500 px).  Keep the
        // longest raster edge strictly bounded; vector/fallback rendering is
        // always available when this deliberately small proxy is promoted.
        return max(.leastNonzeroMagnitude,
                   min(safeScale, Self.maximumPixelEdge / longestEdge))
    }

    private func store(_ image: UIImage, forKey key: String) {
        let pixels = image.cgImage.map { $0.bytesPerRow * $0.height }
            ?? Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        images.setObject(image, forKey: key as NSString, cost: max(pixels, 1))
    }

    private struct KeyMaterial: Encodable {
        let accountNamespace: String
        let boardID: String
        let graphID: String
        let expressions: [GraphExpression]
        let viewport: GraphViewport
        let settings: GraphSettings
        let pixelWidth: Int
        let pixelHeight: Int
        let renderVersion: Int
        let appearance: Int
    }
}
