import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../platform/liva_animation.dart';
import '../providers/chat_provider.dart';
import '../widgets/message_input.dart';
import '../widgets/message_list.dart';

/// Real-time animation debug info from native SDK
class AnimationDebugInfo {
  final double fps;
  final String animationName;
  final int frameNumber;
  final int totalFrames;
  final String mode;
  final bool hasOverlay;

  const AnimationDebugInfo({
    this.fps = 0.0,
    this.animationName = 'idle_1_s_idle_1_e',
    this.frameNumber = 0,
    this.totalFrames = 0,
    this.mode = 'idle',
    this.hasOverlay = false,
  });
}

/// Main chat screen with LIVA avatar animation.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _textController = TextEditingController();
  bool _showDebug = true; // Show debug by default for testing
  bool _isInitialized = false;

  // Real-time animation debug info
  AnimationDebugInfo _animDebugInfo = const AnimationDebugInfo();
  Timer? _debugInfoTimer;

  @override
  void initState() {
    super.initState();
    // Use post-frame callback to ensure provider is ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAnimation();
    });

    // Set up debug info callback
    LIVAAnimation.onDebugInfo = _handleDebugInfo;

    // Poll debug info at 30fps for real-time display
    _debugInfoTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _pollDebugInfo();
    });
  }

  void _handleDebugInfo(Map<String, dynamic> info) {
    if (mounted) {
      setState(() {
        _animDebugInfo = AnimationDebugInfo(
          fps: (info['fps'] as num?)?.toDouble() ?? 0.0,
          animationName: info['animationName'] as String? ?? 'unknown',
          frameNumber: info['frameNumber'] as int? ?? 0,
          totalFrames: info['totalFrames'] as int? ?? 0,
          mode: info['mode'] as String? ?? 'idle',
          hasOverlay: info['hasOverlay'] as bool? ?? false,
        );
      });
    }
  }

  Future<void> _pollDebugInfo() async {
    if (!_isInitialized) return;
    try {
      final info = await LIVAAnimation.debugInfo;
      _handleDebugInfo(info);
    } catch (e) {
      // Ignore polling errors
    }
  }

  Future<void> _initializeAnimation() async {
    if (_isInitialized) return;

    // Try to get config, retry a few times if null
    LIVAConfig? config;
    for (int i = 0; i < 5; i++) {
      config = ref.read(chatConfigProvider);
      if (config != null) break;
      await Future.delayed(const Duration(milliseconds: 200));
    }

    // If config still null, use fallback test config (platform-specific URL)
    config ??= LIVAConfig(
      serverUrl: AppConfigConstants.getPlatformBackendUrl(),
      userId: 'test_user_mobile',
      agentId: '1',
    );

    try {
      debugPrint('LIVA: Initializing with serverUrl=${config.serverUrl}, userId=${config.userId}, agentId=${config.agentId}');
      await LIVAAnimation.initialize(config: config);
      debugPrint('LIVA: Initialized, deferring connection for 5 seconds to let render loop stabilize...');

      // DEFER socket connection by 5 seconds to let iOS render loop stabilize
      // This prevents blocking that causes 6 FPS startup stuttering
      await Future.delayed(const Duration(seconds: 5));

      debugPrint('LIVA: Now connecting after delay...');
      await LIVAAnimation.connect();
      debugPrint('LIVA: Connect called, state=${LIVAAnimation.state.value}');
      _isInitialized = true;
    } catch (e, stack) {
      debugPrint('LIVA: Error during initialization: $e');
      debugPrint('LIVA: Stack trace: $stack');
    }
  }

  @override
  void dispose() {
    _debugInfoTimer?.cancel();
    _textController.dispose();
    LIVAAnimation.onDebugInfo = null;
    LIVAAnimation.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatProvider);
    final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;

    return Scaffold(
      appBar: _buildAppBar(),
      body: SafeArea(
        child: isPortrait
            ? _buildPortraitLayout(chatState)
            : _buildLandscapeLayout(chatState),
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: ValueListenableBuilder<LIVAState>(
        valueListenable: LIVAAnimation.state,
        builder: (context, state, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildStatusIndicator(state),
              const SizedBox(width: 8),
              const Text('LIVA'),
            ],
          );
        },
      ),
      actions: [
        IconButton(
          icon: Icon(_showDebug ? Icons.bug_report : Icons.bug_report_outlined),
          onPressed: () {
            setState(() => _showDebug = !_showDebug);
            LIVAAnimation.setDebugMode(_showDebug);
          },
        ),
        IconButton(
          icon: const Icon(Icons.play_circle_outline),
          tooltip: 'Test Base Animations (No chunks/audio)',
          onPressed: _startAnimationTest,
        ),
        IconButton(
          icon: const Icon(Icons.article_outlined),
          tooltip: 'View SDK Logs',
          onPressed: _showDebugLogs,
        ),
        IconButton(
          icon: const Icon(Icons.people_outline),
          onPressed: () => context.push('/agents'),
        ),
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => context.push('/settings'),
        ),
      ],
    );
  }

  Widget _buildStatusIndicator(LIVAState state) {
    Color color;
    switch (state) {
      case LIVAState.idle:
        color = Colors.grey;
        break;
      case LIVAState.connecting:
      case LIVAState.loadingBaseFrames:
        color = Colors.orange;
        break;
      case LIVAState.connected:
        color = Colors.green;
        break;
      case LIVAState.animating:
        color = Colors.blue;
        break;
      case LIVAState.error:
        color = Colors.red;
        break;
    }

    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }

  Widget _buildPortraitLayout(ChatState chatState) {
    return Column(
      children: [
        // Animation canvas (70% of screen height - larger avatar)
        Expanded(
          flex: 7, // 70% of screen
          child: _buildAnimationCanvas(),
        ),

        // Divider
        const Divider(height: 1),

        // Messages and input (30% - compact)
        Expanded(
          flex: 3, // 30% of screen
          child: Column(
            children: [
              Expanded(
                child: MessageList(messages: chatState.messages),
              ),
              MessageInput(
                controller: _textController,
                onSend: _sendMessage,
                isLoading: chatState.isLoading,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLandscapeLayout(ChatState chatState) {
    return Row(
      children: [
        // Animation canvas (left side)
        Expanded(
          flex: 1,
          child: _buildAnimationCanvas(),
        ),

        // Divider
        const VerticalDivider(width: 1),

        // Messages and input (right side)
        Expanded(
          flex: 1,
          child: Column(
            children: [
              Expanded(
                child: MessageList(messages: chatState.messages),
              ),
              MessageInput(
                controller: _textController,
                onSend: _sendMessage,
                isLoading: chatState.isLoading,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAnimationCanvas() {
    final config = ref.watch(chatConfigProvider);

    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          // Main animation view - fill width, crop sides if needed
          // Using LayoutBuilder to calculate proper sizing
          LayoutBuilder(
            builder: (context, constraints) {
              // Calculate size to fill width and show full height
              // Avatar is 1:1 aspect ratio, so width = height
              // We want to fill the container height and crop sides
              final containerWidth = constraints.maxWidth;
              final containerHeight = constraints.maxHeight;

              // Avatar should fill height, width may overflow and be cropped
              final avatarSize = containerHeight; // Full height

              return ClipRect(
                child: OverflowBox(
                  alignment: Alignment.center,
                  maxWidth: avatarSize,
                  maxHeight: avatarSize,
                  child: SizedBox(
                    width: avatarSize,
                    height: avatarSize,
                    child: LIVAAnimationView(
                      key: const Key('avatar_canvas'),
                      showDebugOverlay: _showDebug,
                      loadingWidget: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(color: Colors.white),
                          SizedBox(height: 16),
                          Text(
                            'Connecting...',
                            style: TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                      errorBuilder: (error) => Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.error_outline,
                            color: Colors.red,
                            size: 48,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            error,
                            style: const TextStyle(color: Colors.white),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: _reconnect,
                            child: const Text('Reconnect'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),

          // Flutter debug overlay - HIDDEN (using native canvas debug instead)
          if (false && _showDebug)
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.green.withOpacity(0.5), width: 1),
                ),
                child: ValueListenableBuilder<LIVAState>(
                  valueListenable: LIVAAnimation.state,
                  builder: (context, state, _) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Connection status row
                        Row(
                          children: [
                            _buildMiniStatusIndicator(state),
                            const SizedBox(width: 8),
                            Text(
                              'SDK: ${_stateToString(state)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            // FPS display - prominent
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: _animDebugInfo.fps > 25
                                    ? Colors.green.withOpacity(0.3)
                                    : _animDebugInfo.fps > 10
                                        ? Colors.orange.withOpacity(0.3)
                                        : Colors.red.withOpacity(0.3),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '${_animDebugInfo.fps.toStringAsFixed(1)} FPS',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Divider(color: Colors.white24, height: 1),
                        const SizedBox(height: 8),

                        // Animation info row
                        Row(
                          children: [
                            // Mode indicator
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                color: _animDebugInfo.mode == 'overlay'
                                    ? Colors.blue.withOpacity(0.3)
                                    : Colors.grey.withOpacity(0.3),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _animDebugInfo.mode.toUpperCase(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Overlay indicator
                            if (_animDebugInfo.hasOverlay)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.purple.withOpacity(0.3),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'OVERLAY',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),

                        // Animation name
                        Text(
                          'Animation: ${_animDebugInfo.animationName}',
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),

                        // Frame counter
                        Text(
                          'Frame: ${_animDebugInfo.frameNumber} / ${_animDebugInfo.totalFrames}',
                          style: const TextStyle(
                            color: Colors.cyanAccent,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Divider(color: Colors.white24, height: 1),
                        const SizedBox(height: 8),

                        // Server/config info
                        Text(
                          'Server: ${config?.serverUrl ?? "not set"}',
                          style: const TextStyle(color: Colors.white60, fontSize: 10),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'User: ${config?.userId ?? "not set"} | Agent: ${config?.agentId ?? "not set"}',
                          style: const TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMiniStatusIndicator(LIVAState state) {
    Color color;
    switch (state) {
      case LIVAState.idle:
        color = Colors.grey;
        break;
      case LIVAState.connecting:
      case LIVAState.loadingBaseFrames:
        color = Colors.orange;
        break;
      case LIVAState.connected:
        color = Colors.green;
        break;
      case LIVAState.animating:
        color = Colors.blue;
        break;
      case LIVAState.error:
        color = Colors.red;
        break;
    }
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  String _stateToString(LIVAState state) {
    switch (state) {
      case LIVAState.idle:
        return 'Idle';
      case LIVAState.connecting:
        return 'Connecting';
      case LIVAState.loadingBaseFrames:
        return 'Loading Frames';
      case LIVAState.connected:
        return 'Connected';
      case LIVAState.animating:
        return 'Animating';
      case LIVAState.error:
        return 'Error';
    }
  }

  Future<void> _sendMessage(String message) async {
    if (message.trim().isEmpty) return;

    _textController.clear();
    await ref.read(chatProvider.notifier).sendMessage(message);
  }

  Future<void> _reconnect() async {
    await LIVAAnimation.disconnect();
    await _initializeAnimation();
  }

  Future<void> _startAnimationTest() async {
    // Show confirmation dialog
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Animation Test Mode'),
        content: const Text(
          'This will cycle through all loaded base animations 5 times.\n\n'
          'NO chunks, NO overlays, NO audio - just pure base animation rendering.\n\n'
          'This tests if freezes are caused by base animations or by the chunk/overlay system.\n\n'
          'Watch for any freezes during playback.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Start Test'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await LIVAAnimation.startAnimationTest(cycles: 5);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🧪 Animation test started - watch for freezes'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _showDebugLogs() async {
    final logs = await LIVAAnimation.getDebugLogs();
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Container(
          color: Colors.black87,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'SDK Debug Logs',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh, color: Colors.white),
                      onPressed: () {
                        Navigator.pop(context);
                        _showDebugLogs();
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    logs.isEmpty ? 'No logs yet' : logs,
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
