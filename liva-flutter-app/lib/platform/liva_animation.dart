import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// LIVA connection state.
enum LIVAState {
  idle,
  connecting,
  loadingBaseFrames,
  connected,
  animating,
  error,
}

/// Base frame loading progress.
class BaseFrameLoadingProgress {
  final String animationName;
  final double progress;
  final bool isFirstIdleFrameReady;
  final int loadedAnimations;
  final int totalAnimations;

  const BaseFrameLoadingProgress({
    this.animationName = '',
    this.progress = 0.0,
    this.isFirstIdleFrameReady = false,
    this.loadedAnimations = 0,
    this.totalAnimations = 9,
  });

  bool get isIdleReady => animationName == 'idle_1_s_idle_1_e' && progress >= 1.0;
}

/// LIVA SDK configuration.
class LIVAConfig {
  final String serverUrl;
  final String userId;
  final String agentId;
  final String instanceId;
  final String resolution;

  const LIVAConfig({
    required this.serverUrl,
    required this.userId,
    required this.agentId,
    this.instanceId = 'default',
    this.resolution = '512',
  });

  Map<String, dynamic> toMap() => {
        'serverUrl': serverUrl,
        'userId': userId,
        'agentId': agentId,
        'instanceId': instanceId,
        'resolution': resolution,
      };
}

/// Platform channel interface for LIVA native SDKs.
///
/// This class provides a unified interface for iOS and Android native SDKs
/// via Flutter platform channels. Use this to control the LIVA animation
/// rendering and connection lifecycle.
///
/// Example:
/// ```dart
/// await LIVAAnimation.initialize(
///   config: LIVAConfig(
///     serverUrl: 'https://api.liva.com',
///     userId: 'user-123',
///     agentId: '1',
///   ),
/// );
/// await LIVAAnimation.connect();
/// ```
class LIVAAnimation {
  static const MethodChannel _channel = MethodChannel('com.liva.animation');
  static const EventChannel _eventChannel =
      EventChannel('com.liva.animation/events');

  static StreamSubscription? _eventSubscription;
  static bool _initialized = false;

  /// Current connection state
  static final ValueNotifier<LIVAState> state = ValueNotifier(LIVAState.idle);

  /// Base frame loading progress
  static final ValueNotifier<BaseFrameLoadingProgress> baseFrameProgress =
      ValueNotifier(const BaseFrameLoadingProgress());

  /// Whether first idle frame is ready (avatar can be shown)
  static final ValueNotifier<bool> isIdleReady = ValueNotifier(false);

  /// Error callback
  static void Function(String error)? onError;

  /// State change callback
  static void Function(LIVAState state)? onStateChange;

  /// Animation mode callback (idle, talking, transition)
  static void Function(String mode)? onModeChange;

  /// Base frame loading progress callback
  static void Function(BaseFrameLoadingProgress progress)? onBaseFrameProgress;

  /// First idle frame ready callback
  static void Function()? onFirstIdleFrameReady;

  /// Debug info callback
  static void Function(Map<String, dynamic> info)? onDebugInfo;

  // MARK: - Lifecycle

  /// Initialize the native SDK with configuration.
  ///
  /// Must be called before [connect]. This sets up the native SDK
  /// components and prepares for connection.
  static Future<void> initialize({
    required LIVAConfig config,
  }) async {
    if (_initialized) {
      return;
    }

    try {
      await _channel.invokeMethod('initialize', config.toMap());

      // Set up method call handler for callbacks
      _channel.setMethodCallHandler(_handleMethodCall);

      // Set up event stream
      _eventSubscription = _eventChannel
          .receiveBroadcastStream()
          .listen(_handleEvent, onError: _handleEventError);

      _initialized = true;
    } on PlatformException catch (e) {
      onError?.call(e.message ?? 'Initialization failed');
      rethrow;
    }
  }

  /// Connect to the backend server.
  ///
  /// Will start the socket connection and begin receiving
  /// animation frames when the server sends them.
  static Future<void> connect() async {
    if (!_initialized) {
      throw StateError('Must call initialize() before connect()');
    }

    try {
      state.value = LIVAState.connecting;
      await _channel.invokeMethod('connect');
    } on PlatformException catch (e) {
      state.value = LIVAState.error;
      onError?.call(e.message ?? 'Connection failed');
      rethrow;
    }
  }

  /// Disconnect from the server.
  ///
  /// Stops animation rendering and closes the socket connection.
  static Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
      state.value = LIVAState.idle;
    } on PlatformException catch (e) {
      onError?.call(e.message ?? 'Disconnect failed');
      rethrow;
    }
  }

  /// Release all resources.
  ///
  /// Call this when the SDK is no longer needed (e.g., app termination).
  static Future<void> dispose() async {
    try {
      await _eventSubscription?.cancel();
      await _channel.invokeMethod('release');
      _initialized = false;
      state.value = LIVAState.idle;
    } on PlatformException catch (e) {
      onError?.call(e.message ?? 'Dispose failed');
    }
  }

  // MARK: - State

  /// Check if currently connected.
  static Future<bool> get isConnected async {
    try {
      return await _channel.invokeMethod('isConnected') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Get debug information from native SDK.
  static Future<Map<String, dynamic>> get debugInfo async {
    try {
      final result = await _channel.invokeMethod('getDebugInfo');
      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException {
      return {};
    }
  }

  /// Get debug logs from native SDK.
  /// Returns all logged messages from the animation engine.
  static Future<String> getDebugLogs() async {
    try {
      final result = await _channel.invokeMethod('getDebugLogs');
      return result as String? ?? '';
    } on PlatformException {
      return '';
    }
  }

  // MARK: - Debug Controls

  /// Enable or disable debug overlay on the canvas.
  static Future<void> setDebugMode(bool enabled) async {
    try {
      await _channel.invokeMethod('setDebugMode', {'enabled': enabled});
    } on PlatformException catch (e) {
      onError?.call(e.message ?? 'Set debug mode failed');
    }
  }

  // MARK: - Event Handlers

  static Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onStateChange':
        _updateState(call.arguments as String);
        break;
      case 'onError':
        onError?.call(call.arguments as String);
        break;
      case 'onModeChange':
        onModeChange?.call(call.arguments as String);
        break;
      case 'onDebugInfo':
        onDebugInfo?.call(Map<String, dynamic>.from(call.arguments));
        break;
    }
  }

  static void _handleEvent(dynamic event) {
    if (event is Map) {
      final type = event['type'] as String?;
      final data = event['data'];

      switch (type) {
        case 'stateChange':
          _updateState(data as String);
          break;
        case 'error':
          onError?.call(data as String);
          break;
        case 'modeChange':
          onModeChange?.call(data as String);
          break;
        case 'debugInfo':
          onDebugInfo?.call(Map<String, dynamic>.from(data));
          break;
        case 'baseFrameProgress':
          _updateBaseFrameProgress(Map<String, dynamic>.from(data));
          break;
        case 'firstIdleFrameReady':
          _handleFirstIdleFrameReady();
          break;
        case 'animationLoaded':
          _handleAnimationLoaded(data as String);
          break;
      }
    }
  }

  static void _handleEventError(dynamic error) {
    onError?.call(error.toString());
  }

  static void _updateState(String stateString) {
    final newState = LIVAState.values.firstWhere(
      (s) => s.name == stateString,
      orElse: () => LIVAState.idle,
    );
    state.value = newState;
    onStateChange?.call(newState);
  }

  static void _updateBaseFrameProgress(Map<String, dynamic> data) {
    final progress = BaseFrameLoadingProgress(
      animationName: data['animationName'] as String? ?? '',
      progress: (data['progress'] as num?)?.toDouble() ?? 0.0,
      isFirstIdleFrameReady: data['isFirstIdleFrameReady'] as bool? ?? false,
      loadedAnimations: data['loadedAnimations'] as int? ?? 0,
      totalAnimations: data['totalAnimations'] as int? ?? 9,
    );
    baseFrameProgress.value = progress;
    onBaseFrameProgress?.call(progress);
  }

  static void _handleFirstIdleFrameReady() {
    isIdleReady.value = true;
    onFirstIdleFrameReady?.call();
    // Transition from loadingBaseFrames to connected
    if (state.value == LIVAState.loadingBaseFrames) {
      state.value = LIVAState.connected;
      onStateChange?.call(LIVAState.connected);
    }
  }

  static void _handleAnimationLoaded(String animationName) {
    // Update loaded animations count
    final current = baseFrameProgress.value;
    baseFrameProgress.value = BaseFrameLoadingProgress(
      animationName: animationName,
      progress: 1.0,
      isFirstIdleFrameReady: current.isFirstIdleFrameReady || animationName == 'idle_1_s_idle_1_e',
      loadedAnimations: current.loadedAnimations + 1,
      totalAnimations: current.totalAnimations,
    );
  }
}

/// Native canvas widget that renders the LIVA animation.
///
/// This widget embeds the native iOS/Android canvas view
/// that displays the avatar animation frames.
///
/// Example:
/// ```dart
/// Scaffold(
///   body: Center(
///     child: AspectRatio(
///       aspectRatio: 1.0,
///       child: LIVACanvasWidget(
///         showDebugOverlay: false,
///       ),
///     ),
///   ),
/// )
/// ```
class LIVACanvasWidget extends StatefulWidget {
  /// Whether to show FPS and frame count overlay.
  final bool showDebugOverlay;

  /// Called when the native view is created.
  final VoidCallback? onViewCreated;

  const LIVACanvasWidget({
    super.key,
    this.showDebugOverlay = false,
    this.onViewCreated,
  });

  @override
  State<LIVACanvasWidget> createState() => _LIVACanvasWidgetState();
}

class _LIVACanvasWidgetState extends State<LIVACanvasWidget> {
  @override
  Widget build(BuildContext context) {
    final creationParams = {
      'showDebugOverlay': widget.showDebugOverlay,
    };

    // Platform-specific view
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: 'com.liva.animation/canvas',
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidView(
        viewType: 'com.liva.animation/canvas',
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    }

    // Fallback for unsupported platforms
    return const Center(
      child: Text('Platform not supported'),
    );
  }

  void _onPlatformViewCreated(int viewId) {
    widget.onViewCreated?.call();
  }
}

/// State-aware canvas widget that shows loading/error states.
class LIVAAnimationView extends StatelessWidget {
  /// Widget to show while connecting.
  final Widget? loadingWidget;

  /// Widget builder for loading base frames with progress.
  final Widget Function(BaseFrameLoadingProgress progress)? loadingProgressBuilder;

  /// Widget to show on error.
  final Widget Function(String error)? errorBuilder;

  /// Whether to show debug overlay.
  final bool showDebugOverlay;

  const LIVAAnimationView({
    super.key,
    this.loadingWidget,
    this.loadingProgressBuilder,
    this.errorBuilder,
    this.showDebugOverlay = false,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LIVAState>(
      valueListenable: LIVAAnimation.state,
      builder: (context, state, child) {
        switch (state) {
          case LIVAState.idle:
            return const Center(
              child: Text('Not connected'),
            );
          case LIVAState.connecting:
            return loadingWidget ??
                const Center(
                  child: CircularProgressIndicator(),
                );
          case LIVAState.loadingBaseFrames:
            return ValueListenableBuilder<BaseFrameLoadingProgress>(
              valueListenable: LIVAAnimation.baseFrameProgress,
              builder: (context, progress, _) {
                if (loadingProgressBuilder != null) {
                  return loadingProgressBuilder!(progress);
                }
                return _DefaultLoadingProgress(progress: progress);
              },
            );
          case LIVAState.connected:
          case LIVAState.animating:
            return LIVACanvasWidget(
              showDebugOverlay: showDebugOverlay,
            );
          case LIVAState.error:
            return errorBuilder?.call('Connection error') ??
                const Center(
                  child: Icon(Icons.error_outline, size: 48),
                );
        }
      },
    );
  }
}

/// Default loading progress widget.
class _DefaultLoadingProgress extends StatelessWidget {
  final BaseFrameLoadingProgress progress;

  const _DefaultLoadingProgress({required this.progress});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 100,
            height: 100,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: progress.loadedAnimations / progress.totalAnimations,
                  strokeWidth: 4,
                ),
                Text(
                  '${(progress.loadedAnimations / progress.totalAnimations * 100).toInt()}%',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Loading avatar...',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (progress.animationName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                progress.animationName.replaceAll('_', ' '),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
