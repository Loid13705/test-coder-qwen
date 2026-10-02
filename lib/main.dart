/// Ponto de entrada do techVT desktop (Flutter).
///
/// Fluxo honesto de boot:
/// 1. ProviderScope + MaterialApp com os 3 temas reais (dark/light/HC);
/// 2. VtShell mostra splash enquanto [BootNotifier.bootstrapStrict] abre o
///    núcleo REAL (SQLite FFI, sandbox, registry, providers, secret store);
/// 3. Se o boot falhar, a tela exibe o VtFailure tipado com retry — nunca um
///    estado inventado para "deixar a interface abrir".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'presentation/screens/vt_shell.dart';
import 'presentation/state/app_state.dart';
import 'presentation/theme/vt_theme.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  // Raízes de workspace vindas da CLI (ex.: `techvt .` ou `techvt a b`).
  final roots = args.where((a) => !a.startsWith('-')).toList();
  runApp(
    ProviderScope(
      child: TechVtApp(workspaceRootsFromCli: roots),
    ),
  );
}

class TechVtApp extends ConsumerStatefulWidget {
  const TechVtApp({super.key, this.workspaceRootsFromCli = const []});
  final List<String> workspaceRootsFromCli;

  @override
  ConsumerState<TechVtApp> createState() => _TechVtAppState();
}

class _TechVtAppState extends ConsumerState<TechVtApp> {
  @override
  void initState() {
    super.initState();
    ref.read(pendingWorkspaceRootsProvider.notifier).state =
        widget.workspaceRootsFromCli;
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    await ref.read(bootProvider.notifier).bootstrapStrict(
          workspaceRoots: widget.workspaceRootsFromCli,
          uiContext: () => context,
        );
  }

  @override
  Widget build(BuildContext context) {
    final choice = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'techVT',
      debugShowCheckedModeBanner: false,
      // Escolha explícita do usuário → ThemeData específico. O alto contraste
      // customizado é aplicado via builder (ThemeMode não tem slot para ele).
      theme: switch (choice) {
        VtThemeChoice.light => VtTheme.light(),
        _ => VtTheme.dark(),
      },
      darkTheme: VtTheme.dark(),
      themeMode: switch (choice) {
        VtThemeChoice.light => ThemeMode.light,
        VtThemeChoice.highContrast => ThemeMode.dark,
        VtThemeChoice.dark => ThemeMode.dark,
      },
      builder: (context, child) {
        if (choice == VtThemeChoice.highContrast) {
          return Theme(data: VtTheme.highContrast(), child: child!);
        }
        return child!;
      },
      home: const VtShell(),
    );
  }
}
