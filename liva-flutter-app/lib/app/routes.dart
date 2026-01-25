import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/config/app_config.dart';
import '../features/auth/screens/login_screen.dart';
import '../features/chat/screens/chat_screen.dart';
import '../features/agents/screens/agents_screen.dart';
import '../features/settings/screens/settings_screen.dart';

/// Router provider for navigation.
final routerProvider = Provider<GoRouter>((ref) {
  // TEST MODE: Skip login entirely, go straight to agents
  return GoRouter(
    initialLocation: '/agents',
    redirect: (context, state) {
      // Redirect home to agents for testing
      if (state.matchedLocation == '/') {
        return '/agents';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        name: 'home',
        redirect: (context, state) => '/chat',
      ),
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/chat',
        name: 'chat',
        builder: (context, state) => const ChatScreen(),
      ),
      GoRoute(
        path: '/agents',
        name: 'agents',
        builder: (context, state) => const AgentsScreen(),
      ),
      GoRoute(
        path: '/settings',
        name: 'settings',
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
  );
});
