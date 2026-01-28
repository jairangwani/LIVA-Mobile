import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../platform/liva_animation.dart';
import '../models/message.dart';

/// Chat configuration provider.
final chatConfigProvider = StateProvider<LIVAConfig?>((ref) {
  final config = ref.watch(appConfigProvider);
  if (config == null) return null;

  // TESTING: Use platform-specific backend URL (10.0.2.2 for Android, localhost for iOS)
  return LIVAConfig(
    serverUrl: AppConfigConstants.getPlatformBackendUrl(),
    userId: config.userId,
    agentId: config.agentId,
  );
});

/// Chat state.
class ChatState {
  final List<ChatMessage> messages;
  final bool isLoading;
  final String? error;

  const ChatState({
    this.messages = const [],
    this.isLoading = false,
    this.error,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isLoading,
    String? error,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// Chat provider.
final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier(ref);
});

/// Chat state notifier.
class ChatNotifier extends StateNotifier<ChatState> {
  final Ref _ref;

  ChatNotifier(this._ref) : super(const ChatState());

  /// Send a message to the backend.
  Future<void> sendMessage(String content) async {
    if (content.trim().isEmpty) return;

    // CRITICAL: Force idle and clear caches BEFORE sending new message
    // This prevents stale overlays from previous response being reused
    // Matches web frontend's forceIdleNow() + stopAllAudio() behavior
    await LIVAAnimation.forceIdleNow();

    // Add user message
    final userMessage = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      content: content,
      role: MessageRole.user,
      timestamp: DateTime.now(),
    );

    state = state.copyWith(
      messages: [...state.messages, userMessage],
      isLoading: true,
      error: null,
    );

    try {
      final config = _ref.read(appConfigProvider);
      if (config == null) {
        throw Exception('App not configured');
      }

      // Send to backend via HTTP POST (use platform-specific URL)
      // Backend expects: AgentID (capital), message (not text)
      final response = await http.post(
        Uri.parse('${AppConfigConstants.getPlatformBackendUrl()}/messages'),
        headers: {
          'Content-Type': 'application/json',
          'X-User-ID': config.userId, // Required by backend middleware
        },
        body: jsonEncode({
          'AgentID': config.agentId,
          'message': content,
          'instance_id': config.instanceId,
          'userResolution': config.resolution,
        }),
      );

      // 200 = OK, 201 = Created - both are success
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw Exception('Failed to send message: ${response.statusCode}');
      }

      // The response will be streamed via socket, so just mark as done
      state = state.copyWith(isLoading: false);

    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );

      // Add error message
      final errorMessage = ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        content: 'Error: ${e.toString()}',
        role: MessageRole.system,
        timestamp: DateTime.now(),
      );

      state = state.copyWith(
        messages: [...state.messages, errorMessage],
      );
    }
  }

  /// Add an assistant response (called from socket events).
  void addAssistantMessage(String content) {
    final assistantMessage = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      content: content,
      role: MessageRole.assistant,
      timestamp: DateTime.now(),
    );

    state = state.copyWith(
      messages: [...state.messages, assistantMessage],
    );
  }

  /// Clear all messages.
  void clearMessages() {
    state = const ChatState();
  }
}
