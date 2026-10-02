/// Runtime local próprio via llama.cpp (§SETTINGS: "opção de runtime próprio").
///
/// Tudo aqui é detecção/execução REAL:
/// - Localiza o binário `llama-server` no PATH ou em caminho configurado
///   (`runtime.llamaBinaryPath`); ausente → falha tipada com ação de
///   instalação, nunca finge que existe.
/// - Escaneia diretórios reais atrás de modelos GGUF e de modelos instalados
///   do Ollama (~/.ollama/models), citando tamanho/modified de cada arquivo.
/// - Sobe um `llama-server` local (loopback) como processo real, aguarda o
///   health endpoint (/health) responder 200 e então expõe o runtime como
///   provider OpenAI-compatível — a geração acontece DE FATO no subprocesso.
/// - Com a internet desligada continua funcionando: só usa loopback.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/errors/vt_failure.dart';
import '../../domain/net_access.dart';
import '../provider/openai_compatible_provider.dart';
import '../provider/provider_contract.dart';

/// Um modelo GGUF encontrado em disco (dados vindos de File.statSync real).
class GgufModel {
  const GgufModel({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String path;
  final String fileName;
  final int sizeBytes;
  final DateTime modifiedAt;

  /// Id estável usado pelo runtime (nome do arquivo sem extensão).
  String get modelId => fileName.replaceAll(RegExp(r'\.gguf$'), '');

  String get sizeHuman {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = sizeBytes.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return '${v.toStringAsFixed(v >= 100 || u == 0 ? 0 : 1)} ${units[u]}';
  }

  Map<String, Object?> toJson() => {
        'path': path,
        'file': fileName,
        'sizeBytes': sizeBytes,
        'modifiedAt': modifiedAt.toIso8601String(),
      };
}

/// Modelo instalado num Ollama local (lido de ~/.ollama/models/manifests,
/// estrutura real do Ollama ≥0.1).
class OllamaModel {
  const OllamaModel({required this.name, required this.sizeBytes});
  final String name; // ex.: qwen2.5-coder:7b
  final int sizeBytes;

  String get sizeHuman => sizeBytes <= 0
      ? '(tamanho indisponível)'
      : '${(sizeBytes / 1e9).toStringAsFixed(1)} GB';

  Map<String, Object?> toJson() => {'name': name, 'sizeBytes': sizeBytes};
}

/// Resultado da varredura de runtime.
class LocalRuntimeInventory {
  const LocalRuntimeInventory({
    required this.llamaServerPath,
    required this.llamaVersion,
    required this.ggufModels,
    required this.ollamaModels,
    required this.scannedDirs,
    required this.skippedDirs,
  });

  /// null quando o binário não foi encontrado (razão técnica reportada na UI).
  final String? llamaServerPath;
  final String? llamaVersion; // stdout REAL de `llama-server --version`
  final List<GgufModel> ggufModels;
  final List<OllamaModel> ollamaModels;
  final List<String> scannedDirs;
  final List<String> skippedDirs; // dirs que não existiam no momento do scan

  bool get engineAvailable => llamaServerPath != null;
  bool get hasAnyModel => ggufModels.isNotEmpty || ollamaModels.isNotEmpty;

  Map<String, Object?> toJson() => {
        'engine': llamaServerPath,
        'engineVersion': llamaVersion,
        'ggufModels': [for (final m in ggufModels) m.toJson()],
        'ollamaModels': [for (final m in ollamaModels) m.toJson()],
        'scannedDirs': scannedDirs,
        'skippedDirs': skippedDirs,
      };
}

/// Serviço de detecção + ciclo de vida do runtime llama.cpp.
class LocalLlamaRuntime {
  LocalLlamaRuntime({
    required this.settingsReader,
  });

  /// Leitura das chaves `runtime.*` de settings.json (injetada pelo bootstrap;
  /// retorna null quando ausente).
  final Object? Function(String key) settingsReader;

  Process? _serverProcess;
  int? _serverPort;
  OpenAiCompatibleProvider? _provider;

  static const defaultScanDirs = <String>[
    '~/.ollama/models',
    '~/models',
    '~/Downloads',
  ];

  String _expandHome(String p) {
    if (!p.startsWith('~')) return p;
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) return p;
    return '$home${p.substring(1)}';
  }

  /// Caminho real do binário ou null. Override inválido → falha tipada
  /// imediata (não cai silenciosamente para o PATH).
  String? _binaryPath() {
    final custom = settingsReader('runtime.llamaBinaryPath');
    if (custom is String && custom.trim().isNotEmpty) {
      final f = File(_expandHome(custom.trim()));
      if (f.existsSync()) return f.absolute.path;
      throw VtFailure(
        code: VtErrorCode.binaryMissing,
        message: 'runtime.llamaBinaryPath aponta para arquivo inexistente: '
            '${custom.trim()}',
        recoveryActions: const [
          RecoveryAction(
              kind: 'open_settings', label: 'Corrigir caminho em Settings'),
        ],
        setupUri: 'techvt://settings/runtime',
      );
    }
    for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
      if (dir.isEmpty) continue;
      final f = File('${dir.replaceAll(RegExp(r'/+$'), '')}/llama-server');
      if (f.existsSync()) return f.absolute.path;
    }
    return null;
  }

  /// Varredura REAL: binário + versão + GGUFs + manifests do Ollama.
  Future<LocalRuntimeInventory> scan() async {
    final exe = _binaryPath();
    String? version;
    if (exe != null) {
      try {
        final r = await Process.run(exe, ['--version'])
            .timeout(const Duration(seconds: 5));
        if (r.exitCode == 0) {
          version = (r.stdout as String).trim().split('\n').first;
        }
      } on Exception {
        version = null; // binário corrompido/incompatível: reportado como tal
      }
    }

    final extraDirs = settingsReader('runtime.modelDirs');
    final dirs = <String>{
      ...defaultScanDirs,
      if (extraDirs is List) ...extraDirs.map((e) => e.toString()),
    }.map(_expandHome).toList();

    final ggufs = <GgufModel>[];
    final scanned = <String>[];
    final skipped = <String>[];
    for (final d in dirs) {
      final dir = Directory(d);
      if (!dir.existsSync()) {
        skipped.add(d);
        continue;
      }
      scanned.add(dir.absolute.path);
      try {
        for (final e in dir.listSync(recursive: true, followLinks: false)) {
          if (e is File && e.path.toLowerCase().endsWith('.gguf')) {
            final st = e.statSync();
            ggufs.add(GgufModel(
              path: e.absolute.path,
              fileName: e.uri.pathSegments.last,
              sizeBytes: st.size,
              modifiedAt: st.modified,
            ));
          }
        }
      } on FileSystemException {
        // permissão negada em subpasta: mantém o que foi lido, sem fingir.
      }
    }
    ggufs.sort((a, b) => a.path.compareTo(b.path));

    final ollama = <OllamaModel>[];
    final manifests = Directory(_expandHome('~/.ollama/models/manifests'));
    if (manifests.existsSync()) {
      try {
        for (final f
            in manifests.listSync(recursive: true).whereType<File>()) {
          // estrutura real: manifests/<registry>/<user>/<name>/<tag>
          final parts = f.absolute.path.split(Platform.pathSeparator);
          if (parts.length < 2) continue;
          final tag = parts.last;
          final name = parts[parts.length - 2];
          var size = 0;
          try {
            // soma os blobs referenciados no manifest (tamanho real em disco)
            final content = f.readAsStringSync();
            for (final m in RegExp(
                    r'"digest"\s*:\s*"sha256:([0-9a-f]+)"')
                .allMatches(content)) {
              final blob = File('${_expandHome("~/.ollama/models/blobs")}'
                  '/sha256-${m.group(1)}');
              if (blob.existsSync()) size += blob.statSync().size;
            }
          } on FileSystemException {
            size = 0;
          }
          ollama.add(OllamaModel(name: '$name:$tag', sizeBytes: size));
        }
      } on FileSystemException {
        // sem acesso: lista vazia REAL
      }
      ollama.sort((a, b) => a.name.compareTo(b.name));
    }

    return LocalRuntimeInventory(
      llamaServerPath: exe,
      llamaVersion: version,
      ggufModels: ggufs,
      ollamaModels: ollama,
      scannedDirs: scanned,
      skippedDirs: skipped,
    );
  }

  /// Sobe o llama-server REAL numa porta de loopback e espera o health
  /// endpoint (/health) responder 200 antes de retornar. Falha tipada se o
  /// processo morre antes disso (stderr real incluído na mensagem).
  Future<OpenAiCompatibleProvider> startServer({
    required String ggufPath,
    int port = 0,
    int contextTokens = 4096,
    Map<String, String> env = const {},
  }) async {
    stopServer();
    final exe = _binaryPath();
    if (exe == null) {
      throw VtFailure(
        code: VtErrorCode.binaryMissing,
        message: 'llama-server não encontrado no PATH nem em '
            'runtime.llamaBinaryPath.',
        recoveryActions: const [
          RecoveryAction(
              kind: 'install_binary',
              label: 'Instalar llama.cpp (llama-server) ou apontar o caminho',
              target: 'techvt://settings/runtime'),
        ],
        setupUri: 'techvt://settings/runtime',
      );
    }
    final model = File(ggufPath);
    if (!model.existsSync()) {
      throw VtFailure(
        code: VtErrorCode.validationFailed,
        message: 'Modelo GGUF inexistente: $ggufPath',
        recoveryActions: const [
          RecoveryAction(kind: 'rescan', label: 'Reescanear diretórios'),
        ],
      );
    }
    final actualPort = port != 0 ? port : await _findFreePort();
    final argv = [
      '--model', model.absolute.path,
      '--host', '127.0.0.1',
      '--port', '$actualPort',
      '--ctx-size', '$contextTokens',
    ];
    final proc = await Process.start(exe, argv,
        environment: {...Platform.environment, ...env},
        mode: ProcessStartMode.detachedWithStdio);
    _serverProcess = proc;
    _serverPort = actualPort;

    final stderrBuf = StringBuffer();
    proc.stderr.transform(utf8.decoder).listen(stderrBuf.write);

    // Health check polling REAL contra /health do servidor filho.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    var healthy = false;
    try {
      while (DateTime.now().isBefore(deadline) && !healthy) {
        if (await _procExited(proc)) {
          final err = stderrBuf.toString().trim();
          stopServer();
          throw VtFailure(
            code: VtErrorCode.sidecarNotRunning,
            message: 'llama-server terminou antes de ficar saudável'
                '${err.isEmpty ? '' : ': $err'}',
          );
        }
        try {
          final req = await client.getUrl(
              Uri.parse('http://127.0.0.1:$actualPort/health'));
          final resp = await req.close().timeout(const Duration(seconds: 2));
          if (resp.statusCode == 200) healthy = true;
          await resp.drain<void>();
        } on SocketException {
          // ainda subindo — tenta de novo até o deadline
        } on TimeoutException {
          // idem
        }
        if (!healthy) await Future.delayed(const Duration(milliseconds: 400));
      }
    } finally {
      client.close(force: true);
    }
    if (!healthy) {
      final err = stderrBuf.toString().trim();
      stopServer();
      throw VtFailure(
        code: VtErrorCode.timeout,
        message: 'llama-server não respondeu em /health em 30s'
            '${err.isEmpty ? '' : ' (stderr: $err)'}',
      );
    }

    final provider = OpenAiCompatibleProvider(ProviderConfig(
      id: 'llama-local',
      displayName: 'llama.cpp (runtime local)',
      baseUrl: 'http://127.0.0.1:$actualPort/v1',
      modelIds: [model.uri.pathSegments.last.replaceAll('.gguf', '')],
      timeout: const Duration(minutes: 5),
      proxy: ProviderProxyConfig.directOnly, // loopback nunca passa por proxy
    ));
    _provider = provider;
    return provider;
  }

  Future<int> _findFreePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  void stopServer() {
    _serverProcess?.kill(ProcessSignal.sigterm);
    _serverProcess = null;
    _serverPort = null;
    _provider = null;
  }

  bool get serverRunning => _serverProcess != null;
  int? get serverPort => _serverPort;

  /// Provider vivo somente quando o servidor está de pé (nunca um provider
  /// apontando para porta morta).
  LlmProvider? get liveProvider => serverRunning ? _provider : null;

  /// Catálogo de modelos detectados para a UI de settings (fonte citada em
  /// cada item: caminho do arquivo GGUF ou nome do manifest do Ollama).
  Future<List<ModelInfo>> discoverCatalog() async {
    final inv = await scan();
    return [
      for (final m in inv.ggufModels)
        ModelInfo(
          id: m.modelId,
          providerId: 'llama-local',
          displayName: '${m.fileName} (${m.sizeHuman})',
          contextWindow: 4096,
          capabilities: const ModelCapabilities(streaming: true),
          source: ModelSource.local,
        ),
      for (final m in inv.ollamaModels)
        ModelInfo(
          id: m.name,
          providerId: 'ollama',
          displayName: '${m.name} (${m.sizeHuman})',
          contextWindow: 8192,
          capabilities: const ModelCapabilities(streaming: true),
          source: ModelSource.local,
        ),
    ];
  }
}

/// true se o processo já terminou (probe de 150ms no exit — não bloqueia).
Future<bool> _procExited(Process proc) async {
  try {
    await proc.exit.timeout(const Duration(milliseconds: 150));
    return true;
  } on TimeoutException {
    return false;
  }
}

/// Valida a URL do runtime antes de salvar em settings: precisa ser http(s);
/// com a internet desligada só aceita loopback (senão o runtime jamais
/// conseguiria gerar e a falha apareceria tarde demais).
void validateRuntimeUrl(Object? value) {
  if (value == null) return;
  final raw = value.toString().trim();
  if (raw.isEmpty) return;
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      !uri.hasScheme ||
      !(uri.isScheme('http') || uri.isScheme('https'))) {
    throw VtFailure(
      code: VtErrorCode.validationFailed,
      message:
          'URL do runtime deve começar com http:// ou https:// (recebido: "$raw").',
    );
  }
  if (!VtNetAccess.enabled && !VtNetAccess.isLoopbackHost(uri.host)) {
    throw VtFailure(
      code: VtErrorCode.networkUnavailable,
      message: 'Internet desligada: o runtime externo "$raw" ficaria '
          'inacessível. Use um endpoint de loopback ou ligue a internet.',
      recoveryActions: const [
        RecoveryAction(kind: 'open_settings', label: 'Abrir Settings → Rede'),
      ],
    );
  }
}
