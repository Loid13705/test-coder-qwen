# techVT

## Desenvolvimento desktop

Requer Flutter 3.24 ou posterior. As dependências da interface e o seletor
nativo de diretórios estão declarados no `pubspec.yaml`.

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d linux
```

No macOS ou Windows, substitua `linux` pelo device desktop correspondente.
O botão **Escolher…** em Workspaces usa o seletor de diretórios fornecido por
`file_picker`; adicionar/remover uma pasta também atualiza as raízes autorizadas
do sandbox na sessão atual.