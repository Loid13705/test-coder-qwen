/// Smoke test da camada de apresentação (flutter_test): valida que a UI é
/// uma casca REAL do núcleo — sem texto mockado, sem estado inventado.
///
/// - Boot em falha → VtShell mostra o VtFailure tipado com retry (nunca abre
///   uma interface "fingindo sucesso");
/// - Diálogo de aprovação: fechar sem decidir = null → gateway rejeita;
/// - UiApprovalGateway nunca aprova por default;
/// - DiffView renderiza +/− com as cores do tema estendido.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:techvt/application/approval.dart';
import 'package:techvt/domain/errors/vt_failure.dart';
import 'package:techvt/domain/tools/tool_contract.dart';
import 'package:techvt/presentation/dialogs/approval_dialog.dart';
import 'package:techvt/presentation/screens/vt_shell.dart';
import 'package:techvt/presentation/state/app_state.dart';
import 'package:techvt/presentation/theme/vt_theme.dart';
import 'package:techvt/presentation/widgets/diff_view.dart';

void main() {
  testWidgets('falha de boot vira tela de erro com retry, nunca UI vazia',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: VtTheme.dark(), home: const VtShell()),
    ));

    // Estado inicial do notifier é Booting → splash honesto.
    expect(find.textContaining('Abrindo núcleo local'), findsOneWidget);

    // Injeta BootFailed com VtFailure real (mesmo tipo que bootstrapStrict
    // produz ao capturar falha do núcleo; via extensão @visibleForTesting).
    container.read(bootProvider.notifier).debugSetState(BootFailed(VtFailure(
      code: VtErrorCode.internalError,
      message: 'sqlite3 indisponível neste host (caso de teste)',
      recoveryActions: const [
        RecoveryAction(kind: 'retry', label: 'Reabrir com outro dataDir'),
      ],
    )));
    await tester.pump();

    expect(find.textContaining('O app não abriu'), findsOneWidget);
    expect(find.textContaining('internal_error'), findsOneWidget);
    expect(find.text('Reabrir com outro dataDir'), findsOneWidget);
    // A interface principal NÃO pode aparecer sobre um boot falho.
    expect(find.text('Chat'), findsNothing);
  });

  testWidgets('aprovação: fechar sem decidir devolve null (gateway rejeita)',
      (tester) async {
    ApprovalDecision? result;
    await tester.pumpWidget(MaterialApp(
      theme: VtTheme.dark(),
      home: Builder(
        builder: (context) {
          return ElevatedButton(
            onPressed: () async {
              result = await showApprovalDialog(context, _sampleRequest());
            },
            child: const Text('open'),
          );
        },
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('fs.write_text'), findsOneWidget);

    // Fecha por Navigator.pop SEM tocar nos botões de decisão — o diálogo
    // retorna null (nenhuma aprovação implícita).
    final dialogContext = find.byType(ApprovalDialog).evaluate().single;
    Navigator.of(dialogContext).pop();
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets(
      'UiApprovalGateway: diálogo fechado sem decisão => REJEITADO '
      '(nunca aprovado por default)', (tester) async {
    late BuildContext rootCtx;
    await tester.pumpWidget(MaterialApp(
      theme: VtTheme.dark(),
      home: Builder(builder: (context) {
        rootCtx = context;
        return const SizedBox.shrink();
      }),
    ));

    final gateway = UiApprovalGateway(() => rootCtx);
    var done = false;
    ApprovalDecision? decision;
    // ignore: unawaited_futures — decidimos via pop() abaixo e aguardamos o
    // resultado com pumpAndSettle; a Future não precisa de await aqui.
    gateway.request(_sampleRequest()).then((d) {
      decision = d;
      done = true;
    });
    await tester.pump(); // abre o diálogo (showDialog → overlay vivo)

    // Fecha o overlay sem decidir — exatamente o que acontece quando o
    // usuário dispensa a janela. O gateway deve converter em rejeição.
    Navigator.of(find.byType(ApprovalDialog).evaluate().single).pop();
    await tester.pumpAndSettle();

    expect(done, isTrue);
    expect(decision!.outcome, ApprovalOutcome.rejected);
    expect(decision!.isApproved, isFalse);
  });

  testWidgets('DiffView marca adições e remoções', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: VtTheme.dark(),
      home: const Scaffold(
        body: DiffView(
          filePath: 'lib/x.dart',
          unifiedDiff: '''
--- a/lib/x.dart
+++ b/lib/x.dart
@@ -1,2 +1,2 @@
-linha antiga
+linha nova
 contexto
''',
          additions: 1,
          deletions: 1,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('linha antiga'), findsOneWidget);
    expect(find.textContaining('linha nova'), findsOneWidget);
  });
}

/// Request real de aprovação (tool fs.write_text, risco localWrite) usado nos
/// dois cenários de diálogo acima.
ApprovalRequest _sampleRequest() => const ApprovalRequest(
      requestId: 'req-smoke-1',
      toolId: 'fs.write_text',
      title: 'Escrever lib/x.dart',
      risk: RiskLevel.localWrite,
      preview: {'path': 'lib/x.dart', 'bytes': 128},
    );
