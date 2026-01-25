import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Application configuration constants.
class AppConfigConstants {
  /// Backend server URL (AWS)
  static const String backendUrl = 'http://liva-test-alb-655341112.us-east-1.elb.amazonaws.com';

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
    final serverUrl = prefs.getString('serverUrl');

    if (userId != null) {
      state = UserConfig(
        serverUrl: serverUrl ?? AppConfigConstants.backendUrl,
        userId: userId,
        agentId: agentId ?? AppConfigConstants.defaultAgentId,
      );
    }
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
      return 'http://localhost:5003';
    case Environment.staging:
      return 'https://staging-api.liva.com';
    case Environment.production:
      return 'https://api.liva.com';
  }
}
