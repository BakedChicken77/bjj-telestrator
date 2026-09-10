import Capacitor
import WebKit

final class BJJViewController: CAPBridgeViewController {
    private var instanceConfiguration: InstanceConfiguration?

    override func webViewConfiguration(for instanceConfiguration: InstanceConfiguration) -> WKWebViewConfiguration {
        self.instanceConfiguration = instanceConfiguration
        return super.webViewConfiguration(for: instanceConfiguration)
    }

    override func webView(with frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {
        guard let instanceConfiguration,
              let scheme = instanceConfiguration.localURL.scheme,
              let fallback = configuration.urlSchemeHandler(forURLScheme: scheme) else {
            return super.webView(with: frame, configuration: configuration)
        }
        // WebKit cannot replace a handler after its scheme has been registered,
        // even after setURLSchemeHandler(nil). Build an equivalent fresh config
        // through Capacitor's factory and preserve the bridge's script controller.
        let mediaConfiguration = super.webViewConfiguration(for: instanceConfiguration)
        mediaConfiguration.userContentController = configuration.userContentController
        mediaConfiguration.setURLSchemeHandler(BJJAssetHandler(fallback: fallback), forURLScheme: scheme)
        return super.webView(with: frame, configuration: mediaConfiguration)
    }

    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(BJJNativePlugin())
        webView?.scrollView.bounces = false
    }
}
