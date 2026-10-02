/// Registro em memória de processos vivos iniciados pelo próprio app
/// (flutter run com [onSessionStarted], ferramentas proc.*, sessões futuras de
/// terminal). É estado operacional REAL — não persistência: ao fechar o app
/// os filhos morrem junto (SIGTERM no dispose), então um registro em memória
/// é a fonte de verdade honesta para proc.list / term.read_output / proc.kill.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../process/process_utils.dart';

const int kDefaultTermBufferSize = 262144; // 256 KB por stream

/// Uma sessão de processo monitorada.
class ManagedProcess {
  ManagedProcess._({
    required this.id,
    required this.pid,
    required this.command,
    required this.args,
    required this.cwd,
    required this.startedAt,
    required this.kind,
    required List<int> pidsInTree,
  }) : _pidsInTree = pidsInTree;

  final String id; // ex.: proc-3 ou flutter-run:emulator-5554
  final int pid;
  final String command;
  final List<String> args;
  final String cwd;
  final DateTime startedAt;
  final String kind; // 'managed' | 'observed'
  final List<int> _pidsInTree;

  Process? _proc;
  final _outBuf = <int>[];
  final _errBuf = <int>[];
  int _outDropped = 0;
  int _errDropped = 0;
  int _bufferLimit = kDefaultTermBufferSize;
  int? _exitCode;
  String? _endedBy; // 'signal' | 'timeout_kill' | 'exit'
  Completer<void>? _idle;

  bool get alive => _exitCode == null;

  /// O primeiro stdout após inatividade resolve esta future — usado pelo
  /// game.hot_reload para detectar "Restarted application" sem fingir nada.
  Completer<void> get firstOutputAfterIdle {
    if (_idle != null) return _idle!;
    return _idle ??= Completer<void>();
  }

  void attach(Process proc) {
    _proc = proc;
    _drain(proc.stdout, _outBuf, isErr: false);
    _drain(proc.stderr, _errBuf, isErr: true);
    unawaited(proc.exit.then((code) {
      _exitCode = code;
      _endedBy ??= 'exit';
    }));
  }

  void _drain(Stream<List<int>> stream, List<int> buf, {required bool isErr}) {
    unawaited(stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((text) {
      final bytes = utf8.encode(text);
      buf.addAll(bytes);
      if (buf.length > _bufferLimit) {
        final excess = buf.length - _bufferLimit;
        buf.removeRange(0, excess);
        if (isErr) {
          _errDropped += excess;
        } else {
          _outDropped += excess;
        }
      }
      if (!isErr && _idle?.isCompleted == false) _idle!.complete();
    }));
  }

  /// Lê a cauda do buffer real, com paginação. Retorna também flags de
  /// truncamento — nunca esconde que faltou conteúdo.
  ({String text, int totalBytes, int droppedBytes, bool truncated}) readTail({
    int maxBytes = 8192,
    int offsetFromEnd = 0,
    bool stderrToo = true,
  }) {
    final merged = stderrToo ? [..._outBuf, ..._errBuf] : [..._outBuf];
    final total = merged.length;
    final end = max(0, total - offsetFromEnd);
    final start = max(0, end - maxBytes);
    final slice = merged.sublist(start, end);
    return (
      text: utf8.decode(slice, allowMalformed: true),
      totalBytes: total,
      droppedBytes: _outDropped + _errDropped,
      truncated: start > 0 || offsetFromEnd > 0,
    );
  }

  Map<String, Object?> describe() => {
        'id': id,
        'pid': pid,
        'kind': kind,
        'command': [command, ...args].join(' '),
        'cwd': cwd,
        'startedAt': startedAt.toIso8601String(),
        'alive': alive,
        if (_exitCode != null) 'exitCode': _exitCode,
        if (_endedBy != null) 'endedBy': _endedBy,
        'stdoutBytes': _outBuf.length,
        'stderrBytes': _errBuf.length,
      };

  /// Envia texto ao stdin do processo (ex.: 'r' de restart no flutter run).
  bool writeStdin(String data) {
    final p = _proc;
    if (p == null || !alive) return false;
    try {
      p.stdin.write(data);
      p.stdin.flush();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> signal(int sig) async {
    final p = _proc;
    if (p == null) return false;
    switch (sig) {
      case 2:
        return await p.kill(ProcessSignal.sigint);
      case 15:
        return await p.kill(ProcessSignal.sigterm);
      case 9:
        return await p.kill(ProcessSignal.sigkill);
      default:
        return false;
    }
  }

  /// Termina a sessão. force=true usa SIGKILL direto; senão SIGTERM e, se o
  /// processo sobreviver ~2s, SIGKILL como último recurso (reportado).
  Future<({bool killed, bool escalatedToKill})> terminate(
      {bool force = false}) async {
    final p = _proc;
    if (p == null || !alive) return (killed: false, escalatedToKill: false);
    if (force) return (killed: await p.kill(ProcessSignal.sigkill), escalatedToKill: false);
    final term = await p.kill(ProcessSignal.sigterm);
    if (!term) return (killed: false, escalatedToKill: false);
    try {
      await p.exit.timeout(const Duration(seconds: 2));
      return (killed: true, escalatedToKill: false);
    } on TimeoutException {
      await p.kill(ProcessSignal.sigkill);
      _endedBy = 'signal';
      return (killed: true, escalatedToKill: true);
    }
  }
}

/// Sessão de flutter run viva, registrada quando o devtools entrega o
/// processo via onSessionStarted — permite hot reload/restart REAIS por stdin
/// e leitura do output acumulado (buffer ringueiro real).
class FlutterRunSession {
  FlutterRunSession(this.deviceId, this.proc, this.registeredAt) {
    unawaited(proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((text) {
      final b = utf8.encode(text);
      _outBuf.addAll(b);
      if (_outBuf.length > kDefaultTermBufferSize) {
        final excess = _outBuf.length - kDefaultTermBufferSize;
        _outBuf.removeRange(0, excess);
        _dropped += excess;
      }
      if (_pending?.isCompleted == false) _pending!.complete();
    }));
    unawaited(proc.exit.then((code) => _exitCode = code));
  }

  final String deviceId;
  final Process proc;
  final DateTime registeredAt;
  final _outBuf = <int>[];
  int _dropped = 0;
  int? _exitCode;
  Completer<void>? _pending;

  bool get alive => _exitCode == null;
  int? get exitCode => _exitCode;

  /// Future que resolve no PRÓXIMO chunk de stdout após [armNextOutput].
  /// Usado pelo game.hot_reload para verificar de fato a resposta do run.
  Future<void> armNextOutput() {
    _pending = Completer<void>();
    return _pending!.future;
  }

  String get tailText => utf8.decode(_outBuf, allowMalformed: true);
  int get droppedBytes => _dropped;

  /// Envia comando interativo ao flutter run ('r' reload, 'R' restart, 'q').
  bool sendCommand(String cmd) {
    if (!alive) return false;
    try {
      proc.stdin.write(cmd);
      proc.stdin.flush();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Lista de processos reais do SO (ps POSIX / tasklist Windows). Sem parsing
/// frágil: colunas separadas por espaço duplo onde possível.
Future<List<Map<String, Object?>>> listSystemProcessesReal() async {
  if (Platform.isWindows) {
    final r = await _run(['tasklist', '/fo', 'csv', '/nh']);
    if (r == null) return const [];
    final out = <Map<String, Object?>>[];
    for (final line in const Utf8Decoder(allowMalformed: true)
        .decode(r)
        .split('\n')) {
      final cols =
          line.split('","').map((c) => c.replaceAll('"', '').trim()).toList();
      if (cols.length < 2) continue;
      out.add({
        'name': cols[0],
        'pid': int.tryParse(cols[1]),
        'raw': line.trim(),
      });
    }
    return out;
  }
  final r = await _run(['/bin/ps', '-eo', 'pid=,ppid=,stat=,comm=,args=']);
  if (r == null) return const [];
  final out = <Map<String, Object?>>[];
  for (final line in const Utf8Decoder(allowMalformed: true)
      .decode(r)
      .split('\n')) {
    final t = line.trimLeft();
    if (t.isEmpty) continue;
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length < 4) continue;
    out.add({
      'pid': int.tryParse(parts[0]),
      'ppid': int.tryParse(parts[1]),
      'stat': parts[2],
      'name': parts[3],
      'args': parts.length > 4 ? parts.sublist(4).join(' ') : parts[3],
    });
  }
  return out;
}

Future<List<int>?> descendantsOf(int rootPid) async {
  if (Platform.isWindows) return null;
  final procs = await listSystemProcessesReal();
  final byParent = <int, List<int>>{};
  for (final p in procs) {
    final pid = p['pid'];
    final ppid = p['ppid'];
    if (pid is int && ppid is int) (byParent[ppid] ??= []).add(pid);
  }
  final out = <int>{rootPid};
  final queue = [rootPid];
  while (queue.isNotEmpty) {
    final cur = queue.removeAt(0);
    for (final child in byParent[cur] ?? const <int>[]) {
      if (out.add(child)) queue.add(child);
    }
  }
  return out.toList();
}

Future<List<int>?> _run(List<String> argv) async {
  try {
    final pr = await Process.run(argv.first, argv.sublist(1));
    if (pr.exitCode != 0) return null;
    return (pr.stdout as List<int>);
  } catch (_) {
    return null;
  }
}

/// Fonte canônica dos nomes de processos que o app reconhece como seus —
/// usada por proc.list (filtro own) e proc.kill (guarda de segurança).
const Set<String> kTechvtOwnProcNames = {
  'techvt', 'dart', 'flutter', 'frontend_server.dart.snapshot',
  'flutter_tester', 'dartdev', 'gradle', 'java',
};

class SessionStore {
  final Map<String, ManagedProcess> _byId = {};
  final Map<String, FlutterRunSession> _flutterRuns = {};
  int _seq = 0;

  String register({
    required Process proc,
    required String command,
    required List<String> args,
    required String cwd,
    int? bufferLimitBytes,
    String? fixedId,
  }) {
    final id = fixedId ?? 'proc-${++_seq}';
    final m = ManagedProcess._(
      id: id,
      pid: proc.pid,
      command: command,
      args: args,
      cwd: cwd,
      startedAt: DateTime.now(),
      kind: 'managed',
      pidsInTree: const [],
    );
    m._bufferLimit = bufferLimitBytes ?? kDefaultTermBufferSize;
    m.attach(proc);
    _byId[id] = m;
    return id;
  }

  /// Registra uma sessão de flutter run entregue pelo devtools.
  String registerFlutterRun(String deviceId, Process proc) {
    final s = FlutterRunSession(deviceId, proc, DateTime.now());
    s.bindStdout();
    _flutterRuns['flutter-run:$deviceId'] = s;
    return 'flutter-run:$deviceId';
  }

  FlutterRunSession? flutterRun(String deviceId) =>
      _flutterRuns['flutter-run:$deviceId'];

  Iterable<FlutterRunSession> get flutterRuns => _flutterRuns.values;

  ManagedProcess? byId(String id) => _byId[id];
  Iterable<ManagedProcess> get managed => _byId.values;

  /// Resolve uma sessão de output: aceita id gerenciado ('proc-1'), id de
  /// flutter run ('flutter-run:<device>') ou PID numérico vivo.
  Object? resolveOutputSession(String ref) {
    final direct = _byId[ref];
    if (direct != null) return direct;
    final fr = _flutterRuns[ref];
    if (fr != null) return fr;
    if (ref.startsWith('flutter-run:')) {
      final dev = ref.substring('flutter-run:'.length);
      return _flutterRuns['flutter-run:$dev'];
    }
    final pid = int.tryParse(ref);
    if (pid != null) return byPid(pid);
    return null;
  }

  ManagedProcess? byPid(int pid) {
    for (final m in _byId.values) {
      if (m.pid == pid) return m;
    }
    return null;
  }

  Future<void> dispose() async {
    for (final m in _byId.values) {
      if (m.alive) await m.terminate(force: true);
    }
    _byId.clear();
    _flutterRuns.clear();
  }
}

/// Observa um PID externo (não gerenciado): kill via dart:io só aceita
/// SIGTERM/SIGKILL — sinal 9/15 aplicado diretamente; 2 exige processo
/// gerenciado (stdin/pipe), senão erro honesto.
Future<bool> signalExternalPid(int pid, int sig) async {
  final s = switch (sig) {
    15 => ProcessSignal.sigterm,
    9 => ProcessSignal.sigkill,
    _ => null,
  };
  if (s == null) return false;
  try {
    return Process.killPid(pid, s);
  } catch (_) {
    return false;
  }
}

String basename(String p) => basenameOf(p);
