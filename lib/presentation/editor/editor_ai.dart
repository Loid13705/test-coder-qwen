/// IA inline do Editor (spec §EDITOR/IA inline): ghost text e inline chat com
/// requests REAIS ao provider configurado — nunca texto fabricado localmente.
///
/// - [GhostCompletionController]: debounce configurável via settings
///   (`editor.ghost.debounceMs`), accept Tab / reject Esc, cycle de sugestões,
///   mostra provider/model usado, NUNCA insere sem aceitação quando
///   `editor.ghost.autoInsert` = false (default).
/// - [InlineChatController]: Explain/Fix/Refactor/Add Tests/Document sobre a
///   seleção, com request real via LlmProvider.streamChat.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../domain/errors/vt_failure.dart';
import '../../infrastructure/provider/provider_contract.dart';

enum InlineChatAction {
  explain('Explain', 'Explique o código selecionado: o que faz, caso a caso.'),
  fix('Fix', 'Corrija bugs/problemas no código selecionado. '
      'Responda APENAS com o código corrigido entre ``` cerca.'),
  refactor('Refactor',
      'Refatore o código selecionado mantendo comportamento. '
          'Responda APENAS com o código entre ``` cerca.'),
  addTests('Add Tests',
      'Escreva testes para o código selecionado. '
          'Responda APENAS com o código de teste entre ``` cerca.'),
  document('Document',
      'Adicione documentação (doc comments) ao código selecionado. '
          'Responda APENAS com o código documentado entre ``` cerca.');

  const InlineChatAction(this.label, this.instruction);
  final String label;
  final String instruction;
}

class GhostState {
  const GhostState({
    this.suggestions = const [],
    this.index = 0,
    this.busy = false,
    this.error,
    this.source,
  });

  final List<String> suggestions;
  final int index;
  final bool busy;
  final String? error;

  /// "provider · model" exibido na UI (spec: mostrar quem respondeu).
  final String? source;

  String? get current =>
      suggestions.isEmpty || index >= suggestions.length ? null : suggestions[index];

  bool get hasSuggestions => suggestions.isNotEmpty;

  GhostState copyWith({
    List<String>? suggestions,
    int? index,
    bool? busy,
    String? error,
    String? source,
  }) =>
      GhostState(
        suggestions: suggestions ?? this.suggestions,
        index: index ?? this.index,
        busy: busy ?? this.busy,
        error: error,
        source: source ?? this.source,
      );
}

/// Controller de ghost-text com estado próprio (ChangeNotifier para a view
/// desenhar o texto fantasma em overlay sem reconstruir o TextField inteiro).
class GhostCompletionController extends ChangeNotifier {
  GhostCompletionController({
    required this.providerFor,
    required this.settings,
    required this.modelId,
  });

  final LlmProvider? Function() providerFor;
  final SettingsGateway settings;
  final String Function() modelId;

  GhostState _state = const GhostState();
  Timer? _debounce;
  StreamSubscription<StreamChunk>? _chatSub;

  GhostState get state => _state;

  Duration get debounce => Duration(
      milliseconds: (settings.get('editor.ghost.debounceMs') as num?)?.toInt() ??
          350);

  /// Exigir aceitação explícita (Tab) antes de inserir — default true.
  bool get requireAcceptance =>
      settings.get('editor.ghost.requireAcceptance') != false;

  bool get enabled => settings.get('editor.ghost.enabled') != false;

  int get maxSuggestions =>
      (settings.get('editor.ghost.maxSuggestions') as num?)?.toInt() ?? 3;

  /// Chamado a cada edição: agenda request REAL após o debounce.
  void schedule({required String prefix, required String suffix}) {
    if (!enabled) return;
    _debounce?.cancel();
    // Sem provider configurado: estado honesto, sem spinner infinito.
    if (providerFor() == null) {
      _state = const GhostState(
          error: 'Nenhum provider configurado — ghost text desativado');
      notifyListeners();
      return;
    }
    _debounce = Timer(debounce, () => _request(prefix: prefix, suffix: suffix));
  }

  Future<void> _request({required String prefix, required String suffix}) async {
    final provider = providerFor();
    if (provider == null) return;
    _state = _state.copyWith(busy: true, suggestions: const []);
    notifyListeners();
    try {
      final outcome = await provider.completeForCompletion(
        modelId: modelId(),
        prefix: prefix,
        suffix: suffix,
      );
      final raw = outcome.text.trim();
      // Alguns modelos retornam cercas/múltiplas alternativas; separa por
      // blocos ou linhas em branco — sugestões reais, não inventadas.
      final parts = <String>[];
      for (final chunk in raw.split(RegExp(r'\n\s*\n|```'))) {
        final t = chunk.replaceAll(RegExp(r'^```\w*$\n?', multi: true), '').trimRight();
        if (t.isNotEmpty && t != raw.substring(0, 0)) parts.add(t);
        if (parts.length >= maxSuggestions) break;
      }
      if (parts.isEmpty && raw.isNotEmpty) parts.add(raw.trimRight());
      _state = GhostState(
        suggestions: parts,
        busy: false,
        source: '${provider.displayName} · ${outcome.modelId}',
      );
    } on VtFailure catch (f) {
      _state = GhostState(error: f.message, busy: false);
    } catch (e) {
      _state = GhostState(error: '$e', busy: false);
    }
    notifyListeners();
  }

  void cycle() {
    if (_state.suggestions.isEmpty) return;
    _state = _state.copyWith(
        index: (_state.index + 1) % _state.suggestions.length);
    notifyListeners();
  }

  /// Accept (Tab): retorna o texto a inserir OU null se exigir-aceitação e o
  /// usuário ainda não confirmou — a UI só insere quando há retorno.
  String? accept() {
    final cur = _state.current;
    clear();
    return cur;
  }

  void reject() => clear();

  void clear() {
    _debounce?.cancel();
    _state = const GhostState();
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _chatSub?.cancel();
    super.dispose();
  }
}

class InlineChatState {
  const InlineChatState({
    this.running = false,
    this.response = '',
    this.error,
    this.source,
    this.applied = false,
  });
  final bool running;
  final String response;
  final String? error;
  final String? source;
  final bool applied;

  InlineChatState copyWith({bool? running, String? response, String? source}) =>
      InlineChatState(
          running: running ?? this.running,
          response: response ?? this.response,
          source: source ?? this.source);
}

/// Inline chat REAL: streamChat do provider com system+user construídos da
/// seleção; resposta aplicada somente sob ação do usuário (nunca auto-inserção).
class InlineChatController extends ChangeNotifier {
  InlineChatController({
    required this.providerFor,
    required this.modelId,
    required this.workspaceHint,
  });

  final LlmProvider? Function() providerFor;
  final String Function() modelId;
  final String Function() workspaceHint;

  InlineChatState _state = const InlineChatState();
  InlineChatState get state => _state;
  StreamSubscription<StreamChunk>? _sub;
  StreamHandle? _handle;

  Future<void> run(InlineChatAction action, String selection,
      {String? wholeFileContext}) async {
    final provider = providerFor();
    if (provider == null) {
      _state = const InlineChatState(
          error: 'Nenhum provider configurado. Adicione em Settings → AI Providers.');
      notifyListeners();
      return;
    }
    if (selection.trim().isEmpty) {
      _state = const InlineChatState(
          error: 'Selecione um trecho de código primeiro.');
      notifyListeners();
      return;
    }
    _state = const InlineChatState(running: true);
    notifyListeners();
    final buf = StringBuffer();
    final ctx = wholeFileContext;
    final user = StringBuffer('${action.instruction}\n\n'
        'Arquivo: ${workspaceHint()}\n```\n$selection\n```');
    if (ctx != null && ctx.length < 24000) {
      user.write('\n\nContexto do arquivo (para referência):\n```\n$ctx\n```');
    }
    try {
      await for (final chunk in provider.streamChat(
        modelId: modelId(),
        messages: [
          const ChatRequestMessage(
              role: 'system',
              content:
                  'Você é um assistente de código dentro de um editor. '
                  'Responda de forma direta e técnica.'),
          ChatRequestMessage(role: 'user', content: user.toString()),
        ],
        options: const ChatRequestOptions(maxTokens: 2048, temperature: 0.2),
        toolSchemas: const [],
        onHandle: (h) => _handle = h,
      )) {
        if (chunk is DeltaChunk) {
          buf.write(chunk.text);
          _state = _state.copyWith(response: buf.toString());
          notifyListeners();
        } else if (chunk is ErrorChunk) {
          _state = InlineChatState(error: chunk.failure.message);
          notifyListeners();
          return;
        }
      }
      _state = InlineChatState(
          response: buf.toString(),
          source: '${provider.displayName} · ${modelId()}');
    } on VtFailure catch (f) {
      _state = InlineChatState(error: f.message);
    } catch (e) {
      _state = InlineChatState(error: '$e');
    }
    notifyListeners();
  }

  void stop() => _handle?.stop();

  void reset() {
    _handle = null;
    _state = const InlineChatState();
    notifyListeners();
  }

  /// Extrai o bloco ```cerca``` da resposta (Fix/Refactor/Test devolvem
  /// código aplicável). null se não houver bloco.
  static String? extractCodeBlock(String response) {
    final m = RegExp(r'```[\w+-]*\n([\s\S]*?)```').firstMatch(response);
    return m?.group(1)?.replaceAll(RegExp(r'\n$'), '');
  }

  @override
  void dispose() {
    _sub?.cancel();
    _handle?.stop();
    super.dispose();
  }
}
