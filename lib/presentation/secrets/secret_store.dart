/// Armazenamento local de segredos (API keys) fora do settings.json.
///
/// Estratégia honesta desktop-first: as chaves vivem em `<dataDir>/secrets/`
/// com permissão restrita (0600 em Unix) e NUNCA são escritas em
/// settings.json nem expostas na UI além do estado "definida / ausente".
/// No build Flutter final, este gateway pode ser trocado por
/// `flutter_secure_storage` (keychain do SO) mantendo a mesma interface —
/// sem isso, nada aqui finge ser keychain: é arquivo local documentado.
library;

import 'dart:convert';
import 'dart:io';

abstract class SecretStore {
  Future<String?> read(String providerId);
  Future<void> write(String providerId, String value);
  Future<void> delete(String providerId);
  Future<List<String>> ids();
}

class FileSecretStore implements SecretStore {
  FileSecretStore._(this._dir);

  static const _fileName = 'secrets.json';
  final Directory _dir;

  static Future<FileSecretStore> open(String dataDir) async {
    final dir = Directory('$dataDir/secrets');
    await dir.create(recursive: true);
    return FileSecretStore._(dir);
  }

  File get _file => File('${_dir.path}/$_fileName');

  Future<Map<String, Object?>> _load() async {
    final f = _file;
    if (!await f.exists()) return {};
    try {
      final d = jsonDecode(await f.readAsString());
      if (d is Map) return d.cast<String, Object?>();
    } on FormatException {
      // Arquivo corrompido: tratado como vazio REAL (nunca inventa chave).
    }
    return {};
  }

  Future<void> _save(Map<String, Object?> values) async {
    final f = _file;
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(values));
    if (!Platform.isWindows) {
      // Restringe permissão do arquivo que contém segredos.
      await Process.run('chmod', ['600', f.path]);
    }
  }

  @override
  Future<String?> read(String providerId) async {
    final v = (await _load())[providerId];
    return v is String && v.isNotEmpty ? v : null;
  }

  @override
  Future<void> write(String providerId, String value) async {
    final values = await _load();
    values[providerId] = value;
    await _save(values);
  }

  @override
  Future<void> delete(String providerId) async {
    final values = await _load();
    values.remove(providerId);
    await _save(values);
  }

  @override
  Future<List<String>> ids() async => (await _load()).keys.toList();
}
