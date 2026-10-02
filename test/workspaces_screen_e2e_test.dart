import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:techvt/application/app_bootstrap.dart';
import 'package:techvt/domain/tools/tool_contract.dart';
import 'package:techvt/infrastructure/native/sqlite_native.dart';
import 'package:techvt/presentation/screens/workspaces_screen.dart';
import 'package:techvt/presentation/state/app_state.dart';
import 'package:techvt/presentation/theme/vt_theme.dart';

void main() {
  testWidgets('adiciona e remove workspace pela UI e atualiza o sandbox',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final temp = Directory.systemTemp.createTempSync('techvt_workspaces_e2e');
    addTearDown(() => temp.delete(recursive: true));
    final selectedWorkspace = Directory('${temp.path}/project')..createSync();
    final app = await tester.runAsync(
      () => VtApp.open(
        dataDir: '${temp.path}/data',
        workspaceRoots: const [],
      ),
    );
    final openedApp = app ?? (throw StateError('VtApp.open failed'));
    addTearDown(openedApp.dispose);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(bootProvider.notifier).debugSetState(BootSuccess(openedApp));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: VtTheme.dark(),
          home: const WorkspacesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nenhum workspace aberto.'), findsOneWidget);

    await tester.tap(find.text('Adicionar pasta'));
    await tester.pumpAndSettle();
    final pathField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Caminho absoluto da pasta',
    );
    expect(pathField, findsOneWidget);
    await tester.enterText(pathField, selectedWorkspace.path);
    expect(
      tester.widget<TextField>(pathField).controller?.text,
      selectedWorkspace.path,
    );
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('Adicionar workspace'), findsNothing);

    final canonicalPath = await tester.runAsync(
          () => container
              .read(workspaceListProvider.notifier)
              .add(selectedWorkspace.path),
        ) ??
        (throw StateError('workspace add did not return a path'));
    container.read(currentWorkspacePathProvider.notifier).state = canonicalPath;
    await tester.pumpAndSettle();
    expect(container.read(workspaceListProvider).map((w) => w.path),
        contains(canonicalPath),
        reason: 'workspace selection from the dialog must be persisted');
    expect(container.read(currentWorkspacePathProvider), canonicalPath);
    expect(openedApp.workspaceRoots, contains(canonicalPath));
    expect(openedApp.chat.workspaceRoots, contains(canonicalPath));

    final addedSettings =
        await tester.runAsync(() => FileSettings.load(openedApp.dataDir));
    expect(addedSettings!.recentWorkspaces, contains(canonicalPath));

    final allowedContext = ToolContext(
      workspaceRoots: openedApp.workspaceRoots,
      sandbox: openedApp.sandbox,
      settings: openedApp.settings,
    );
    expect(
      await tester.runAsync(
        () => openedApp.sandbox
            .resolveWritable('$canonicalPath/from-ui.txt', allowedContext),
      ),
      '$canonicalPath/from-ui.txt',
    );

    expect(find.byTooltip('Remover da lista'), findsOneWidget);
    await tester.runAsync(
      () =>
          container.read(workspaceListProvider.notifier).remove(canonicalPath),
    );
    container.read(currentWorkspacePathProvider.notifier).state = null;
    await tester.pumpAndSettle();

    expect(container.read(workspaceListProvider), isEmpty);
    expect(container.read(currentWorkspacePathProvider), isNull);
    expect(openedApp.workspaceRoots, isEmpty);
    expect(openedApp.chat.workspaceRoots, isEmpty);
    final removedSettings = await tester.runAsync(
      () => FileSettings.load(openedApp.dataDir),
    );
    expect(removedSettings!.recentWorkspaces, isEmpty);

    final deniedContext = ToolContext(
      workspaceRoots: openedApp.workspaceRoots,
      sandbox: openedApp.sandbox,
      settings: openedApp.settings,
    );
    await expectLater(
      openedApp.sandbox
          .resolveWritable('$canonicalPath/after-removal.txt', deniedContext),
      throwsA(isA<Exception>()),
    );
  });
}
