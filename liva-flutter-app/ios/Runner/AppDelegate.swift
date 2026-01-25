import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        // Register LIVA Animation plugin
        if let controller = window?.rootViewController as? FlutterViewController {
            LIVAAnimationPlugin.register(with: controller.registrar(forPlugin: "LIVAAnimationPlugin")!)
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
