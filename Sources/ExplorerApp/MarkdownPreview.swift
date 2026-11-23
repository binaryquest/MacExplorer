import AppKit
import JavaScriptCore
import WebKit

@MainActor
final class MarkdownPreview: WKWebView, WKNavigationDelegate {
    private var renderTask: Task<Void, Never>?

    init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        super.init(frame: frame, configuration: config)
        navigationDelegate = self
        underPageBackgroundColor = .controlBackgroundColor
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    func clear() {
        renderTask?.cancel()
        stopLoading()
        isHidden = true
    }

    func display(_ url: URL) {
        clear()
        renderTask = Task { [weak self] in
            let page = await Task.detached(priority: .userInitiated) { Self.page(at: url) }.value
            guard !Task.isCancelled, let self else { return }
            loadHTMLString(page, baseURL: url.deletingLastPathComponent())
            isHidden = false
        }
    }

    nonisolated private static func page(at url: URL) -> String {
        guard let scriptURL = Bundle.main.url(forResource: "markdown-it.min", withExtension: "js", subdirectory: "Markdown"),
              let library = try? String(contentsOf: scriptURL, encoding: .utf8),
              let context = JSContext() else { return "无法载入 Markdown 预览。" }
        var encoding = String.Encoding.utf8
        guard let source = try? String(contentsOf: url, usedEncoding: &encoding) else { return "无法读取文件。" }
        context.evaluateScript(library)
        let parser = context.evaluateScript("markdownit({html:false})")
        guard let html = parser?.invokeMethod("render", withArguments: [source])?.toString(), context.exception == nil else { return "无法解析文件。" }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src file: data:">
        <style>
        :root { color-scheme: light dark; background: white; color: #242424; }
        body { margin: 0; padding: 6px 16px 24px; font: 14px/1.62 -apple-system, sans-serif; overflow-wrap: anywhere; }
        h1,h2,h3,h4 { line-height: 1.28; margin: 1.1em 0 .5em; }
        body > :first-child { margin-top: .4em; }
        hr { border: 0; border-top: 1px solid #d8dce0; }
        blockquote { margin-left: 0; padding-left: 12px; border-left: 2px solid #d8dce0; }
        pre { overflow-x: auto; } code { font: .93em ui-monospace, monospace; }
        table { border-collapse: collapse; } th,td { border: 1px solid #d8dce0; padding: 4px 8px; }
        img { max-width: 100%; } a { color: LinkText; }
        @media (prefers-color-scheme: dark) { :root { background: #1e1e1e; color: #eee; } }
        </style></head><body>\(html)</body></html>
        """
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.navigationType == .other ? .allow : .cancel)
    }
}
