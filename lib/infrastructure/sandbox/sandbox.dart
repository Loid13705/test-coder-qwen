/// Sandbox de filesystem e rede (spec §SEGURANÇA E PRIVACIDADE).
///
/// - Escrita restrita às raízes do workspace + temp da app.
/// - Leitura idem, salvo grants explícitos de leitura (auditados).
/// - Proteção path traversal (normalização léxica antes de tocar no disco).
/// - Política de symlinks configurável.
library;

import 'dart:convert';
import 'dart:io';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';
import '../process/process_utils.dart';

class ExternalGrant {
  const ExternalGrant(
      {required this.path, required this.writable, required this.grantedAt});
  final String path;
  final bool writable;
  final DateTime grantedAt;

  Map<String, Object?> toJson() => {
        'path': path,
        'writable': writable,
        'grantedAt': grantedAt.toIso8601String()
      };

  factory ExternalGrant.fromJson(Map<String, Object?> j) => ExternalGrant(
        path: j['path'] as String,
        writable: j['writable'] as bool? ?? false,
        grantedAt: DateTime.parse(j['grantedAt'] as String),
      );
}

class WorkspaceSandbox implements SandboxGateway {
  WorkspaceSandbox({
    required List<String> roots,
    required this.tempDir,
    this.followSymlinks = false,
    this.excludePatterns = const ['.git', 'build', '.dart_tool'],
    List<ExternalGrant> grants = const [],
    this.allowedDomains = const <String>{},
    this.allowAllLocalRead = true,
  }) : _grants = List.of(grants) {
    _roots = roots.map(_canonical).toList();
  }

  late List<String> _roots;
  final String tempDir;
  final bool followSymlinks;
  final List<String> excludePatterns;
  final Set<String> allowedDomains;

  /// Ler de qualquer caminho local é permitido por default (single-user IDE);
  /// escrita NUNCA fora de roots/temp/grants-writable.
  final bool allowAllLocalRead;
  final List<ExternalGrant> _grants;

  static String _canonical(String p) => lexicalNormalize(normalizeSlashes(p));

  String _normalize(String rawPath, List<String> roots) {
    if (rawPath.isEmpty) {
      throw VtFailure(
          code: VtErrorCode.validationFailed, message: 'Caminho vazio.');
    }
    var p = rawPath;
    if (!isAbsolute(p)) {
      if (roots.isEmpty) {
        throw VtFailure(
          code: VtErrorCode.validationFailed,
          message:
              'Workspace ainda não aberto — não há raiz para resolver caminho relativo.',
          recoveryActions: const [
            RecoveryAction(
                kind: 'open_settings', label: 'Abrir pasta de projeto')
          ],
        );
      }
      p = joinPath(roots.first, p);
    }
    return lexicalNormalize(p);
  }

  bool _inside(String candidate, String parent) {
    final c = normalizeSlashes(candidate);
    final par = normalizeSlashes(parent);
    return c == par || c.startsWith('$par/');
  }

  bool _inRoots(String p, {bool includeTemp = false}) {
    for (final r in _roots) {
      if (_inside(p, r)) return true;
    }
    if (includeTemp && _inside(p, normalizeSlashes(tempDir))) return true;
    return false;
  }

  void _checkSymlinkPolicy(String p) {
    if (followSymlinks) return;
    // Se o alvo final for symlink e não estiver dentro das roots, bloqueia.
    final linkType = FileSystemEntity.typeSync(p, followLinks: false);
    if (linkType == FileSystemEntityType.link) {
      throw VtFailure(
        code: VtErrorCode.permissionDenied,
        message:
            'Symlink policy: "$p" é um symlink e a política atual não segue links. '
            'Ajuste filesystem.followSymlinks em Settings → FileSystem.',
      );
    }
  }

  @override
  Future<String> resolveReadable(String rawPath, ToolContext ctx) async {
    final p = _normalize(
        rawPath, ctx.workspaceRoots.isEmpty ? _roots : ctx.workspaceRoots);
    _checkSymlinkPolicy(p);
    if (!_inRoots(p, includeTemp: true) && !allowAllLocalRead) {
      final grant = _grants.any((g) => _inside(p, g.path));
      if (!grant) throw VtFailure.pathOutOfSandbox(p);
    }
    if (!isAbsolute(p)) throw VtFailure.pathOutOfSandbox(p);
    return p;
  }

  @override
  Future<String> resolveWritable(String rawPath, ToolContext ctx) async {
    final roots = ctx.workspaceRoots.isEmpty ? _roots : ctx.workspaceRoots;
    final p = _normalize(rawPath, roots);
    _checkSymlinkPolicy(p);
    if (_inRoots(p, includeTemp: true)) return p;
    final grant =
        _grants.where((g) => g.writable).any((g) => _inside(p, g.path));
    if (!grant) throw VtFailure.pathOutOfSandbox(p);
    return p;
  }

  /// Concede acesso externo auditado (tool permission.grant chama isto).
  void grant(ExternalGrant g) {
    if (!_grants.any((e) => e.path == g.path)) _grants.add(g);
  }

  List<ExternalGrant> get grants => List.unmodifiable(_grants);

  @override
  bool isAllowedDomain(String domain, ToolContext ctx) {
    final d = normalizeSlashes(domain).toLowerCase();
    if (allowedDomains.isEmpty) {
      return false; // sem allowlist ⇒ nada de rede externa
    }
    for (final allowed in allowedDomains) {
      final a = allowed.toLowerCase();
      if (d == a || d.endsWith('.${a.replaceFirst('.', '')}')) return true;
    }
    return false;
  }

  /// Persistência dos grants (chamado pelo storage real).
  String exportGrantsJson() =>
      jsonEncode([for (final g in _grants) g.toJson()]);

  void importGrantsJson(String s) {
    _grants
      ..clear()
      ..addAll([
        for (final e in (jsonDecode(s) as List))
          ExternalGrant.fromJson((e as Map).cast<String, Object?>())
      ]);
  }
}
