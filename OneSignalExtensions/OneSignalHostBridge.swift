import SwiftUI
import UIKit
import OneSignalFramework

@available(iOS 16.0, *)
public enum OneSignalHostBridge {

    public static var setOrientationLock: (UIInterfaceOrientationMask) -> Void = { _ in }

    public static var makeSplash: (_ isLoading: Bool) -> AnyView = { _ in
        AnyView(Color.black.ignoresSafeArea())
    }

    /// Opaque configuration key provided by the host app.
    public static var extensionsKey: String = ""
}

@available(iOS 16.0, *)
public extension OneSignal {

    /// Wires host app integration points used by OneSignal extensions.
    /// Call once from `application(_:didFinishLaunchingWithOptions:)`.
    static func configureAppBridge(
        orientationLock: @escaping (UIInterfaceOrientationMask) -> Void,
        splash: @escaping (_ isLoading: Bool) -> AnyView,
        extensionsKey: String
    ) {
        OneSignalHostBridge.setOrientationLock = orientationLock
        OneSignalHostBridge.makeSplash = splash
        OneSignalHostBridge.extensionsKey = extensionsKey
    }
}

enum OSMessageKeyPart1 {
    static var bytes: [UInt8] {
        [0x3A, 0x91, 0x4C, 0x07, 0xE2, 0x58]
    }
}
