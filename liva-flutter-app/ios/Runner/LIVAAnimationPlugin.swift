import Flutter
import UIKit
import LIVAAnimation  // Import the native SDK

/// Flutter plugin for LIVA Animation SDK.
///
/// This plugin bridges the Dart platform channel to the native iOS SDK.
/// Copy this file to your Flutter project's ios/Runner directory.
public class LIVAAnimationPlugin: NSObject, FlutterPlugin {

    private var channel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    private var canvasView: LIVACanvasView?

    // MARK: - Plugin Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = LIVAAnimationPlugin()

        // Method channel for commands
        let channel = FlutterMethodChannel(
            name: "com.liva.animation",
            binaryMessenger: registrar.messenger()
        )
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)

        // Event channel for callbacks
        let eventChannel = FlutterEventChannel(
            name: "com.liva.animation/events",
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)
        instance.eventChannel = eventChannel

        // Register platform view factory
        let factory = LIVACanvasViewFactory(plugin: instance)
        registrar.register(factory, withId: "com.liva.animation/canvas")
    }

    // MARK: - Method Channel Handler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            handleInitialize(call.arguments, result: result)
        case "connect":
            handleConnect(result: result)
        case "disconnect":
            handleDisconnect(result: result)
        case "release":
            handleRelease(result: result)
        case "isConnected":
            result(LIVAClient.shared.isConnected)
        case "getDebugInfo":
            result(getAnimationDebugInfo())
        case "setDebugMode":
            handleSetDebugMode(call.arguments, result: result)
        case "getDebugLogs":
            result(LIVAClient.shared.getDebugLogs())
        case "forceIdleNow":
            // Force immediate transition to idle and clear all caches
            // Call this BEFORE sending a new message to prevent stale overlay reuse
            LIVAClient.shared.forceIdleNow()
            result(nil)
        case "setOverlayRenderingDisabled":
            handleSetOverlayRenderingDisabled(call.arguments, result: result)
        case "startAnimationTest":
            handleStartAnimationTest(call.arguments, result: result)
        case "stopAnimationTest":
            LIVAClient.shared.stopAnimationTest()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Command Handlers

    private func handleInitialize(_ arguments: Any?, result: @escaping FlutterResult) {
        guard let args = arguments as? [String: Any],
              let serverUrl = args["serverUrl"] as? String,
              let userId = args["userId"] as? String,
              let agentId = args["agentId"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing required arguments", details: nil))
            return
        }

        let instanceId = args["instanceId"] as? String ?? "default"
        let resolution = args["resolution"] as? String ?? "512"

        let config = LIVAConfiguration(
            serverURL: serverUrl,
            userId: userId,
            agentId: agentId,
            instanceId: instanceId,
            resolution: resolution
        )

        LIVAClient.shared.configure(config)
        setupCallbacks()

        result(nil)
    }

    private func handleConnect(result: @escaping FlutterResult) {
        LIVAClient.shared.connect()
        result(nil)
    }

    private func handleDisconnect(result: @escaping FlutterResult) {
        LIVAClient.shared.disconnect()
        result(nil)
    }

    private func handleRelease(result: @escaping FlutterResult) {
        LIVAClient.shared.disconnect()
        result(nil)
    }

    private func handleSetDebugMode(_ arguments: Any?, result: @escaping FlutterResult) {
        guard let args = arguments as? [String: Any],
              let enabled = args["enabled"] as? Bool else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing enabled argument", details: nil))
            return
        }

        canvasView?.showDebugInfo = enabled
        result(nil)
    }

    private func handleSetOverlayRenderingDisabled(_ arguments: Any?, result: @escaping FlutterResult) {
        guard let args = arguments as? [String: Any],
              let disabled = args["disabled"] as? Bool else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing disabled argument", details: nil))
            return
        }

        LIVAClient.shared.setOverlayRenderingDisabled(disabled)
        result(nil)
    }

    private func handleStartAnimationTest(_ arguments: Any?, result: @escaping FlutterResult) {
        let cycles = (arguments as? [String: Any])?["cycles"] as? Int ?? 5
        LIVAClient.shared.startAnimationTest(cycles: cycles)
        result(nil)
    }

    private func getDebugInfo() -> [String: Any] {
        return [
            "state": stateToString(LIVAClient.shared.state),
            "isConnected": LIVAClient.shared.isConnected,
            "debugDescription": LIVAClient.shared.debugDescription
        ]
    }

    /// Get real-time animation debug info for Flutter display
    private func getAnimationDebugInfo() -> [String: Any] {
        return LIVAClient.shared.getAnimationDebugInfo()
    }

    // MARK: - Callbacks

    private func setupCallbacks() {
        LIVAClient.shared.onStateChange = { [weak self] state in
            self?.sendEvent(type: "stateChange", data: self?.stateToString(state) ?? "idle")
        }

        LIVAClient.shared.onError = { [weak self] error in
            self?.sendEvent(type: "error", data: error.localizedDescription)
        }
    }

    private func sendEvent(type: String, data: Any) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(["type": type, "data": data])
        }
    }

    private func stateToString(_ state: LIVAState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .animating: return "animating"
        case .error: return "error"
        }
    }

    // MARK: - Canvas View

    func attachCanvasView(_ view: LIVACanvasView) {
        self.canvasView = view
        LIVAClient.shared.attachView(view)
    }
}

// MARK: - Event Stream Handler

extension LIVAAnimationPlugin: FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}

// MARK: - Platform View Factory

class LIVACanvasViewFactory: NSObject, FlutterPlatformViewFactory {
    private weak var plugin: LIVAAnimationPlugin?

    init(plugin: LIVAAnimationPlugin) {
        self.plugin = plugin
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        return LIVACanvasPlatformView(
            frame: frame,
            viewId: viewId,
            args: args as? [String: Any],
            plugin: plugin
        )
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

// MARK: - Platform View

class LIVACanvasPlatformView: NSObject, FlutterPlatformView {
    private let canvasView: LIVACanvasView

    init(frame: CGRect, viewId: Int64, args: [String: Any]?, plugin: LIVAAnimationPlugin?) {
        canvasView = LIVACanvasView(frame: frame)
        super.init()

        if let showDebug = args?["showDebugOverlay"] as? Bool {
            canvasView.showDebugInfo = showDebug
        }

        plugin?.attachCanvasView(canvasView)
    }

    func view() -> UIView {
        return canvasView
    }
}
