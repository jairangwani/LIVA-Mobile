import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../platform/liva_animation.dart';
import '../providers/chat_provider.dart';
import '../widgets/message_input.dart';
import '../widgets/message_list.dart';

/// Main chat screen with LIVA avatar animation.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _textController = TextEditingController();
  bool _showDebug = false;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    // Use post-frame callback to ensure provider is ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAnimation();
    });
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

    // If config still null, use fallback test config (localhost for testing)
    config ??= const LIVAConfig(
      serverUrl: 'http://localhost:5003',
      userId: 'test_user_mobile',
      agentId: '1',
    );

    try {
      debugPrint('LIVA: Initializing with serverUrl=${config.serverUrl}, userId=${config.userId}, agentId=${config.agentId}');
      await LIVAAnimation.initialize(config: config);
      debugPrint('LIVA: Initialized, now connecting...');
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
    _textController.dispose();
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
        // Animation canvas (top half)
        Expanded(
          flex: 2,
          child: _buildAnimationCanvas(),
        ),

        // Divider
        const Divider(height: 1),

        // Messages and input (bottom half)
        Expanded(
          flex: 3,
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
          // Main animation view
          Center(
            child: AspectRatio(
              aspectRatio: 1.0,
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

          // Debug overlay (always visible for now)
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ValueListenableBuilder<LIVAState>(
                valueListenable: LIVAAnimation.state,
                builder: (context, state, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          _buildMiniStatusIndicator(state),
                          const SizedBox(width: 6),
                          Text(
                            'SDK: ${_stateToString(state)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Server: ${config?.serverUrl ?? "not set"}',
                        style: const TextStyle(color: Colors.white60, fontSize: 9),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'User: ${config?.userId ?? "not set"} | Agent: ${config?.agentId ?? "not set"}',
                        style: const TextStyle(color: Colors.white60, fontSize: 9),
                      ),
                      Text(
                        'Initialized: $_isInitialized',
                        style: const TextStyle(color: Colors.white60, fontSize: 9),
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
