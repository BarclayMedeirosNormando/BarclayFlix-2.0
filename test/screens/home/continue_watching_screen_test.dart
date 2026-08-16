import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iptv_app/data/models/watch_progress.dart';
import 'package:iptv_app/data/services/storage_service.dart';
import 'package:iptv_app/providers/continue_watching_provider.dart';
import 'package:iptv_app/screens/home/continue_watching_screen.dart';

WatchProgress _progress(String id, {String title = 'Item'}) => WatchProgress(
      contentId: id,
      title: title,
      imageUrl: '',
      positionSeconds: 120,
      durationSeconds: 1200,
      type: WatchProgressType.vod,
      playbackUrl: 'http://exemplo.com/$id.mp4',
      lastWatchedAt: DateTime.now(),
    );

Future<ContinueWatchingProvider> pumpContinueWatchingScreen(
  WidgetTester tester, {
  List<WatchProgress> seed = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  final storageService = StorageService();
  for (final progress in seed) {
    await storageService.saveProgress(progress);
  }
  final provider = ContinueWatchingProvider(storageService: storageService);
  await provider.load();

  await tester.pumpWidget(
    ChangeNotifierProvider<ContinueWatchingProvider>.value(
      value: provider,
      child: const MaterialApp(home: ContinueWatchingScreen()),
    ),
  );
  await tester.pumpAndSettle();

  return provider;
}

void main() {
  testWidgets('lista vazia: mostra hint e o botão "Limpar tudo" fica desabilitado', (tester) async {
    await pumpContinueWatchingScreen(tester);

    expect(find.textContaining('Nada assistido ainda'), findsOneWidget);

    // find.byTooltip acha o `Tooltip` interno do IconButton, não o
    // IconButton em si -- precisa do predicate pra pegar o widget certo.
    final button = tester.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Limpar tudo'));
    expect(button.onPressed, isNull);
  });

  testWidgets('"X" no card remove só aquele item, sem confirmação', (tester) async {
    await pumpContinueWatchingScreen(tester, seed: [
      _progress('1', title: 'Filme A'),
      _progress('2', title: 'Filme B'),
    ]);

    expect(find.text('Filme A'), findsOneWidget);
    expect(find.text('Filme B'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    // Sem diálogo nenhum no meio do caminho -- some direto.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Filme B'), findsOneWidget, reason: 'o outro item continua intacto');
  });

  testWidgets('"Limpar tudo" pede confirmação antes de esvaziar a lista', (tester) async {
    await pumpContinueWatchingScreen(tester, seed: [_progress('1', title: 'Filme A')]);

    await tester.tap(find.byTooltip('Limpar tudo'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Filme A'), findsOneWidget, reason: 'ainda não confirmou, nada foi removido');

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('Filme A'), findsOneWidget, reason: 'cancelar não deve remover nada');

    await tester.tap(find.byTooltip('Limpar tudo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Limpar tudo').last);
    await tester.pumpAndSettle();

    expect(find.text('Filme A'), findsNothing);
    expect(find.textContaining('Nada assistido ainda'), findsOneWidget);
  });
}
