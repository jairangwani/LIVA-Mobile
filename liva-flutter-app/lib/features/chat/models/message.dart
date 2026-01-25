import 'package:equatable/equatable.dart';

/// Message role.
enum MessageRole {
  user,
  assistant,
  system,
}

/// Chat message model.
class ChatMessage extends Equatable {
  final String id;
  final String content;
  final MessageRole role;
  final DateTime timestamp;

  const ChatMessage({
    required this.id,
    required this.content,
    required this.role,
    required this.timestamp,
  });

  @override
  List<Object?> get props => [id, content, role, timestamp];

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'role': role.name,
        'timestamp': timestamp.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      content: json['content'] as String,
      role: MessageRole.values.firstWhere(
        (r) => r.name == json['role'],
        orElse: () => MessageRole.system,
      ),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}
