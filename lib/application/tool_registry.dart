/// Tool registry da spec (§TOOL REGISTRY): catálogo tipado, resolução por id,
/// schemas prontos para o wire dos providers e filtro por capacidade/allowlist.
///
/// Sem mocks: registrar uma tool é registrar a implementação real; health e
/// execute delegam à infra (dart:io / git / sandbox) sem simulação.
library;

import '../domain/tools/tool_contract.dart';

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
