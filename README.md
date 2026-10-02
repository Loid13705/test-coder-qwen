# techVT

## Windows (plataforma prioritária)

O projeto inclui o runner desktop do Windows e foi priorizado para Windows 10
(versão 1903 ou posterior) e Windows 11. A camada local usa `winsqlite3.dll`,
disponível no sistema nessas versões do Windows.

Para compilar, executar e empacotar, use Windows com Flutter 3.24 ou posterior
e Visual Studio 2022 com a carga **Desktop development with C++** (incluindo
CMake e Windows SDK):

```sh
flutter pub get
flutter doctor -v
flutter analyze
flutter test
flutter run -d windows
flutter build windows --release
```

O executável de release fica em `build/windows/x64/runner/Release/`. Para
desenvolvimento em Linux ou macOS, habilite o runner da plataforma local com
`flutter create --platforms=linux .` ou `flutter create --platforms=macos .`.

O botão **Escolher…** em Workspaces usa o seletor nativo fornecido por
`file_picker`; adicionar/remover uma pasta também atualiza as raízes autorizadas
do sandbox na sessão atual.
