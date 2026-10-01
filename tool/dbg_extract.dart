import 'package:techvt/infrastructure/search/code_index_store.dart';

void main() {
  for (final s in extractDartSymbols('''
abstract class BaseThing {
  final String name;
  int counter = 0;

  BaseThing(this.name);

  Future<void> doWork({int? attempts}) async {
    if (attempts == null) return;
  }
}

class Widget extends BaseThing with Loudly {
''')) {
    print('${s.$2} ${s.$1} line=${s.$3}');
  }
}
