/// Gate global de acesso a rede (§SETTINGS: "opção de ligar e desligar a
/// internet").
///
/// Um único ponto mutável que toda saída HTTP da aplicação consulta ANTES de
/// abrir qualquer conexão: providers LLM remotos, tools web/browser e o motor
/// llama.cpp quando em modo online. O toggle persistido é `internetEnabled`
/// em settings.json; este holder é atualizado no boot e a cada escrita de
/// settings (nunca diverge do disco).
///
/// Regra da casa: bloqueio é honesto — retorna VtFailure tipado
/// (`network_unavailable`) com ação de configuração concreta, nunca um
/// resultado simulado.
library;

import 'errors/vt_failure.dart';

class VtNetAccess {
  VtNetAccess._();

  /// true = rede liberada (default conservador: ligado até o settings dizer
  /// o contrário; o bootstrap chama [apply] com o valor real do disco).
  static bool enabled = true;

  static void apply(Object? settingsValue) {
    // Só desliga quando explicitamente `false`; ausente/lixo = ligado
    // (mesma semântica dos demais toggles de settings.json).
    enabled = settingsValue is! bool || settingsValue;
  }

  /// Lança falha tipada se a internet estiver desligada. Chamado por todo
  /// código que abre conexão para hosts NÃO-loops.
  static void ensureAllowed({required String what}) {
    if (enabled) return;
    throw VtFailure(
      code: VtErrorCode.networkUnavailable,
      message:
          'Internet desligada nas configurações — "$what" não foi executado.',
      recoveryActions: const [
        RecoveryAction(
            kind: 'open_settings',
            label: 'Ligar a internet em Settings → Rede'),
      ],
      setupUri: 'techvt://settings/network',
    );
  }

  /// Hosts que continuam acessíveis mesmo com a internet desligada: loopback
  /// (ollama, LM Studio, llama.cpp server local, sidecars locais).
  static bool isLoopbackHost(String host) {
    final h = host.toLowerCase().trim();
    if (h == 'localhost' || h == '::1' || h == '0.0.0.0') return true;
    if (h.startsWith('127.')) return true; // 127.0.0.0/8 inteiro
    return false;
  }

  /// Conveniência para Uri: permite loopback sempre; exige [enabled] para o
  /// resto.
  static bool allowsUri(Uri uri) =>
      enabled || isLoopbackHost(uri.host);
}
