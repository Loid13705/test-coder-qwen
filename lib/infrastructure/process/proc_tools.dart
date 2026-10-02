/// Tools de processo e terminal (spec catálogo: proc.* / term.*).
///
/// Tudo REAL, sem simulação:
/// - `proc.list`     — varre o SO (`ps -eo pid,ppid,stat,comm,args` POSIX /
///                     `tasklist /fo csv` Windows) e cruza com as sessões
///                     gerenciadas pelo app; filtro own/workspace/name.
/// - `proc.kill`     — sinal real no PID-alvo. Guarda dura: recusa PID 0/próprio
///                     e qualquer processo fora do escopo techVT quando `own`
///                     não foi ativado explicitamente. Escalada SIGTERM→SIGKILL
///                     reportada honestamente.
/// - `term.read_output` — lê o buffer ringueiro REAL da sessão (flutter run ou
///                     proc.start), com paginação por bytes a partir do fim e
///                     flags de truncamento/drops — nunca esconde que faltou.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/errors/vt_failure.dart';
import '../../domain/tools/tool_contract.dart';
import 'process_utils.dart';
import 'session_store.dart';

Future<ToolResult<O>> _guard<O extends ToolOutput>(
    VtTool<dynamic, O> tool, Future<ToolResult<O>> Function() body) async {
  try {
    return await body().timeout(tool.timeout);
  } on TimeoutException {
    return ToolFailureResult<O>(VtFailure.timeout(tool.timeout));
  } on VtFailure catch (f) {
    return ToolFailureResult<O>(f);
  } on FormatException catch (e) {
    return ToolFailureResult<O>(VtFailure(
        code: VtErrorCode.validationFailed, message: e.message));
  }
}

abstract class _ProcTool extends VtTool<MapToolInput, TextOutput> {
  _ProcTool(this.sessions);
  final SessionStore sessions;

  @override
  List<String> get capabilities => const ['process'];
  @override
  Duration get timeout => const Duration(seconds: 30);
  @override
  RetryPolicy get retryPolicy => const RetryPolicy();
  @override
  Map<String, Object?> get outputSchema => const {'type': 'object'};
  @override
  bool get isIdempotent => true;
  @override
  RiskLevel get risk => RiskLevel.readOnly;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.auto;

  @override
  Future<MapToolInput> parseInput(Map<String, Object?> raw) async {
    validateInput(raw);
    return MapToolInput(raw);
  }

  @override
  Future<ToolHealth> health(ToolContext ctx) async => const HealthOk();

  ToolSuccess<TextOutput> ok(Object data) => ToolSuccess(
      data: TextOutput(const JsonEncoder.withIndent('  ').convert(data)));

  String workingDir(ToolContext ctx) => ctx.workspaceRoots.isEmpty
      ? Directory.current.path
      : ctx.workspaceRoots.first;
}

bool _isOwnName(String name) {
  final lower = name.toLowerCase();
  for (final n in kTechvtOwnProcNames) {
    if (lower.contains(n)) return true;
  }
  return false;
}

// ---------------------------------------------------------------- proc.list
class ProcListTool extends _ProcTool {
  ProcListTool(super.sessions);

  @override
  String get id => 'proc.list';
  @override
  String get title => 'Lista processos';
  @override
  String get description =>
      'Lista processos REAIS visíveis ao usuário: varre o sistema (ps/tasklist) '
      'e marca as sessões gerenciadas por este app (flutter run, proc.start). '
      'Filtros: own (nomes techVT), workspace (cwd sob a raiz), name (substring).';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'own': {
            'type': 'boolean',
            'description':
                'Somente processos techVT/dart/flutter/gradle/java (default false).'
          },
          'workspace': {
            'type': 'boolean',
            'description':
                'Somente sessões gerenciadas cujo cwd está sob a raiz do '
                    'workspace (default false).'
          },
          'name': {
            'type': 'string',
            'description': 'Substring (case-insensitive) em nome/args.'
          },
          'limit': {
            'type': 'integer',
            'description': 'Máximo de itens (default 100, máx 500).'
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) =>
      _guard(this, () async {
        final own = input.boolOf('own');
        final wsOnly = input.boolOf('workspace');
        final nameFilter = input.str('name').toLowerCase();
        final limit = (input.intOrNull('limit') ?? 100).clamp(1, 500);

        final managedPids = <int>{
          for (final m in sessions.managed) m.pid,
          for (final f in sessions.flutterRuns) f.proc.pid,
        };
        final root = normalizeSlashes(workingDir(ctx));

        final procs = await listSystemProcessesReal();
        final items = <Map<String, Object?>>[];
        for (final p in procs) {
          final pid = p['pid'];
          if (pid is! int) continue;
          final name = (p['name']?.toString() ?? '');
          final args = (p['args']?.toString() ?? '');
          if (own && !_isOwnName(name) && !managedPids.contains(pid)) {
            continue;
          }
          if (nameFilter.isNotEmpty &&
              !name.toLowerCase().contains(nameFilter) &&
              !args.toLowerCase().contains(nameFilter)) {
            continue;
          }
          items.add({
            ...p,
            'managed': managedPids.contains(pid),
            'underWorkspace': managedPids.contains(pid),
          });
        }
        // Sessões gerenciadas entram mesmo se o ps não as mostrar (ex.:
        // Windows tasklist sem coluna args) — são a fonte mais rica.
        final extra = <Map<String, Object?>>[];
        for (final m in sessions.managed) {
          if (wsOnly && !normalizeSlashes(m.cwd).startsWith(root)) continue;
          if (items.any((i) => i['pid'] == m.pid)) continue;
          extra.add({...m.describe(), 'source': 'managed'});
        }
        for (final f in sessions.flutterRuns) {
          if (items.any((i) => i['pid'] == f.proc.pid)) continue;
          extra.add({
            'pid': f.proc.pid,
            'name': 'flutter',
            'args': 'run -d ${f.deviceId}',
            'managed': true,
            'sessionId': 'flutter-run:${f.deviceId}',
            'alive': f.alive,
            'exitCode': f.exitCode,
            'startedAt': f.registeredAt.toIso8601String(),
            'source': 'managed',
          }..removeWhere((_, v) => v == null));
        }
        final merged = [...extra, ...items];
        final shown = wsOnly
            ? merged
                .where((i) =>
                    i['source'] == 'managed' || i['managed'] == true)
                .toList()
            : merged;
        return ok({
          'count': shown.length > limit ? limit : shown.length,
          'totalMatched': shown.length,
          'truncated': shown.length > limit,
          'processes': shown.take(limit).toList(),
        });
      });
}

// ---------------------------------------------------------------- proc.kill
class ProcKillTool extends _ProcTool {
  ProcKillTool(super.sessions);

  @override
  String get id => 'proc.kill';
  @override
  String get title => 'Mata processo';
  @override
  String get description =>
      'Envia sinal REAL a um processo: sessão gerenciada por id (proc-N / '
      'flutter-run:<device>) ou PID numérico. Default SIGTERM com escalada a '
      'SIGKILL após 2s (reportada). Guarda: recusa PID 0, o PID deste app e, '
      'sem scope="own", qualquer processo não-gerenciado — matar avulso do SO '
      'exige intenção explícita.';
  @override
  RiskLevel get risk => RiskLevel.destructive;
  @override
  ApprovalPolicyMode get defaultApproval => ApprovalPolicyMode.explicitApproval;
  @override
  bool get isIdempotent => false;

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['target'],
        'properties': {
          'target': {
            'type': 'string',
            'description': 'Id da sessão gerenciada ou PID numérico.'
          },
          'signal': {
            'type': 'integer',
            'description':
                'Sinal: 15 SIGTERM (default), 9 SIGKILL, 2 SIGINT (só para '
                    'sessões gerenciadas).'
          },
          'scope': {
            'type': 'string',
            'enum': ['auto', 'own'],
            'description':
                '"own" permite PID externo cujo nome pertence à família '
                    'techVT/dart/flutter/gradle/java. "auto" (default) só '
                    'mata sessões gerenciadas.'
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) =>
      _guard(this, () async {
        final target = input.str('target');
        final sig = input.intOrNull('signal') ?? 15;
        final scope = input.str('scope').isEmpty ? 'auto' : input.str('scope');
        if (sig != 2 && sig != 9 && sig != 15) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Sinal $sig não suportado — use 2 (SIGINT, gerenciado), '
                '9 (SIGKILL) ou 15 (SIGTERM).',
          ));
        }
        final myPid = pid;
        int? pidNum;
        ManagedProcess? managed;
        FlutterRunSession? frun;
        final resolved = sessions.resolveOutputSession(target);
        if (resolved is ManagedProcess) {
          managed = resolved;
          pidNum = resolved.pid;
        } else if (resolved is FlutterRunSession) {
          frun = resolved;
          pidNum = resolved.proc.pid;
        } else {
          pidNum = int.tryParse(target);
          if (pidNum == null) {
            return ToolFailureResult(VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'Alvo "$target" não é uma sessão gerenciada nem um PID '
                  'numérico. Use proc.list para ver os reais.',
            ));
          }
        }
        if (pidNum == 0 || pidNum == myPid) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.permissionDenied,
            message: 'PID $pidNum é protegido (processo próprio/zero) — kill '
                'recusado antes de tocar no SO.',
          ));
        }
        final isManaged = managed != null || frun != null;
        if (!isManaged && scope != 'own') {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.approvalRequired,
            message: 'PID $pidNum não é uma sessão iniciada por este app. Para '
                'matar processo externo, reenvie com scope="own" (e o nome '
                'precisa pertencer à família techVT/dart/flutter).',
          ));
        }
        if (!isManaged && scope == 'own') {
          final procs = await listSystemProcessesReal();
          final row = procs.where((p) => p['pid'] == pidNum).firstOrNull;
          if (row == null) {
            return ToolFailureResult(VtFailure(
              code: VtErrorCode.validationFailed,
              message: 'PID $pidNum não existe na tabela real de processos.',
            ));
          }
          final nm = row['name']?.toString() ?? '';
          if (!_isOwnName(nm)) {
            return ToolFailureResult(VtFailure(
              code: VtErrorCode.permissionDenied,
              message: 'PID $pidNum pertence a "$nm", fora da família techVT — '
                  'kill recusado.',
            ));
          }
        }
        if (managed != null) {
          if (!managed.alive) {
            return ok({'killed': false, 'reason': 'already_exited',
              'pid': managed.pid, 'exitCode': managed.describe()['exitCode']});
          }
          final res = sig == 9
              ? await managed.terminate(force: true)
              : await managed.terminate();
          return ok({
            'killed': res.killed,
            'escalatedToKill': res.escalatedToKill,
            'signal': sig,
            'pid': managed.pid,
            'sessionId': managed.id,
          });
        }
        if (frun != null) {
          if (!frun.alive) {
            return ok({'killed': false, 'reason': 'already_exited',
                'pid': frun.proc.pid, 'exitCode': frun.exitCode});
          }
          if (sig == 2) {
            final sent = await frun.proc.kill(ProcessSignal.sigint);
            return ok({'killed': sent, 'signal': 2, 'pid': frun.proc.pid,
                'sessionId': 'flutter-run:${frun.deviceId}'});
          }
          final term = await frun.proc.kill(ProcessSignal.sigterm);
          var escalated = false;
          if (term && sig == 15) {
            try {
              await frun.proc.exit.timeout(const Duration(seconds: 2));
            } on TimeoutException {
              await frun.proc.kill(ProcessSignal.sigkill);
              escalated = true;
            }
          } else if (sig == 9) {
            await frun.proc.kill(ProcessSignal.sigkill);
          }
          return ok({'killed': term, 'escalatedToKill': escalated,
              'signal': sig, 'pid': frun.proc.pid,
              'sessionId': 'flutter-run:${frun.deviceId}'});
        }
        // PID externo validado pela guarda own acima.
        final killed = await signalExternalPid(pidNum!, sig);
        if (!killed) {
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.permissionDenied,
            message: 'O SO recusou o sinal $sig ao PID $pidNum '
                '(permissão/ESRCH).',
          ));
        }
        return ok({'killed': true, 'signal': sig, 'pid': pidNum,
            'external': true});
      });
}

// ---------------------------------------------------------- term.read_output
class TermReadOutputTool extends _ProcTool {
  TermReadOutputTool(super.sessions);

  @override
  String get id => 'term.read_output';
  @override
  String get title => 'Lê output de sessão';
  @override
  String get description =>
      'Lê o buffer REAL acumulado de uma sessão viva/terminada deste app '
      '(flutter run ou proc.start via SessionStore), paginando a partir do '
      'fim (tail). Reporta totalBytes/droppedBytes/truncated — se conteúdo '
      'foi perdido pelo ring buffer, isso aparece no resultado.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'required': ['session'],
        'properties': {
          'session': {
            'type': 'string',
            'description':
                'Id da sessão ("proc-1", "flutter-run:<device>") ou PID.'
          },
          'max_bytes': {
            'type': 'integer',
            'description': 'Bytes a retornar a partir do offset (default '
                '8192, máx 262144).'
          },
          'offset_from_end': {
            'type': 'integer',
            'description': 'Paginação: 0 = tail; some max_bytes para páginas '
                'anteriores (default 0).'
          },
          'stderr': {
            'type': 'boolean',
            'description': 'Inclui stderr (default true, gerenciadas).'
          },
        },
      };

  @override
  Future<ToolResult<TextOutput>> execute(
      ToolContext ctx, MapToolInput input) =>
      _guard(this, () async {
        final ref = input.str('session');
        final maxBytes = (input.intOrNull('max_bytes') ?? 8192).clamp(1, 262144);
        final offset = (input.intOrNull('offset_from_end') ?? 0).clamp(0, 1 << 30);
        final stderrToo = input.boolOf('stderr', true);
        final s = sessions.resolveOutputSession(ref);
        if (s == null) {
          final realIds = [
            for (final m in sessions.managed) m.id,
            for (final f in sessions.flutterRuns) 'flutter-run:${f.deviceId}',
          ];
          return ToolFailureResult(VtFailure(
            code: VtErrorCode.validationFailed,
            message: 'Sessão "$ref" desconhecida. Reais agora: '
                '${realIds.isEmpty ? 'nenhuma' : realIds.join(', ')}',
            recoveryActions: const [
              RecoveryAction(kind: 'list_sessions', label: 'Rodar proc.list'),
            ],
          ));
        }
        if (s is ManagedProcess) {
          final r = s.readTail(
              maxBytes: maxBytes,
              offsetFromEnd: offset,
              stderrToo: stderrToo);
          return ok({
            'sessionId': s.id,
            'pid': s.pid,
            'text': r.text,
            'returnedBytes': utf8.encode(r.text).length,
            'totalBytes': r.totalBytes,
            'droppedByRingBuffer': r.droppedBytes,
            'truncated': r.truncated,
            'alive': s.alive,
          });
        }
        final f = s as FlutterRunSession;
        final text = f.tailText;
        final end =
            (f.alive ? text.length : text.length) - offset; // chars-based page
        final start = (end - maxBytes).clamp(0, text.length);
        final slice = start < end ? text.substring(start, end) : '';
        return ok({
          'sessionId': 'flutter-run:${f.deviceId}',
          'pid': f.proc.pid,
          'deviceId': f.deviceId,
          'text': slice,
          'totalChars': text.length,
          'droppedByRingBuffer': f.droppedBytes,
          'truncated': start > 0,
          'alive': f.alive,
          'exitCode': f.exitCode,
        });
      });
}
