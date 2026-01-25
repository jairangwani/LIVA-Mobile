import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';

/// Agent model.
class Agent {
  final String id;
  final String name;
  final String? description;
  final String? voiceId;
  final String status;

  const Agent({
    required this.id,
    required this.name,
    this.description,
    this.voiceId,
    required this.status,
  });

  factory Agent.fromJson(Map<String, dynamic> json) {
    return Agent(
      id: json['agent_id']?.toString() ?? json['id']?.toString() ?? '',
      name: json['name'] as String? ?? 'Unknown Agent',
      description: json['description'] as String?,
      voiceId: json['voice_id'] as String?,
      status: json['status'] as String? ?? 'active',
    );
  }
}

/// Agents list provider.
final agentsProvider = FutureProvider<List<Agent>>((ref) async {
  try {
    // Backend returns agents in the /api/config response
    final response = await http.get(
      Uri.parse('${AppConfigConstants.backendUrl}/api/config'),
    );

    debugPrint('AGENTS: Fetching from ${AppConfigConstants.backendUrl}/api/config');
    debugPrint('AGENTS: Response status: ${response.statusCode}');

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      debugPrint('AGENTS: Response keys: ${data.keys.toList()}');
      final agentsList = data['agents'] as List? ?? [];
      debugPrint('AGENTS: Found ${agentsList.length} agents');
      return agentsList.map((a) => Agent.fromJson(a)).toList();
    } else {
      debugPrint('AGENTS: Non-200 response: ${response.body}');
    }
  } catch (e, stack) {
    debugPrint('AGENTS: Error fetching agents: $e');
    debugPrint('AGENTS: Stack: $stack');
  }
  return [];
});

/// Agents selection screen.
class AgentsScreen extends ConsumerStatefulWidget {
  const AgentsScreen({super.key});

  @override
  ConsumerState<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends ConsumerState<AgentsScreen> {
  bool _autoSelectDone = false;
  String _statusMessage = 'Initializing...';

  @override
  void initState() {
    super.initState();
    // Set up test user on init
    _setupTestUser();
  }

  Future<void> _setupTestUser() async {
    setState(() => _statusMessage = 'Setting up test user...');

    // Auto-setup test user config
    await ref.read(appConfigProvider.notifier).setConfig(
      const UserConfig(
        serverUrl: 'http://liva-test-alb-655341112.us-east-1.elb.amazonaws.com',
        userId: 'test_user_mobile',
        agentId: '1',
      ),
    );

    setState(() => _statusMessage = 'Test user configured. Loading agents...');
  }

  void _autoSelectFirstAgent(List<Agent> agents) {
    if (_autoSelectDone || agents.isEmpty) return;
    _autoSelectDone = true;

    // Auto-select first agent and navigate to chat
    final agent = agents.first;
    debugPrint('AUTO-SELECT: Selecting agent ${agent.id} (${agent.name})');

    ref.read(appConfigProvider.notifier).setAgentId(agent.id);

    // Navigate to chat after a brief delay
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        debugPrint('AUTO-SELECT: Navigating to chat...');
        context.go('/chat');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final agentsAsync = ref.watch(agentsProvider);
    final currentConfig = ref.watch(appConfigProvider);
    final currentAgentId = currentConfig?.agentId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Agent'),
        actions: [
          // Manual navigation to chat for testing
          IconButton(
            icon: const Icon(Icons.chat),
            onPressed: () => context.go('/chat'),
            tooltip: 'Go to Chat',
          ),
        ],
      ),
      body: Column(
        children: [
          // Debug status panel
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.black87,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DEBUG STATUS',
                  style: TextStyle(
                    color: Colors.amber,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Status: $_statusMessage',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
                Text(
                  'Server: ${currentConfig?.serverUrl ?? "not set"}',
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
                Text(
                  'User: ${currentConfig?.userId ?? "not set"}',
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
                Text(
                  'Agent: ${currentConfig?.agentId ?? "not set"}',
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ],
            ),
          ),

          // Main content
          Expanded(
            child: agentsAsync.when(
              loading: () {
                return const Center(child: CircularProgressIndicator());
              },
              error: (error, _) => Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 48, color: Colors.red),
                    const SizedBox(height: 16),
                    Text('Error loading agents: $error'),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => ref.refresh(agentsProvider),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
              data: (agents) {
                // Update status
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _statusMessage.contains('Loading')) {
                    setState(() => _statusMessage = 'Loaded ${agents.length} agent(s)');
                  }
                });

                // Auto-select if only one agent
                if (agents.length == 1 && !_autoSelectDone) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _autoSelectFirstAgent(agents);
                  });
                }

                if (agents.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.smart_toy_outlined, size: 64),
                        SizedBox(height: 16),
                        Text('No agents available'),
                        SizedBox(height: 8),
                        Text('Check backend connection', style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: agents.length,
                  itemBuilder: (context, index) {
                    final agent = agents[index];
                    final isSelected = agent.id == currentAgentId;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.smart_toy,
                            color: isSelected
                                ? Theme.of(context).colorScheme.onPrimary
                                : Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        title: Text(
                          agent.name,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : null,
                          ),
                        ),
                        subtitle: Text(
                          agent.description ?? 'ID: ${agent.id}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: isSelected
                            ? Icon(
                                Icons.check_circle,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : Icon(
                                Icons.circle_outlined,
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        onTap: () => _selectAgent(context, ref, agent),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _selectAgent(BuildContext context, WidgetRef ref, Agent agent) {
    ref.read(appConfigProvider.notifier).setAgentId(agent.id);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Selected ${agent.name}'),
        duration: const Duration(seconds: 1),
      ),
    );

    context.pop();
  }
}
