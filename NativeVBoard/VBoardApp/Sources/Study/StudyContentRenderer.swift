import SwiftUI
@preconcurrency import WebKit

/// Renders canonical study Markdown without rewriting it. Markdown, TeX, and
/// chemistry remain source data while the bundled web renderer is only a
/// presentation surface.
struct StudyContentView: View {
    let source: String
    var maximumWidth: CGFloat = 760

    @State private var measuredHeight: CGFloat = 80

    var body: some View {
        StudyContentWebView(source: source, measuredHeight: $measuredHeight)
            .frame(maxWidth: maximumWidth)
            .frame(height: max(44, measuredHeight))
            .accessibilityLabel("Study content")
    }
}

private struct StudyContentWebView: UIViewRepresentable {
    let source: String
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(measuredHeight: $measuredHeight)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "contentHeight")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.loadedSource = source
        load(source: source, into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.measuredHeight = $measuredHeight
        guard context.coordinator.loadedSource != source else { return }
        context.coordinator.loadedSource = source
        load(source: source, into: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "contentHeight")
        webView.navigationDelegate = nil
    }

    private func load(source: String, into webView: WKWebView) {
        webView.loadHTMLString(StudyContentDocument.html(source: source),
                               baseURL: Bundle.main.resourceURL)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var measuredHeight: Binding<CGFloat>
        var loadedSource = ""

        init(measuredHeight: Binding<CGFloat>) {
            self.measuredHeight = measuredHeight
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "contentHeight",
                  let number = message.body as? NSNumber else { return }
            let height = max(44, CGFloat(truncating: number).rounded(.up))
            if abs(measuredHeight.wrappedValue - height) > 0.5 {
                measuredHeight.wrappedValue = height
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Study answers are display-only. Local assets may load, but links
            // cannot navigate or replace the embedded answer.
            decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
        }
    }
}

enum StudyContentDocument {
    /// Base64 keeps arbitrary model output out of executable HTML. The shared
    /// renderer disables Markdown HTML, sanitizes output, and runs KaTeX with
    /// trust disabled.
    static func html(source: String) -> String {
        let encoded = Data(source.utf8).base64EncodedString()
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src data:; connect-src 'none'">
          <link rel="stylesheet" href="katex/katex.min.css">
          <style>
            :root { color-scheme: light dark; }
            html, body { margin: 0; padding: 0; background: transparent; }
            body {
              color: -apple-system-label;
              font: -apple-system-body;
              font-family: -apple-system, BlinkMacSystemFont, sans-serif;
              line-height: 1.48;
              overflow-wrap: anywhere;
              -webkit-text-size-adjust: 100%;
            }
            h1, h2, h3, h4 { line-height: 1.18; margin: 1em 0 .42em; }
            h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }
            p { margin: .45em 0 .8em; }
            ul, ol { padding-left: 1.45em; }
            li { margin: .25em 0; }
            blockquote {
              margin: .8em 0; padding: .15em 0 .15em .85em;
              border-left: 3px solid -apple-system-tertiary-label;
              color: -apple-system-secondary-label;
            }
            code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
            pre { overflow-x: auto; padding: .75em; border-radius: .6em; background: rgba(127,127,127,.12); }
            a { color: -apple-system-link; }
            .study-math-display, .katex-display { overflow-x: auto; overflow-y: hidden; padding: .16em 0; }
            .study-notation-fallback { font-family: Georgia, serif; }
            table { border-collapse: collapse; max-width: 100%; }
            th, td { border: 1px solid -apple-system-separator; padding: .35em .5em; }
          </style>
          <script src="katex/katex.min.js"></script>
          <script src="katex/mhchem.min.js"></script>
          <script src="markdown-it/markdown-it.min.js"></script>
          <script src="markdown-it-texmath/texmath.js"></script>
          <script src="dompurify/purify.min.js"></script>
          <script src="study-render.js"></script>
        </head>
        <body>
          <main id="content" aria-live="polite"></main>
          <script>
            (() => {
              const bytes = Uint8Array.from(atob('\(encoded)'), character => character.charCodeAt(0));
              const source = new TextDecoder().decode(bytes);
              const target = document.getElementById('content');
              target.replaceChildren(globalThis.renderStudyMarkdown(source));
              const reportHeight = () => {
                const height = Math.ceil(Math.max(document.body.scrollHeight, document.documentElement.scrollHeight));
                window.webkit.messageHandlers.contentHeight.postMessage(height);
              };
              new ResizeObserver(reportHeight).observe(target);
              requestAnimationFrame(() => requestAnimationFrame(reportHeight));
              document.fonts.ready.then(reportHeight);
            })();
          </script>
        </body>
        </html>
        """
    }
}

/// A lightweight, cached presentation for text objects that live directly on
/// the zoomable canvas. Full study sheets use the bundled KaTeX/mhchem web
/// renderer above. Canvas cards need a synchronous Core Animation surface, so
/// this formatter derives readable display text without mutating or replacing
/// the canonical Markdown stored in `CanvasObject.sourceMarkdown`.
enum CompactStudyPresentation {
    private static let replacements: [(String, String)] = [
        (#"\rightleftharpoons"#, "⇌"), (#"\leftrightarrow"#, "↔"),
        (#"\rightarrow"#, "→"), (#"\to"#, "→"),
        (#"\sum"#, "∑"), (#"\int"#, "∫"), (#"\infty"#, "∞"),
        (#"\pm"#, "±"), (#"\times"#, "×"), (#"\cdot"#, "·"),
        (#"\leq"#, "≤"), (#"\geq"#, "≥"), (#"\neq"#, "≠"),
        (#"\alpha"#, "α"), (#"\beta"#, "β"), (#"\gamma"#, "γ"),
        (#"\delta"#, "δ"), (#"\theta"#, "θ"), (#"\lambda"#, "λ"),
        (#"\mu"#, "μ"), (#"\pi"#, "π"), (#"\sigma"#, "σ"),
        (#"\phi"#, "φ"), (#"\omega"#, "ω")
    ]

    static func readableText(from source: String) -> String {
        var value = source
        // Preserve the meaning of common compact expressions even when a
        // native text layer cannot run the full HTML math layout engine.
        value = replacing(#"\\frac\{([^{}]+)\}\{([^{}]+)\}"#, in: value, with: "($1)/($2)")
        value = replacing(#"\\sqrt\{([^{}]+)\}"#, in: value, with: "√($1)")
        value = replacing(#"\^\{([^{}]+)\}"#, in: value, with: "^$1")
        value = replacing(#"_\{([^{}]+)\}"#, in: value, with: "_$1")
        for command in ["text", "mathrm", "mathbf", "operatorname", "ce"] {
            value = replacing(#"\\"# + command + #"\{([^{}]*)\}"#, in: value, with: "$1")
        }
        for (pattern, replacement) in replacements {
            value = value.replacingOccurrences(of: pattern, with: replacement)
        }
        value = value
            .replacingOccurrences(of: "\\(", with: "")
            .replacingOccurrences(of: "\\)", with: "")
            .replacingOccurrences(of: "\\[", with: "")
            .replacingOccurrences(of: "\\]", with: "")
            .replacingOccurrences(of: "$$", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
        value = replacing(#"(?m)^#{1,6}\s*"#, in: value, with: "")
        value = replacing(#"\\([A-Za-z]+)"#, in: value, with: "$1")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    static func layer(for object: CanvasObject,
                      frame: CGRect,
                      contentsScale: CGFloat) -> CALayer {
        let card = CALayer()
        card.frame = frame
        card.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96).cgColor
        card.borderColor = UIColor.separator.withAlphaComponent(0.32).cgColor
        card.borderWidth = 2
        card.cornerRadius = min(28, max(12, frame.height * 0.045))
        card.shadowColor = UIColor.black.cgColor
        card.shadowOpacity = 0.10
        card.shadowRadius = 12
        card.shadowOffset = CGSize(width: 0, height: 5)

        let textLayer = CATextLayer()
        let source = object.sourceMarkdown ?? object.text ?? ""
        let isPractice = object.role == "ai_practice_problem"
        let requestedSize = CGFloat(object.fontSize ?? 32)
        let fontSize = isPractice ? max(58, requestedSize) : max(38, requestedSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(5, fontSize * 0.16)
        paragraph.paragraphSpacing = max(7, fontSize * 0.20)
        let color = UIColor(svgHex: object.color ?? "#183153")
        textLayer.string = NSAttributedString(
            string: readableText(from: source),
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize,
                                         weight: isPractice ? .semibold : .regular),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
        textLayer.isWrapped = true
        textLayer.truncationMode = .end
        textLayer.alignmentMode = .left
        textLayer.contentsScale = contentsScale
        let horizontalInset = max(24, min(46, frame.width * 0.045))
        let verticalInset = max(20, min(38, frame.height * 0.07))
        textLayer.frame = card.bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        card.addSublayer(textLayer)
        return card
    }

    private static func replacing(_ pattern: String,
                                  in source: String,
                                  with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.stringByReplacingMatches(in: source,
                                                   range: range,
                                                   withTemplate: template)
    }
}
