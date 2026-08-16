import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  testWidgets('lista vazia: mostra hint e nenhum botão de ação na AppBar', (tester) async {
    await pumpContinueWatchingScreen(tester);

    expect(find.textContaining('Nada assistido ainda'), findsOneWidget);
    expect(find.byTooltip('Limpar tudo'), findsNothing);
    expect(find.byTooltip('Selecionar pra remover'), findsNothing);
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
    await tester.tap(find.text('Remover'));
    await tester.pumpAndSettle();

    expect(find.text('Filme A'), findsNothing);
    expect(find.textContaining('Nada assistido ainda'), findsOneWidget);
  });

  group('Modo Selecionar (D-Pad)', () {
    testWidgets('ligar o modo faz Enter marcar o card em vez de abrir o Player', (tester) async {
      await pumpContinueWatchingScreen(tester, seed: [
        _progress('1', title: 'Filme A'),
        _progress('2', title: 'Filme B'),
      ]);

      await tester.tap(find.byTooltip('Selecionar pra remover'));
      await tester.pumpAndSettle();

      expect(find.text('0 selecionado(s)'), findsOneWidget);

      await tester.tap(find.text('Filme A'));
      await tester.pumpAndSettle();

      // Marcou (badge de check apareceu), não navegou pro Player.
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.text('1 selecionado(s)'), findsOneWidget);
      expect(find.text('Filme A'), findsOneWidget, reason: 'continua na mesma tela');
    });

    testWidgets('"Remover selecionados" só remove os marcados, com confirmação', (tester) async {
      await pumpContinueWatchingScreen(tester, seed: [
        _progress('1', title: 'Filme A'),
        _progress('2', title: 'Filme B'),
      ]);

      await tester.tap(find.byTooltip('Selecionar pra remover'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Filme A'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remover selecionados'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.text('Remover'));
      await tester.pumpAndSettle();

      expect(find.text('Filme A'), findsNothing);
      expect(find.text('Filme B'), findsOneWidget, reason: 'não estava marcado, continua na lista');
      // Sai do modo Selecionar automaticamente depois de remover.
      expect(find.text('Continuar Assistindo'), findsOneWidget);
    });

    testWidgets('Escape sai do modo Selecionar primeiro, só volta pra tela anterior na segunda vez', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storageService = StorageService();
      await storageService.saveProgress(_progress('1', title: 'Filme A'));
      final provider = ContinueWatchingProvider(storageService: storageService);
      await provider.load();

      await tester.pumpWidget(
        ChangeNotifierProvider<ContinueWatchingProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ContinueWatchingScreen()),
                ),
                child: const Text('Abrir'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      expect(find.byType(ContinueWatchingScreen), findsOneWidget);

      await tester.tap(find.byTooltip('Selecionar pra remover'));
      await tester.pumpAndSettle();
      expect(find.text('0 selecionado(s)'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(ContinueWatchingScreen), findsOneWidget, reason: 'primeiro Escape só sai do modo Selecionar');
      expect(find.text('Continuar Assistindo'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(ContinueWatchingScreen), findsNothing, reason: 'segundo Escape (já fora do modo) volta pra tela anterior');
      expect(find.text('Abrir'), findsOneWidget);
    });
  });
}
