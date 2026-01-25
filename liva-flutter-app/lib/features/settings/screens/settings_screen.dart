import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../platform/liva_animation.dart';

/// Settings screen.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _serverUrlController = TextEditingController();
  bool _showDebugInfo = false;
  Map<String, dynamic> _debugInfo = {};

  @override
  void initState() {
    super.initState();
    _loadDebugInfo();
  }

  Future<void> _loadDebugInfo() async {
    final info = await LIVAAnimation.debugInfo;
    setState(() => _debugInfo = info);
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(appConfigProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Account section
          _buildSectionHeader('Account'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('User ID'),
                  subtitle: Text(config?.userId ?? 'Not logged in'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('Logout'),
                  onTap: () => _logout(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Connection section
          _buildSectionHeader('Connection'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Server URL'),
                  subtitle: Text(config?.serverUrl ?? AppConfigConstants.backendUrl),
                  onTap: () => _showServerUrlDialog(context, config?.serverUrl),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.smart_toy_outlined),
                  title: const Text('Current Agent'),
                  subtitle: Text('Agent ${config?.agentId ?? '1'}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/agents'),
                ),
                const Divider(height: 1),
                ValueListenableBuilder<LIVAState>(
                  valueListenable: LIVAAnimation.state,
                  builder: (context, state, _) {
                    return ListTile(
                      leading: _buildStatusIcon(state),
                      title: const Text('Connection Status'),
                      subtitle: Text(_stateToString(state)),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Debug section
          _buildSectionHeader('Debug'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.bug_report_outlined),
                  title: const Text('Show Debug Info'),
                  value: _showDebugInfo,
                  onChanged: (value) {
                    setState(() => _showDebugInfo = value);
                    LIVAAnimation.setDebugMode(value);
                  },
                ),
                if (_showDebugInfo) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Debug Information',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _debugInfo.entries
                              .map((e) => '${e.key}: ${e.value}')
                              .join('\n'),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                              ),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton(
                          onPressed: _loadDebugInfo,
                          child: const Text('Refresh'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),

          // About section
          _buildSectionHeader('About'),
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('Version'),
                  subtitle: Text('1.0.0'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Licenses'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showLicensePage(context: context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }

  Widget _buildStatusIcon(LIVAState state) {
    IconData icon;
    Color color;

    switch (state) {
      case LIVAState.idle:
        icon = Icons.circle_outlined;
        color = Colors.grey;
        break;
      case LIVAState.connecting:
      case LIVAState.loadingBaseFrames:
        icon = Icons.pending;
        color = Colors.orange;
        break;
      case LIVAState.connected:
        icon = Icons.check_circle;
        color = Colors.green;
        break;
      case LIVAState.animating:
        icon = Icons.animation;
        color = Colors.blue;
        break;
      case LIVAState.error:
        icon = Icons.error;
        color = Colors.red;
        break;
    }

    return Icon(icon, color: color);
  }

  String _stateToString(LIVAState state) {
    switch (state) {
      case LIVAState.idle:
        return 'Disconnected';
      case LIVAState.connecting:
        return 'Connecting...';
      case LIVAState.loadingBaseFrames:
        return 'Loading Avatar...';
      case LIVAState.connected:
        return 'Connected';
      case LIVAState.animating:
        return 'Animating';
      case LIVAState.error:
        return 'Error';
    }
  }

  Future<void> _showServerUrlDialog(BuildContext context, String? currentUrl) async {
    _serverUrlController.text = currentUrl ?? AppConfigConstants.backendUrl;

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Server URL'),
        content: TextField(
          controller: _serverUrlController,
          decoration: const InputDecoration(
            labelText: 'URL',
            hintText: 'https://api.example.com',
          ),
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _serverUrlController.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      final config = ref.read(appConfigProvider);
      if (config != null) {
        await ref.read(appConfigProvider.notifier).setConfig(
              config.copyWith(serverUrl: result),
            );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Server URL updated. Reconnect to apply.'),
            ),
          );
        }
      }
    }
  }

  Future<void> _logout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await LIVAAnimation.disconnect();
      await ref.read(appConfigProvider.notifier).clearConfig();

      if (mounted) {
        context.go('/login');
      }
    }
  }
}
