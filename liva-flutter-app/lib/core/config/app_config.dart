import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Application configuration constants.
class AppConfigConstants {
  /// Backend server URL (Local for testing) - iOS and desktop
  static const String backendUrl = 'http://localhost:5003';

  /// Backend server URL for Android emulator (10.0.2.2 = host machine)
  static const String backendUrlAndroid = 'http://10.0.2.2:5003';

  /// Get platform-specific backend URL
  static String getPlatformBackendUrl() {
    if (Platform.isAndroid) {
      return backendUrlAndroid;
    }
    return backendUrl;
  }

  /// Default agent ID
  static const String defaultAgentId = '1';

  /// Default canvas resolution
  static const String defaultResolution = '512';

  /// Socket.IO path
  static const String socketPath = '/socket.io';

  /// API endpoints
  static const String messagesEndpoint = '/messages';
  static const String configEndpoint = '/api/config';
  static const String loginEndpoint = '/api/login';
  static const String signupEndpoint = '/api/signup';
  static const String guestEndpoint = '/initialize-guest-user';
}

/// User configuration for the app.
class UserConfig {
  final String serverUrl;
  final String userId;
  final String agentId;
  final String instanceId;
  final String resolution;

  const UserConfig({
    required this.serverUrl,
    required this.userId,
    required this.agentId,
    this.instanceId = 'default',
    this.resolution = '512',
  });

  UserConfig copyWith({
    String? serverUrl,
    String? userId,
    String? agentId,
    String? instanceId,
    String? resolution,
  }) {
    return UserConfig(
      serverUrl: serverUrl ?? this.serverUrl,
      userId: userId ?? this.userId,
      agentId: agentId ?? this.agentId,
      instanceId: instanceId ?? this.instanceId,
      resolution: resolution ?? this.resolution,
    );
  }
}

/// App configuration provider.
final appConfigProvider = StateNotifierProvider<AppConfigNotifier, UserConfig?>((ref) {
  return AppConfigNotifier();
});

/// App configuration state notifier.
class AppConfigNotifier extends StateNotifier<UserConfig?> {
  AppConfigNotifier() : super(null) {
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('userId');
    final agentId = prefs.getString('agentId');
    // TESTING: Always use platform-specific URL, ignore cached serverUrl
    // final serverUrl = prefs.getString('serverUrl');

    // TEST MODE: Auto-initialize with Agent 1 if no config
    // This allows the app to start directly with the chat screen
    state = UserConfig(
      serverUrl: AppConfigConstants.getPlatformBackendUrl(),
      userId: userId ?? 'test_user_mobile',
      agentId: agentId ?? AppConfigConstants.defaultAgentId,
    );
  }

  Future<void> setConfig(UserConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('userId', config.userId);
    await prefs.setString('agentId', config.agentId);
    await prefs.setString('serverUrl', config.serverUrl);
    state = config;
  }

  Future<void> setUserId(String userId) async {
    if (state != null) {
      await setConfig(state!.copyWith(userId: userId));
    } else {
      await setConfig(UserConfig(
        serverUrl: AppConfigConstants.backendUrl,
        userId: userId,
        agentId: AppConfigConstants.defaultAgentId,
      ));
    }
  }

  Future<void> setAgentId(String agentId) async {
    if (state != null) {
      await setConfig(state!.copyWith(agentId: agentId));
    }
  }

  Future<void> clearConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('userId');
    await prefs.remove('agentId');
    await prefs.remove('serverUrl');
    state = null;
  }
}

/// Environment-specific configuration.
enum Environment {
  development,
  staging,
  production,
}

/// Get backend URL for environment.
String getBackendUrl(Environment env) {
  switch (env) {
    case Environment.development:
      return AppConfigConstants.getPlatformBackendUrl();
    case Environment.staging:
      return 'https://staging-api.liva.com';
    case Environment.production:
      return 'https://api.liva.com';
  }
}
