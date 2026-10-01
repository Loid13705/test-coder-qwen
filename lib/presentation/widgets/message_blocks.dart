/// Widgets de blocos de mensagem tipados (spec §CHAT — blocos tipados).
///
/// Cada bloco renderiza exatamente o que está persistido no banco; nada aqui
/// gera conteúdo — diffs, terminals e erros vêm crus do tool loop/provider.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/errors/vt_failure.dart';
import '../../application/chat_service.dart' show ToolCallStatus;
import '../theme/vt_theme.dart';
import 'diff_view.dart';

/// Interpreta os blocos JSON persistidos pelo ChatService
/// (`{'type': ...}`, mesma convenção do repository) em widgets reais.
class MessageBlocksView extends StatelessWidget {
  const MessageBlocksView({super.key, required this.blocks});
  final List<Map<String, Object?>> blocks;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in blocks) _BlockView(block: b),
      ],
    );
  }
}

class _BlockView extends StatelessWidget {
  const _BlockView({required this.block});
  final Map<String, Object?> block;

  @override
  Widget build(BuildContext context) {
    final type = block['type'] as String? ?? 'text';
    switch (type) {
      case 'markdown':
      case 'text':
        return MarkdownLite(text: block['text'] as String? ?? '');
      case 'code':
        return CodeCard(
          language: block['language'] as String? ?? 'text',
          code: block['code'] as String? ?? '',
          fileName: block['fileName'] as String?,
        );
      case 'diff':
        return DiffView(
          filePath: block['filePath'] as String? ?? '',
          unifiedDiff: block['unifiedDiff'] as String? ?? '',
          additions: (block['additions'] as num?)?.toInt() ?? 0,
          deletions: (block['deletions'] as num?)?.toInt() ?? 0,
        );
      case 'terminal':
        return TerminalCard(
          command: block['command'] as String? ?? '',
          exitCode: (block['exitCode'] as num?)?.toInt(),
          outputTail: block['outputTail'] as String? ?? '',
        );
      case 'tool_call':
        return ToolCallCard(
          callId: block['callId'] as String? ?? '',
          toolId: block['toolId'] as String? ?? '',
          argsJson: block['argsJson'] as String? ?? '{}',
          statusWire: block['status'] as String? ?? 'pending',
        );
      case 'error':
        return ErrorCard(failureJson: block);
      default:
        // Bloco desconhecido: mostra o JSON cru — nunca descarta em silêncio.
        return SelectableText(
          const JsonEncoder.withIndent('  ').convert(block),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        );
    }
  }
}

/// Renderizador Markdown enxuto SEM dependências externas: cabeçalhos, listas,
/// código cercado, negrito/itálico inline e links. Suficiente para chat; o
/// build Flutter completo pode trocar por `markdown_widget`.
class MarkdownLite extends StatelessWidget {
  const MarkdownLite({super.key, required this.text});
  final String text;

  static final _fence = RegExp(r'```(\w*)\n([\s\S]*?)```');

  @override
  Widget build(BuildContext context) {
    final widgets = <Widget>[];
    var rest = text;
    while (rest.isNotEmpty) {
      final m = _fence.firstMatch(rest);
      if (m == null) {
        widgets.add(_InlineMarkdown(source: rest));
        break;
      }
      final before = rest.substring(0, m.start);
      if (before.trim().isNotEmpty) {
        widgets.add(_InlineMarkdown(source: before));
      }
      widgets.add(CodeCard(
          language: m.group(1)?.isNotEmpty == true ? m.group(1)! : 'text',
          code: m.group(2) ?? ''));
      rest = rest.substring(m.end);
    }
    if (widgets.isEmpty) {
      widgets.add(const SizedBox.shrink());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final w in widgets)
          Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: w),
      ],
    );
  }
}

/// Texto markdown inline simples: linhas com #, -, e **negrito**.
class _InlineMarkdown extends StatelessWidget {
  const _InlineMarkdown({required this.source});
  final String source;

  @override
  Widget build(BuildContext context) {
    final lines = const LineSplitter().convert(source);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines) _line(context, line),
      ],
    );
  }

  Widget _line(BuildContext context, String line) {
    final theme = Theme.of(context);
    if (line.startsWith('### ')) {
      return Text(line.substring(4), style: theme.textTheme.titleSmall);
    }
    if (line.startsWith('## ')) {
      return Text(line.substring(3), style: theme.textTheme.titleMedium);
    }
    if (line.startsWith('# ')) {
      return Text(line.substring(2), style: theme.textTheme.titleLarge);
    }
    if (line.startsWith('- ') || line.startsWith('* ')) {
      return Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('•  ', style: theme.textTheme.bodyMedium),
            Expanded(child: _rich(context, line.substring(2), theme)),
          ],
        ),
      );
    }
    if (line.trim().isEmpty) return const SizedBox(height: 4);
    return _rich(context, line, theme);
  }

  static final _bold = RegExp(r'\*\*([^*]+)\*\*');
  static final _code = RegExp(r'`([^`]+)`');

  Widget _rich(BuildContext context, String s, ThemeData theme) {
    // Aplica negrito e code-span de forma sequencial simples.
    final spans = <InlineSpan>[];
    final combined =
        RegExp('${_bold.pattern}|${_code.pattern.replaceAll('(?<', '(?<c')}');
    var last = 0;
    for (final m in combined.allMatches(s)) {
      if (m.start > last) {
        spans.add(TextSpan(text: s.substring(last, m.start)));
      }
      if (m.group(1) != null) {
        spans.add(TextSpan(
            text: m.group(1),
            style: const TextStyle(fontWeight: FontWeight.bold)));
      } else {
        final g = m.group(2) ?? m.group(1) ?? '';
        spans.add(TextSpan(
            text: g,
            style: TextStyle(
                fontFamily: 'monospace',
                backgroundColor:
                    VtTheme.of(context).codeBackground.withOpacity(.8),
                color: VtTheme.of(context).accent)));
      }
      last = m.end;
    }
    if (last < s.length) spans.add(TextSpan(text: s.substring(last)));
    if (spans.isEmpty) spans.add(TextSpan(text: s));
    return SelectableText.rich(
        TextSpan(style: theme.textTheme.bodyMedium, children: spans));
  }
}

class CodeCard extends StatelessWidget {
  const CodeCard(
      {super.key, required this.language, required this.code, this.fileName});
  final String language;
  final String code;
  final String? fileName;

  @override
  Widget build(BuildContext context) {
    final vt = VtTheme.of(context);
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: vt.codeBackground,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(6)),
            ),
            child: Row(
              children: [
                Icon(Icons.code, size: 14, color: theme.hintColor),
                const SizedBox(width: 6),
                // Flexible + ellipsis: nome do arquivo/linguagem longo não
                // estoura o Row quando a janela fica estreita.
                Flexible(
                  child: Text(fileName ?? language,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall),
                ),
                const Spacer(),
                IconButton(
                  iconSize: 14,
                  tooltip: 'Copiar',
                  icon: const Icon(Icons.copy),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Código copiado'),
                          behavior: SnackBarBehavior.floating,
                          width: 240),
                    );
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                code,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12, height: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TerminalCard extends StatelessWidget {
  const TerminalCard(
      {super.key,
      required this.command,
      required this.exitCode,
      required this.outputTail});
  final String command;
  final int? exitCode;
  final String outputTail;

  @override
  Widget build(BuildContext context) {
    final vt = VtTheme.of(context);
    final theme = Theme.of(context);
    final ok = exitCode == 0;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: vt.codeBackground,
        border: Border.all(
            color: exitCode == null
                ? theme.dividerColor
                : (ok ? vt.riskLow : vt.riskCritical)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
            child: Row(
              children: [
                Icon(Icons.terminal, size: 14, color: theme.hintColor),
                const SizedBox(width: 6),
                Expanded(
                  child: SelectableText('\$ $command',
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
                if (exitCode != null)
                  Text('exit $exitCode',
                      style: TextStyle(
                          fontSize: 11,
                          color: ok ? vt.riskLow : vt.riskCritical,
                          fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          if (outputTail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: SelectableText(
                outputTail,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                maxLines: 15,
              ),
            ),
        ],
      ),
    );
  }
}

/// Card de tool call persistido (bloco `tool_call` do ChatService).
///
/// Renderiza exatamente o status gravado no banco (`ToolCallStatus.name`);
/// nunca infere sucesso — status ausente/inválido vira 'desconhecido'.
class ToolCallCard extends StatelessWidget {
  const ToolCallCard({
    super.key,
    required this.callId,
    required this.toolId,
    required this.argsJson,
    required this.statusWire,
  });

  final String callId;
  final String toolId;
  final String argsJson;
  final String statusWire;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final status = ToolCallStatus.values.firstWhere(
      (s) => s.name == statusWire,
      orElse: () => ToolCallStatus.pending,
    );
    final known = ToolCallStatus.values.any((s) => s.name == statusWire);
    final (icon, color, label) = switch (status) {
      ToolCallStatus.pending => (
          Icons.hourglass_empty,
          theme.hintColor,
          'aguardando aprovação'
        ),
      ToolCallStatus.approved => (
          Icons.check_circle_outline,
          vt.riskLow,
          'aprovada'
        ),
      ToolCallStatus.executing => (
          Icons.play_circle_outline,
          vt.accent,
          'executando…'
        ),
      ToolCallStatus.succeeded => (
          Icons.task_alt,
          vt.riskLow,
          'concluída'
        ),
      ToolCallStatus.failed => (
          Icons.error_outline,
          vt.riskCritical,
          'falhou'
        ),
      ToolCallStatus.blocked => (
          Icons.block,
          vt.riskHigh,
          'bloqueada'
        ),
    };
    // Args como JSON indentado quando parseável; cru caso contrário.
    final prettyArgs = () {
      try {
        return const JsonEncoder.withIndent('  ').convert(jsonDecode(argsJson));
      } catch (_) {
        return argsJson;
      }
    }();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: vt.codeBackground.withOpacity(0.5),
        border: Border.all(color: color.withOpacity(0.6)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ExpansionTile(
        shape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        leading: Icon(icon, size: 16, color: color),
        title: Row(
          children: [
            Flexible(
              child: Text(toolId,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12)),
            ),
            const SizedBox(width: 8),
            Text(known ? label : 'status desconhecido ($statusWire)',
                style:
                    theme.textTheme.labelSmall?.copyWith(color: color)),
          ],
        ),
        subtitle: Text(callId,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.hintColor)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                prettyArgs,
                maxLines: 12,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ErrorCard extends StatelessWidget {
  const ErrorCard({super.key, required this.failureJson});

  /// Payload de `VtFailure.toJson()` salvo pelo ChatService.
  final Map<String, Object?> failureJson;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final code =
        VtErrorCode.fromWire(failureJson['code'] as String? ?? 'internal_error');
    final message = failureJson['message'] as String? ?? '';
    final actions = ((failureJson['recoveryActions'] as List?) ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((e) => e.cast<String, Object?>())
        .toList();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: vt.diffDeletion.withOpacity(0.35),
        border: Border.all(color: vt.riskCritical),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, color: vt.riskCritical, size: 18),
              const SizedBox(width: 6),
              Text(code.wire,
                  style: TextStyle(
                      color: vt.riskCritical,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      fontSize: 12)),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(message, style: theme.textTheme.bodyMedium),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final a in actions)
                  Chip(
                    label: Text('${a['label']}',
                        style: const TextStyle(fontSize: 11)),
                    avatar: const Icon(Icons.build_circle_outlined, size: 16),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
