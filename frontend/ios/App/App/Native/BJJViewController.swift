import Capacitor
import WebKit

final class BJJViewController: CAPBridgeViewController {
    override func webView(with frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {
        if let fallback = configuration.urlSchemeHandler(forURLScheme: "capacitor") {
            configuration.setURLSchemeHandler(nil, forURLScheme: "capacitor")
            configuration.setURLSchemeHandler(BJJAssetHandler(fallback: fallback), forURLScheme: "capacitor")
        }
        return super.webView(with: frame, configuration: configuration)
    }
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(BJJNativePlugin())
        webView?.scrollView.bounces = false
    }
}
