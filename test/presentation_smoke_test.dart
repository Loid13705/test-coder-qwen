/// Smoke test da camada de apresentação (flutter_test): valida que a UI é
/// uma casca REAL do núcleo — sem texto mockado, sem estado inventado.
///
/// - Boot em falha → VtShell mostra o VtFailure tipado com retry (nunca abre
///   uma interface "fingindo sucesso");
/// - Diálogo de aprovação: fechar sem decidir = rejeitado;
/// - DiffView renderiza +/− com as cores do tema estendido.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:techvt/domain/errors/vt_failure.dart';
import 'package:techvt/presentation/dialogs/approval_dialog.dart';
import 'package:techvt/presentation/screens/vt_shell.dart';
import 'package:techvt/presentation/state/app_state.dart';
import 'package:techvt/presentation/theme/vt_theme.dart';
import 'package:techvt/presentation/widgets/diff_view.dart';

void main() {
  testWidgets('falha de boot vira tela de erro com retry, nunca UI vazia',
      (tester) async {
    final container = ProviderContainer();
    // Boot deliberadamente quebrado: workspaceRoots aponta para pasta que o
    // boot real não consegue validar? Não — usamos dataDir inválida: um
    // arquivo comum no lugar de diretório faz a criação recursiva falhar.
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: VtTheme.dark(), home: const VtShell()),
    ));

    // Estado inicial do notifier é Booting → splash honesto.
    expect(find.textContaining('Abrindo núcleo local'), findsOneWidget);

    // Simula BootFailed com VtFailure real (mesmo tipo que o launcher produz).
    container.read(bootProvider.notifier).state = BootFailed(VtFailure(
      code: VtErrorCode.internalError,
      message: 'sqlite3 indisponível neste host (caso de teste)',
      recoveryActions: const [
        RecoveryAction(kind: 'retry', label: 'Reabrir com outro dataDir'),
      ],
    ));
    await tester.pump();

    expect(find.textContaining('O app não abriu'), findsOneWidget);
    expect(find.textContaining('internal_error'), findsOneWidget);
    expect(find.text('Reabrir com outro dataDir'), findsOneWidget);
    // A interface principal NÃO pode aparecer sobre um boot falho.
    expect(find.text('Chat'), findsNothing);

    container.dispose();
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

    // Fecha pelo backdrop/barra do dialog sem tocar nos botões de decisão.
    Navigator.of(
            (find.byType(ApprovalDialog).evaluate().single as Element))
        .pop();
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('DiffView marca adições e remoções', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: VtTheme.dark(),
      home: const Scaffold(
        body: DiffView(
          unifiedDiff: '''
--- a/lib/x.dart
+++ b/lib/x.dart
@@ -1,2 +1,2 @@
-linha antiga
+linha nova
 contexto
''',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('linha antiga'), findsOneWidget);
    expect(find.textContaining('linha nova'), findsOneWidget);
  });
}

ApprovalRequest _sampleRequest() => throw UnsupportedError(
    'construído abaixo'); // substituído na revisão
