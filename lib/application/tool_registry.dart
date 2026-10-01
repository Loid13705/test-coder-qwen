/// Tool registry da spec (§TOOL REGISTRY): catálogo tipado, resolução por id,
/// schemas prontos para o wire dos providers e filtro por capacidade/allowlist.
///
/// Sem mocks: registrar uma tool é registrar a implementação real; health e
/// execute delegam à infra (dart:io / git / sandbox) sem simulação.
library;

import 'dart:io';

import '../domain/tools/tool_contract.dart';

/// Procura binário no PATH real (síncrono — usado em filtros de prompt).
String? findBinaryReal(String name) {
  final paths =
      (Platform.environment['PATH'] ?? '').split(Platform.pathSeparator);
  final exts = Platform.isWindows ? ['.exe', '.cmd', '.bat', ''] : [''];
  for (final dir in paths) {
    if (dir.isEmpty) continue;
    for (final ext in exts) {
      final cand = '$dir${Platform.pathSeparator}$name$ext';
      try {
        if (File(cand).existsSync()) return cand;
      } on FileSystemException {
        continue;
      }
    }
  }
  return null;
}

class ToolRegistry {
  final Map<String, VtTool<ToolInput, ToolOutput>> _byId = {};

  void register(VtTool<ToolInput, ToolOutput> tool) {
    final existing = _byId[tool.id];
    if (existing != null && !identical(existing, tool)) {
      throw ArgumentError('Tool "${tool.id}" já registrada com outra instância.');
    }
    _byId[tool.id] = tool;
  }

  void unregister(String id) => _byId.remove(id);

  VtTool<ToolInput, ToolOutput>? byId(String id) => _byId[id];

  /// Capacidades presentes no host, verificadas DE FATO (binário no PATH /
  /// ambiente), não assumidas. Usado por [schemasForPrompt] para omitir do
  /// wire as tools que falhariam por capacidade ausente — a UI de catálogo
  /// continua mostrando todas via health().
  Future<Set<String>> availableCapabilities() async {
    final caps = <String>{};
    for (final t in all) {
      for (final c in t.capabilities) {
        if (caps.contains(c)) continue;
        if (await _capabilityPresent(c)) caps.add(c);
      }
    }
    return caps;
  }

  static Future<bool> _capabilityPresent(String cap) async {
    switch (cap) {
      case 'git':
        return findBinaryReal('git') != null;
      case 'dart':
        return findBinaryReal('dart') != null;
      case 'flutter':
        return findBinaryReal('flutter') != null;
      case 'devtools':
        return findBinaryReal('dart') != null ||
            findBinaryReal('flutter') != null;
      case 'network':
        // presença de interface ativa: tentativa barata via env/rotas reais
        return true; // dart:io sempre pode tentar sockets; erro real aparece no execute
      case 'sqlite':
        return true; // carregado na bootstrap; se falhou, nem chegamos aqui
      default:
        return true; // capacidade desconhecida: deixa executar e falhar honesto
    }
  }

  bool contains(String id) => _byId.containsKey(id);

  List<VtTool<ToolInput, ToolOutput>> get all =>
      _byId.values.toList(growable: false);

  /// Catálogo completo (entries estruturadas do contrato).
  List<Map<String, Object?>> catalog() => [
        for (final t in all) t.catalogEntry(),
      ];

  /// Schemas no formato aceito por `LlmProvider.streamChat(toolSchemas:)`:
  /// `{name, description, parameters}` (o provider embrulha em
  /// `{"type":"function","function":...}` ou `input_schema` conforme o wire).
  ///
  /// - `allowedIds`: allowlist do ChatRequestOptions — se não-vazia, só essas
  ///   tools vão ao modelo.
  /// - `availableCapabilities`: capacidades presentes no host (ex.: {'git'});
  ///   tools que exigem capacidade ausente são omitidas do prompt (a UI de
  ///   catálogo as mostra como degraded via health()).
  List<Map<String, Object?>> schemasForPrompt({
    List<String> allowedIds = const [],
    Set<String>? availableCapabilities,
  }) {
    final allow = allowedIds.isEmpty ? null : allowedIds.toSet();
    return [
      for (final t in all)
        if (allow == null || allow.contains(t.id))
          if (availableCapabilities == null ||
              t.capabilities.every(availableCapabilities.contains))
            {
              'name': t.id,
              'description': t.description,
              'parameters': t.inputSchema,
            },
    ];
  }
}
