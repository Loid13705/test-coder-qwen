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
        // Forma canônica `'type'` mesmo que o writer tenha gravado `'kind'`
        // (MessageBlock.toJson usa 'kind'; o stream do chat usa 'type').
        blocks: normalizeStoredBlocks((jsonDecode(r['blocks_json'] as String) as List)
            .map((e) => (e as Map).cast<String, Object?>())
            .toList()),
        status: r['status'] as String,
        // Colunas opcionais são gravadas como '' via bind paramétrico
        // (nunca NULL interpolado); normaliza '' de volta para null.
        modelId: _nullIfEmpty(r['model_id']),
        mode: _nullIfEmpty(r['mode']),
        usageJson: _decodeMapOrNull(r['usage_json']),
      );

  static String? _nullIfEmpty(Object? v) {
    final s = v is String ? v : null;
    return (s == null || s.isEmpty) ? null : s;
  }

  static Map<String, Object?>? _decodeMapOrNull(Object? raw) {
    final s = _nullIfEmpty(raw);
    if (s == null) return null;
    return (jsonDecode(s) as Map).cast<String, Object?>();
  }

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
  pinned INTEGER NOT NULL DEFAULT 0,
  tags TEXT NOT NULL DEFAULT '[]',
  folder TEXT NOT NULL DEFAULT '',
  archived_at TEXT,
  deleted_at TEXT,
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','archived','deleted')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_conv_ws ON conversations(workspace_id, updated_at);
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL
    REFERENCES conversations(id) ON DELETE CASCADE,
  role TEXT NOT NULL
    CHECK (role IN ('user','assistant','system','tool')),
  model_id TEXT NOT NULL DEFAULT '',
  mode TEXT NOT NULL DEFAULT '',
  blocks_json TEXT NOT NULL,
  status TEXT NOT NULL
    CHECK (status IN ('draft','streaming','complete','completed','cancelled_partial','failed')),
  usage_json TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conversation_id, id);
''';

/// Migração idempotente (adiciona colunas que existam na spec mas não no DB
/// criado por versões antigas do schema). `ALTER TABLE ADD COLUMN` é real e
/// persiste os dados existentes.
const kChatMigrations = [
  "ALTER TABLE conversations ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE conversations ADD COLUMN tags TEXT NOT NULL DEFAULT '[]'",
  "ALTER TABLE conversations ADD COLUMN folder TEXT NOT NULL DEFAULT ''",
  "ALTER TABLE conversations ADD COLUMN archived_at TEXT",
  "ALTER TABLE conversations ADD COLUMN deleted_at TEXT",
];

/// Normaliza a forma canônica de um bloco persistido: o writer aceita tanto
/// `'type'` quanto `'kind'` como discriminador; o reader SEMPRE produz
/// `'type'`, para a UI nunca precisar de dois caminhos.
Map<String, Object?> normalizeStoredBlock(Map<String, Object?> b) {
  if (b.containsKey('type')) return b;
  final out = Map<String, Object?>.of(b);
  out['type'] = b['kind'] as String? ?? 'text';
  return out;
}

List<Map<String, Object?>> normalizeStoredBlocks(List<Map<String, Object?>> bs) =>
    [for (final b in bs) normalizeStoredBlock(b)];
