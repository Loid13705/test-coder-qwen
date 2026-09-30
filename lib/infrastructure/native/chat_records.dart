/// Registros persistidos do chat (schema local-first em SQLite).
///
/// Fica em infrastructure/native para evitar ciclo de imports com o
/// ChatRepository; a camada de aplicação consome via repositório.
library;

import 'dart:convert';

class MessageRecord {
  const MessageRecord({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.createdAt,
    required this.blocks,
    required this.status,
    this.modelId,
    this.mode,
    this.usageJson,
  });

  factory MessageRecord.fromRow(Map<String, Object?> r) => MessageRecord(
        id: r['id'] as String,
        conversationId: r['conversation_id'] as String,
        role: r['role'] as String,
        createdAt: r['created_at'] as String,
        blocks: (jsonDecode(r['blocks_json'] as String) as List)
            .map((e) => (e as Map).cast<String, Object?>())
            .toList(),
        status: r['status'] as String,
        modelId: r['model_id'] as String?,
        mode: r['mode'] as String?,
        usageJson: r['usage_json'] == null
            ? null
            : (jsonDecode(r['usage_json'] as String) as Map)
                .cast<String, Object?>(),
      );

  final String id;
  final String conversationId;
  final String role;
  final String createdAt;
  final List<Map<String, Object?>> blocks;
  final String status;
  final String? modelId;
  final String? mode;
  final Map<String, Object?>? usageJson;
}

const kChatSchema = '''
CREATE TABLE IF NOT EXISTS conversations (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  title TEXT NOT NULL,
  parent_id TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_conv_ws ON conversations(workspace_id, updated_at);
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  role TEXT NOT NULL,
  model_id TEXT,
  mode TEXT,
  blocks_json TEXT NOT NULL,
  status TEXT NOT NULL,
  usage_json TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conversation_id, id);
''';
