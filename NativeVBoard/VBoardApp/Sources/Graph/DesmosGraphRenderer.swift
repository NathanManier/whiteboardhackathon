@preconcurrency import WebKit
import Foundation
import UIKit

private final class WeakGraphRendererBox: @unchecked Sendable {
    weak var value: DesmosGraphRenderer?
}

private final class GraphScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private let target: WeakGraphRendererBox

    init(target: WeakGraphRendererBox) {
        self.target = target
        super.init()
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        let target = target
        Task { @MainActor in target.value?.receiveScriptMessage(message) }
    }
}

struct DesmosConfiguration: Equatable, Sendable {
    static let stableAPIVersion = "v1.12"
    static let scriptBaseURL = URL(string: "https://www.desmos.com/api/v1.12/calculator.js")!

    let apiKey: String?

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG
        let configured = environment["VBoardDesmosAPIKey"]
            ?? bundle.object(forInfoDictionaryKey: "VBoardDesmosAPIKey") as? String
        #else
        let configured = bundle.object(forInfoDictionaryKey: "VBoardDesmosAPIKey") as? String
        #endif
        apiKey = Self.validatedAPIKey(configured)
    }

    init(apiKey: String?) {
        self.apiKey = Self.validatedAPIKey(apiKey)
    }

    var isConfigured: Bool { apiKey != nil }

    var scriptURL: URL? {
        guard let apiKey,
              var components = URLComponents(url: Self.scriptBaseURL,
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "apiKey", value: apiKey)]
        return components.url
    }

    private static func validatedAPIKey(_ configured: String?) -> String? {
        let value = configured?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = value?.lowercased() ?? ""
        guard let value, value.count >= 8,
              !lowered.contains("placeholder"), !lowered.contains("replace"),
              !lowered.contains("your_api_key"), !value.contains("$("), !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct DesmosBridgeMessage: Equatable, Sendable {
    enum Event: String, Sendable {
        case ready
        case viewportChanged
        case error
    }

    let event: Event
    let graphID: String
    let nonce: String
    let viewport: GraphViewport?
    let errorCode: String?

    static func decode(_ body: Any, expectedGraphID: String,
                       expectedNonce: String) -> DesmosBridgeMessage? {
        guard let value = body as? [String: Any], value.count <= 8,
              (value["version"] as? NSNumber)?.intValue == 1,
              let eventRaw = value["event"] as? String,
              let event = Event(rawValue: eventRaw),
              let graphID = value["graphID"] as? String,
              graphID == expectedGraphID, graphID.count <= 128,
              let nonce = value["nonce"] as? String,
              nonce == expectedNonce, nonce.count <= 128 else { return nil }

        var viewport: GraphViewport?
        if let bounds = value["viewport"] as? [String: Any] {
            guard bounds.count <= 4,
                  let xMin = finite(bounds["xMin"]), let xMax = finite(bounds["xMax"]),
                  let yMin = finite(bounds["yMin"]), let yMax = finite(bounds["yMax"]),
                  xMax > xMin, yMax > yMin,
                  max(abs(xMin), abs(xMax), abs(yMin), abs(yMax)) <= 10_000_000 else {
                return nil
            }
            viewport = GraphViewport(xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax)
        }
        let errorCode = (value["code"] as? String).map { String($0.prefix(96)) }
        return DesmosBridgeMessage(event: event, graphID: graphID, nonce: nonce,
                                   viewport: viewport, errorCode: errorCode)
    }

    private static func finite(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
}

@MainActor
final class DesmosGraphRenderer: NSObject, GraphRendererProvider {
    let identifier = "desmos-v1.12"
    private(set) var view: UIView
    var isAvailable: Bool { configuration.isConfigured }

    private let configuration: DesmosConfiguration
    private let webView: WKWebView
    private let messageProxy: GraphScriptMessageProxy
    private let messageName = "vboardGraph"
    private var currentGraph: GraphObject?
    private var currentNonce = UUID().uuidString.lowercased()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyTimeout: Task<Void, Never>?
    private var cachedViewport: GraphViewport?
    private var isMounted = false
    private var allowsBootstrapNavigation = false

    init(configuration: DesmosConfiguration = DesmosConfiguration()) {
        self.configuration = configuration
        let weakTarget = WeakGraphRendererBox()
        let messageProxy = GraphScriptMessageProxy(target: weakTarget)
        self.messageProxy = messageProxy
        let controller = WKUserContentController()
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webConfiguration.userContentController = controller
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        self.webView = webView
        self.view = webView
        super.init()
        weakTarget.value = self
        controller.add(messageProxy, name: messageName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func mount(graph: GraphObject, in frame: CGRect) async throws {
        guard isAvailable, let scriptURL = configuration.scriptURL else {
            throw GraphRendererError.unavailable
        }
        if isMounted, currentGraph?.id == graph.id {
            webView.frame = frame
            try await update(graph: graph)
            return
        }
        unmountRuntimeOnly()
        currentGraph = graph
        cachedViewport = graph.viewport
        currentNonce = UUID().uuidString.lowercased()
        webView.frame = frame
        webView.isUserInteractionEnabled = false
        isMounted = true
        allowsBootstrapNavigation = true
        let html = Self.wrapperHTML(scriptURL: scriptURL,
                                    graphID: graph.id, nonce: currentNonce)
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.desmos.com"))
        try await waitUntilReady()
        try await update(graph: graph)
    }

    func update(graph: GraphObject) async throws {
        guard isMounted, graph.id == currentGraph?.id else {
            throw GraphRendererError.provider("not mounted")
        }
        currentGraph = graph
        cachedViewport = graph.viewport
        let payload = Self.payload(for: graph)
        _ = try await webView.callAsyncJavaScript(
            "return window.vboardGraphAdapter.setGraph(graph);",
            arguments: ["graph": payload], in: nil, contentWorld: .page
        )
    }

    func setInteractive(_ interactive: Bool) async throws {
        guard isMounted else { throw GraphRendererError.provider("not mounted") }
        webView.isUserInteractionEnabled = interactive
        _ = try await webView.callAsyncJavaScript(
            "return window.vboardGraphAdapter.setInteractive(interactive);",
            arguments: ["interactive": interactive], in: nil, contentWorld: .page
        )
    }

    func resize(to frame: CGRect) async throws {
        webView.frame = frame
        guard isMounted else { return }
        _ = try await webView.callAsyncJavaScript(
            "return window.vboardGraphAdapter.resize();",
            arguments: [:], in: nil, contentWorld: .page
        )
    }

    func readViewport() async -> GraphViewport? {
        guard isMounted else { return cachedViewport }
        do {
            let value = try await webView.callAsyncJavaScript(
                "return window.vboardGraphAdapter.getViewport();",
                arguments: [:], in: nil, contentWorld: .page
            )
            if let dictionary = value as? [String: Any],
               let parsed = Self.viewport(from: dictionary) {
                cachedViewport = parsed
            }
        } catch { }
        return cachedViewport
    }

    func captureSnapshot() async throws -> UIImage {
        guard isMounted else { throw GraphRendererError.provider("not mounted") }
        let value = try await webView.callAsyncJavaScript(
            "return await window.vboardGraphAdapter.snapshot('png');",
            arguments: [:], in: nil, contentWorld: .page
        )
        guard let dataURI = value as? String,
              dataURI.count <= 24_000_000,
              let comma = dataURI.firstIndex(of: ","),
              dataURI[..<comma].contains("image/png"),
              let data = Data(base64Encoded: String(dataURI[dataURI.index(after: comma)...])),
              let image = UIImage(data: data) else {
            throw GraphRendererError.provider("snapshot")
        }
        return image
    }

    func captureSVG() async throws -> String {
        guard isMounted else { throw GraphRendererError.provider("not mounted") }
        let value = try await webView.callAsyncJavaScript(
            "return await window.vboardGraphAdapter.snapshot('svg');",
            arguments: [:], in: nil, contentWorld: .page
        )
        guard let svg = value as? String, svg.count <= 8_000_000,
              svg.hasPrefix("<svg") || svg.hasPrefix("<?xml") else {
            throw GraphRendererError.provider("snapshot")
        }
        return svg
    }

    func unmount() {
        unmountRuntimeOnly()
        currentGraph = nil
        cachedViewport = nil
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            readyTimeout?.cancel()
            readyTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard let self, let continuation = self.readyContinuation else { return }
                self.readyContinuation = nil
                continuation.resume(throwing: GraphRendererError.unavailable)
            }
        }
    }

    private func unmountRuntimeOnly() {
        readyTimeout?.cancel()
        readyTimeout = nil
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        if isMounted {
            webView.evaluateJavaScript("window.vboardGraphAdapter && window.vboardGraphAdapter.destroy();")
        }
        webView.stopLoading()
        webView.removeFromSuperview()
        webView.isUserInteractionEnabled = false
        isMounted = false
        allowsBootstrapNavigation = false
    }

    private static func payload(for graph: GraphObject) -> [String: Any] {
        [
            "id": graph.id,
            "expressions": graph.expressions.prefix(12).map { expression in
                ["id": expression.id,
                 "latex": String(expression.latex.prefix(2_000)),
                 "visible": expression.visible] as [String: Any]
            },
            "viewport": [
                "xMin": graph.viewport.xMin, "xMax": graph.viewport.xMax,
                "yMin": graph.viewport.yMin, "yMax": graph.viewport.yMax
            ],
            "settings": [
                "showXAxis": graph.settings.showXAxis,
                "showYAxis": graph.settings.showYAxis,
                "showGrid": graph.settings.showGrid
            ]
        ]
    }

    private static func viewport(from value: [String: Any]) -> GraphViewport? {
        func finite(_ key: String) -> Double? {
            guard let number = value[key] as? NSNumber else { return nil }
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        guard let xMin = finite("xMin"), let xMax = finite("xMax"),
              let yMin = finite("yMin"), let yMax = finite("yMax"),
              xMax > xMin, yMax > yMin else { return nil }
        return GraphViewport(xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax)
    }

    private static func wrapperHTML(scriptURL: URL, graphID: String, nonce: String) -> String {
        let escapedURL = scriptURL.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let graphJSON = jsonString(graphID)
        let nonceJSON = jsonString(nonce)
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src https://www.desmos.com 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src https://www.desmos.com data:; connect-src https://www.desmos.com https://*.desmos.com;">
        <style>html,body,#calculator{margin:0;width:100%;height:100%;overflow:hidden;background:#fff}*{box-sizing:border-box}</style>
        <script src="\(escapedURL)"></script>
        </head><body><div id="calculator"></div><script>
        (() => {
          'use strict';
          const graphID = \(graphJSON);
          const nonce = \(nonceJSON);
          const send = (event, extra = {}) => window.webkit.messageHandlers.vboardGraph.postMessage(Object.assign({version:1,event,graphID,nonce}, extra));
          let calculator = null;
          let knownIDs = new Set();
          let viewportTimer = null;
          const bounds = () => {
            if (!calculator) return null;
            const m = calculator.graphpaperBounds.mathCoordinates;
            return {xMin:m.left,xMax:m.right,yMin:m.bottom,yMax:m.top};
          };
          try {
            if (!window.Desmos || !window.Desmos.GraphingCalculator) throw new Error('provider_unavailable');
            calculator = window.Desmos.GraphingCalculator(document.getElementById('calculator'), {
              autosize:false, expressions:false, settingsMenu:false, keypad:false,
              zoomButtons:true, expressionsTopbar:false, pointsOfInterest:true,
              trace:false, border:false, lockViewport:false
            });
            calculator.observe('graphpaperBounds', () => {
              clearTimeout(viewportTimer);
              viewportTimer = setTimeout(() => send('viewportChanged', {viewport:bounds()}), 100);
            });
            window.vboardGraphAdapter = {
              setGraph(graph) {
                if (!graph || graph.id !== graphID || !Array.isArray(graph.expressions) || graph.expressions.length > 12) return false;
                const next = new Set();
                const expressions = [];
                for (const value of graph.expressions) {
                  if (!value || typeof value.id !== 'string' || value.id.length > 128 || typeof value.latex !== 'string' || value.latex.length > 2000) continue;
                  next.add(value.id);
                  expressions.push({id:value.id, latex:value.latex, hidden:value.visible === false});
                }
                const removed = [...knownIDs].filter(id => !next.has(id)).map(id => ({id}));
                if (removed.length) calculator.removeExpressions(removed);
                calculator.setExpressions(expressions);
                knownIDs = next;
                const v = graph.viewport;
                if (v && [v.xMin,v.xMax,v.yMin,v.yMax].every(Number.isFinite) && v.xMax > v.xMin && v.yMax > v.yMin) {
                  calculator.setMathBounds({left:v.xMin,right:v.xMax,bottom:v.yMin,top:v.yMax});
                }
                const s = graph.settings || {};
                calculator.updateSettings({xAxisNumbers:!!s.showXAxis,yAxisNumbers:!!s.showYAxis,showGrid:!!s.showGrid});
                calculator.resize();
                return true;
              },
              setInteractive(enabled) {
                const node = document.getElementById('calculator');
                node.style.pointerEvents = enabled ? 'auto' : 'none';
                return true;
              },
              getViewport() { return bounds(); },
              resize() { if (calculator) calculator.resize(); return true; },
              snapshot(format) {
                return new Promise((resolve, reject) => {
                  if (!calculator) { reject(new Error('not_ready')); return; }
                  calculator.asyncScreenshot({format:format === 'svg' ? 'svg' : 'png', targetPixelRatio:2}, value => value ? resolve(value) : reject(new Error('snapshot_failed')));
                });
              },
              destroy() {
                clearTimeout(viewportTimer);
                if (calculator) { calculator.destroy(); calculator = null; }
                knownIDs.clear();
                return true;
              }
            };
            send('ready');
          } catch (_) { send('error', {code:'provider_unavailable'}); }
        })();
        </script></body></html>
        """
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(encoded.dropFirst().dropLast())
    }

    fileprivate func receiveScriptMessage(_ message: WKScriptMessage) {
        guard message.name == messageName,
              message.webView === webView,
              message.frameInfo.isMainFrame,
              let graph = currentGraph,
              let event = DesmosBridgeMessage.decode(
                message.body, expectedGraphID: graph.id,
                expectedNonce: currentNonce
              ) else { return }
        switch event.event {
        case .ready:
            readyTimeout?.cancel()
            readyTimeout = nil
            let continuation = readyContinuation
            readyContinuation = nil
            continuation?.resume()
        case .viewportChanged:
            if let viewport = event.viewport { cachedViewport = viewport }
        case .error:
            readyTimeout?.cancel()
            readyTimeout = nil
            let continuation = readyContinuation
            readyContinuation = nil
            continuation?.resume(throwing: GraphRendererError.unavailable)
        }
    }
}

extension DesmosGraphRenderer: WKNavigationDelegate, WKUIDelegate {
    nonisolated func webView(_ webView: WKWebView,
                            decidePolicyFor navigationAction: WKNavigationAction,
                            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, webView === self.webView,
                  navigationAction.targetFrame?.isMainFrame != false else {
                decisionHandler(.cancel); return
            }
            let isBootstrap = self.allowsBootstrapNavigation
                && navigationAction.navigationType == .other
                && (navigationAction.request.url?.scheme == "about"
                    || navigationAction.request.url?.absoluteString == "https://www.desmos.com/")
            if isBootstrap { self.allowsBootstrapNavigation = false }
            decisionHandler(isBootstrap ? .allow : .cancel)
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                            createWebViewWith configuration: WKWebViewConfiguration,
                            for navigationAction: WKNavigationAction,
                            windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}
