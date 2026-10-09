// AppDelegate.swift
//
// Classic (pre-UIScene) app lifecycle on purpose: UIScene / SceneDelegate is
// iOS 13+, and there's no `UIApplicationSceneManifest` key in Info.plist, so
// UIKit falls back to this path automatically -- which also happens to keep
// working fine on modern iOS.

import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ReceiverViewController()
        window.backgroundColor = .black
        window.makeKeyAndVisible()
        self.window = window
        // 签名到期：解析一次 → 写设置页 defaults + 起 9002 应答点（常量 payload）。
        // 放这里而不是 ReceiverViewController：与视图生命周期解耦，开关翻转/重建
        // 视图都不会重复起应答点。
        SignatureAnnounce.start()
        return true
    }
}
