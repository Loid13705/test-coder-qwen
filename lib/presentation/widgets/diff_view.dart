/// Visualização de unified diff real (linhas +/-/@ vindas do tool loop).
library;

import 'dart:convert' show LineSplitter;

import 'package:flutter/material.dart';

import '../theme/vt_theme.dart';

class DiffView extends StatelessWidget {
  const DiffView({
    super.key,
    required this.filePath,
    required this.unifiedDiff,
    required this.additions,
    required this.deletions,
  });

  final String filePath;
  final String unifiedDiff;
  final int additions;
  final int deletions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VtTheme.of(context);
    final lines = unifiedDiff.isEmpty
        ? const <String>[]
        : const LineSplitter().convert(unifiedDiff.replaceAll('\r\n', '\n'));

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: vt.codeBackground,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.diff_together, size: 16, color: vt.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: SelectableText(filePath,
                      style: theme.textTheme.labelMedium,
                      overflow: TextOverflow.ellipsis),
                ),
                Text('+$additions',
                    style: TextStyle(
                        color: vt.riskLow, fontWeight: FontWeight.bold)),
                const SizedBox(width: 6),
                Text('−$deletions',
                    style: TextStyle(
                        color: vt.riskCritical, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Divider(height: 1, color: theme.dividerColor),
          Padding(
            padding: const EdgeInsets.all(4),
            child: SelectableText.rich(
              TextSpan(
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12, height: 1.35),
                children: [
                  for (final line in lines)
                    TextSpan(
                      text: '$line\n',
                      style: _styleFor(line, vt),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  TextStyle _styleFor(String line, VtColors vt) {
    if (line.startsWith('+++') || line.startsWith('---')) {
      return const TextStyle(fontWeight: FontWeight.bold);
    }
    if (line.startsWith('@@')) {
      return TextStyle(color: vt.accent);
    }
    if (line.startsWith('+')) {
      return TextStyle(color: vt.riskLow, backgroundColor: vt.diffAddition);
    }
    if (line.startsWith('-')) {
      return TextStyle(color: vt.riskCritical, backgroundColor: vt.diffDeletion);
    }
    return const TextStyle();
  }
}

