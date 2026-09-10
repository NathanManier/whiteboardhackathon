import PDFKit
import UIKit

/// Locked, high-fidelity source surface for a PDF-backed board. The PDF bytes
/// remain canonical; this view only renders the requested page. V-Board user
/// objects live in independent layers above it.
final class PDFPageRenderView: UIView {
    private var document: PDFDocument?
    private var pageIndex = 0
    private var representedDigest: Int?
    private(set) var renderState: PDFRenderState = .unloaded

    override class var layerClass: AnyClass { CATiledLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .white
        isUserInteractionEnabled = false
        // Imported professor transforms use the board's top-left world origin.
        // Keep the PDF backing layer on that same origin so scaling does not
        // drift around UIView's default center anchor point.
        layer.anchorPoint = .zero
        layer.position = .zero
        if let tiled = layer as? CATiledLayer {
            tiled.tileSize = CGSize(width: 768, height: 768)
            tiled.levelsOfDetail = 4
            tiled.levelsOfDetailBias = 4
            tiled.needsDisplayOnBoundsChange = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(data: Data, pageIndex: Int = 0) {
        let digest = data.hashValue ^ pageIndex
        guard representedDigest != digest else { return }
        representedDigest = digest
        document = PDFDocument(data: data)
        self.pageIndex = pageIndex
        renderState = document?.page(at: pageIndex) == nil ? .failed : .ready
        #if DEBUG
        let page = document?.page(at: pageIndex)
        print("[VBoard] PDF BOARD LOAD bytes=\(data.count) pages=\(document?.pageCount ?? 0) pageIndex=\(pageIndex) pageBounds=\(String(describing: page?.bounds(for: .cropBox))) rotation=\(page?.rotation ?? 0) state=\(renderState.rawValue) viewFrame=\(frame) viewBounds=\(bounds) layerPosition=\(layer.position) anchor=\(layer.anchorPoint) hidden=\(isHidden) opacity=\(layer.opacity)")
        #endif
        layer.setNeedsDisplay()
    }

    func clear() {
        representedDigest = nil
        document = nil
        renderState = .unloaded
        layer.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0,
              let context = UIGraphicsGetCurrentContext(),
              let page = document?.page(at: pageIndex),
              let pageRef = page.pageRef else { return }
        context.saveGState()
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)
        // UIView drawing begins in top-left/Y-down space while CGPDFPage is
        // bottom-left/Y-up. Convert once, then ask Core Graphics for the exact
        // crop-box/rotation transform into the board-local rectangle. The
        // selection proxy uses this same entire board rectangle.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let pageTransform = pageRef.getDrawingTransform(
            .cropBox,
            rect: CGRect(origin: .zero, size: bounds.size),
            rotate: 0,
            preserveAspectRatio: false
        )
        context.concatenate(pageTransform)
        context.drawPDFPage(pageRef)
        context.restoreGState()
    }
}

enum PDFRenderState: String {
    case unloaded
    case ready
    case failed
}

struct PDFPageBoardTransform: Equatable {
    let boardSize: CGSize

    func pdfTopLeftToBoard(_ point: CGPoint, pdfDisplaySize: CGSize) -> CGPoint {
        guard pdfDisplaySize.width > 0, pdfDisplaySize.height > 0 else { return .zero }
        return CGPoint(x: point.x / pdfDisplaySize.width * boardSize.width,
                       y: point.y / pdfDisplaySize.height * boardSize.height)
    }

    func boardToPDFTopLeft(_ point: CGPoint, pdfDisplaySize: CGSize) -> CGPoint {
        guard boardSize.width > 0, boardSize.height > 0 else { return .zero }
        return CGPoint(x: point.x / boardSize.width * pdfDisplaySize.width,
                       y: point.y / boardSize.height * pdfDisplaySize.height)
    }
}

enum PDFBoardSource {
    static let logicalID = "pdf-page-1"

    /// The SVG reader deliberately ignores image nodes. Add one transparent
    /// geometry proxy to the native scene so selection, lasso, transforms,
    /// and study bbox construction use the same stable ID as the server-side
    /// PDF image node without rasterizing the PDF into professor ink.
    static func selectableDocument(_ document: SVGDocument, sourceKind: BoardSourceKind) -> SVGDocument {
        guard sourceKind.isPDF,
              !document.paths.contains(where: { $0.id == logicalID }) else { return document }
        let box = document.viewBox
        let d = "M \(box.minX) \(box.minY) L \(box.maxX) \(box.minY) L \(box.maxX) \(box.maxY) L \(box.minX) \(box.maxY) Z"
        let proxy = SVGPath(id: logicalID, d: d, fill: .clear, fillRule: .nonZero,
                            dataInk: "pdf-source")
        return SVGDocument(viewBox: box, paths: document.paths + [proxy])
    }

    static func apply(transform: ObjectTransform?, to view: UIView) {
        guard let transform, transform.deleted != true else {
            view.isHidden = transform?.deleted == true
            view.layer.setAffineTransform(.identity)
            return
        }
        view.isHidden = false
        view.layer.setAffineTransform(CGAffineTransform.identity
            .translatedBy(x: CGFloat(transform.x), y: CGFloat(transform.y))
            .scaledBy(x: CGFloat(transform.scaleX ?? 1), y: CGFloat(transform.scaleY ?? 1)))
    }
}
