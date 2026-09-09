import Foundation
import UIKit

struct SVGPath: Equatable {
    let id: String?
    let d: String                 // Canonical, untouched server geometry.
    let fill: UIColor
    let fillRule: CAShapeLayerFillRule
    let dataInk: String?
}

struct SVGDocument: Equatable {
    let viewBox: CGRect
    let paths: [SVGPath]

    static func parse(_ source: String) throws -> SVGDocument {
        let reader = SVGReader()
        guard let data = source.data(using: .utf8) else { throw SVGError.invalidDocument }
        let parser = XMLParser(data: data); parser.delegate = reader
        guard parser.parse(), let document = reader.document else { throw SVGError.invalidDocument }
        return document
    }
}

enum SVGError: Error { case invalidDocument, unsupportedPath }

private final class SVGReader: NSObject, XMLParserDelegate {
    private var viewBox = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var paths: [SVGPath] = []
    var document: SVGDocument? { SVGDocument(viewBox: viewBox, paths: paths) }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
        if name == "svg", let raw = attributes["viewBox"] {
            let parts = raw.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if parts.count == 4, parts[2] > 0, parts[3] > 0 { viewBox = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]) }
        }
        guard name == "path", let d = attributes["d"], !d.isEmpty else { return }
        paths.append(SVGPath(id: attributes["id"], d: d, fill: UIColor(svgHex: attributes["fill"] ?? "#000000"), fillRule: attributes["fill-rule"] == "evenodd" ? .evenOdd : .nonZero, dataInk: attributes["data-ink"]))
    }
}

extension UIColor {
    convenience init(svgHex: String) {
        let hex = svgHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { self.init(white: 0, alpha: 1); return }
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// Converts only at display time. `SVGPath.d` is never changed or regenerated.
enum SVGPathParser {
    private static var cache: [String: CGPath] = [:]
    private static var cacheOrder: [String] = []
    private static let lock = NSLock()
    private static let cacheLimit = 4096

    static func cachedPath(from d: String, hits: () -> Void = {}, misses: () -> Void = {}) throws -> CGPath {
        lock.lock()
        if let cached = cache[d] {
            cacheOrder.removeAll { $0 == d }
            cacheOrder.append(d)
            lock.unlock()
            hits()
            return cached
        }
        lock.unlock()
        let parsed = try path(from: d)
        lock.lock()
        // Another thread may have won the race; either instance is equivalent.
        let value = cache[d] ?? parsed
        cache[d] = value
        cacheOrder.removeAll { $0 == d }
        cacheOrder.append(d)
        if cacheOrder.count > cacheLimit, let evicted = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        lock.unlock()
        misses()
        return value
    }

    static func path(from d: String) throws -> CGPath {
        let tokens = Tokenizer(d).tokens
        var index = 0, command: Character?; let path = CGMutablePath()
        var point = CGPoint.zero, subpathStart = CGPoint.zero
        func number() throws -> CGFloat { guard index < tokens.count, case .number(let n) = tokens[index] else { throw SVGError.unsupportedPath }; index += 1; return n }
        func isNumber() -> Bool { index < tokens.count && tokens[index].isNumber }
        func target(_ relative: Bool) throws -> CGPoint { let x = try number(), y = try number(); return relative ? CGPoint(x: point.x + x, y: point.y + y) : CGPoint(x: x, y: y) }
        while index < tokens.count {
            if case .command(let incoming) = tokens[index] { command = incoming; index += 1 }
            guard let letter = command else { throw SVGError.unsupportedPath }
            let relative = letter.isLowercase; let op = letter.uppercased()
            switch op {
            case "M":
                let first = try target(relative); path.move(to: first); point = first; subpathStart = first
                while isNumber() { let next = try target(relative); path.addLine(to: next); point = next }
            case "L": while isNumber() { let next = try target(relative); path.addLine(to: next); point = next }
            case "H": while isNumber() { let x = try number(); point.x = relative ? point.x + x : x; path.addLine(to: point) }
            case "V": while isNumber() { let y = try number(); point.y = relative ? point.y + y : y; path.addLine(to: point) }
            case "C": while isNumber() { let a = try target(relative), b = try target(relative), end = try target(relative); path.addCurve(to: end, control1: a, control2: b); point = end }
            case "Q": while isNumber() { let control = try target(relative), end = try target(relative); path.addQuadCurve(to: end, control: control); point = end }
            case "Z": path.closeSubpath(); point = subpathStart
            default: throw SVGError.unsupportedPath
            }
        }
        return path
    }
}

private enum SVGToken { case command(Character), number(CGFloat); var isNumber: Bool { if case .number = self { return true }; return false } }
private struct Tokenizer {
    let tokens: [SVGToken]
    init(_ input: String) {
        let pattern = "[MmLlHhVvCcQqZz]|[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+\\.?)(?:[eE][-+]?[0-9]+)?"
        let range = NSRange(input.startIndex..., in: input)
        let regex = try! NSRegularExpression(pattern: pattern)
        tokens = regex.matches(in: input, range: range).compactMap { match in
            let value = String(input[Range(match.range, in: input)!])
            if value.count == 1, let character = value.first, character.isLetter { return .command(character) }
            return Double(value).map { .number(CGFloat($0)) }
        }
    }
}
