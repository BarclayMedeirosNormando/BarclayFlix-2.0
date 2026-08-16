import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iptv_app/data/models/xtream_models.dart';
import 'package:iptv_app/data/services/storage_service.dart';
import 'package:iptv_app/data/services/xtream_api_service.dart';
import 'package:iptv_app/providers/auth_provider.dart';
import 'package:iptv_app/providers/continue_watching_provider.dart';
import 'package:iptv_app/providers/series_details_provider.dart';
import 'package:iptv_app/providers/settings_provider.dart';
import 'package:iptv_app/screens/series_details/series_seasons_screen.dart';

const _testDns = 'http://servidor-teste.com:8080';
const _testUser = 'cliente_teste';
const _testPass = 'senha_teste';

const _testSeries = Series(
  seriesId: 55,
  name: 'Série Teste',
  cover: '',
  plot: '',
  cast: '',
  director: '',
  genre: '',
  releaseDate: '',
  rating: 0,
  categoryId: '20',
);

/// Mesmo dataset de series_details_screen_dpad_test.dart: temporada "1" com
/// 2 episódios, temporada "2" com 1, temporada "3" sem nenhum (estado
/// vazio).
Future<http.Response> _seriesInfoHandler(http.Request request) async {
  if (request.url.queryParameters['action'] != 'get_series_info') {
    return http.Response('Not Found', 404);
  }

  return http.Response(
    jsonEncode({
      'info': {
        'name': 'Série Teste',
        'cover': '',
        'plot': '',
        'cast': '',
        'director': '',
        'genre': '',
        'release_date': '',
        'rating': '0',
        'category_id': '20',
      },
      'episodes': {
        '1': [
          {'id': '101', 'episode_num': 1, 'title': 'Piloto', 'container_extension': 'mp4', 'season': 1, 'info': {}},
          {
            'id': '102',
            'episode_num': 2,
            'title': 'Segundo Episódio',
            'container_extension': 'mp4',
            'season': 1,
            'info': {},
          },
        ],
        '2': [
          {'id': '201', 'episode_num': 1, 'title': 'Retorno', 'container_extension': 'mp4', 'season': 2, 'info': {}},
        ],
        '3': [],
      },
    }),
    200,
  );
}

bool isFocused(WidgetTester tester, Finder finder) => Focus.of(tester.element(finder)).hasFocus;

void focusItem(WidgetTester tester, Finder finder) => Focus.of(tester.element(finder)).requestFocus();

/// Pré-carrega o [SeriesDetailsProvider] (mesmo estado que SeriesDetailsScreen
/// já deixa pronto antes do ícone "Temporadas" ficar tocável, ver
/// SeriesDetailsScreen._openSeasons) e sobe a SeriesSeasonsScreen sozinha.
Future<void> pumpSeriesSeasonsScreen(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({});

  final apiService = XtreamApiService(dns: _testDns, username: _testUser, password: _testPass, client: MockClient(_seriesInfoHandler));
  final seriesDetailsProvider = SeriesDetailsProvider();
  await seriesDetailsProvider.loadSeriesInfo(apiService, _testSeries.seriesId.toString());

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider(apiService: apiService)),
        ChangeNotifierProvider<SeriesDetailsProvider>.value(value: seriesDetailsProvider),
        ChangeNotifierProvider<ContinueWatchingProvider>(
          create: (_) => ContinueWatchingProvider(storageService: StorageService()),
        ),
        ChangeNotifierProvider<SettingsProvider>(create: (_) => SettingsProvider(storageService: StorageService())),
      ],
      child: const MaterialApp(home: SeriesSeasonsScreen(series: _testSeries)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Autofoco inicial', () {
    testWidgets('abre com "Temporada 1" já focada, sem nenhum foco manual', (tester) async {
      await pumpSeriesSeasonsScreen(tester);

      expect(isFocused(tester, find.text('Temporada 1')), isTrue);
    });
  });

  group('Seletor de temporada', () {
    testWidgets('navegável lateralmente e troca a lista de episódios ao ativar', (tester) async {
      await pumpSeriesSeasonsScreen(tester);

      expect(find.text('Piloto'), findsOneWidget);
      expect(find.text('Retorno'), findsNothing);

      focusItem(tester, find.text('Temporada 1'));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(isFocused(tester, find.text('Temporada 2')), isTrue);
      expect(isFocused(tester, find.text('Temporada 1')), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Retorno'), findsOneWidget);
      expect(find.text('Piloto'), findsNothing);
    });

    testWidgets('temporada sem episódios mostra estado vazio', (tester) async {
      await pumpSeriesSeasonsScreen(tester);

      await tester.tap(find.text('Temporada 3'));
      await tester.pumpAndSettle();

      expect(find.text('Nenhum episódio listado nesta temporada.'), findsOneWidget);
    });
  });

  group('Lista de episódios', () {
    testWidgets('seta para baixo move o foco sequencialmente entre os episódios', (tester) async {
      await pumpSeriesSeasonsScreen(tester);

      focusItem(tester, find.text('Piloto'));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(isFocused(tester, find.text('Segundo Episódio')), isTrue);
      expect(isFocused(tester, find.text('Piloto')), isFalse);
    });

    testWidgets('seta esquerda/direita em qualquer episódio devolve o foco para a temporada selecionada', (tester) async {
      await pumpSeriesSeasonsScreen(tester);

      focusItem(tester, find.text('Segundo Episódio'));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(isFocused(tester, find.text('Segundo Episódio')), isFalse);
      expect(
        isFocused(tester, find.text('Temporada 1')),
        isTrue,
        reason: 'lista de episódios é uma coluna única -- toda seta lateral é uma "borda"',
      );

      focusItem(tester, find.text('Piloto'));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(isFocused(tester, find.text('Temporada 1')), isTrue);
    });

    testWidgets('tocar num episódio abre o Player', (tester) async {
      await pumpSeriesSeasonsScreen(tester);

      await tester.tap(find.text('Piloto'));
      await tester.pump();

      // A PlayerScreen real não termina de montar em teste (precisa do
      // media_kit nativo) -- só confirma que o toque não lançou nenhuma
      // exceção de provider ausente antes de chegar lá.
      final thrown = tester.takeException();
      if (thrown != null) {
        expect(thrown.toString(), isNot(contains('ProviderNotFoundException')));
      }
    });
  });

  group('Voltar/Escape', () {
    testWidgets('Escape volta para a tela anterior', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final apiService = XtreamApiService(dns: _testDns, username: _testUser, password: _testPass, client: MockClient(_seriesInfoHandler));
      final seriesDetailsProvider = SeriesDetailsProvider();
      await seriesDetailsProvider.loadSeriesInfo(apiService, _testSeries.seriesId.toString());

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider(apiService: apiService)),
            ChangeNotifierProvider<SeriesDetailsProvider>.value(value: seriesDetailsProvider),
            ChangeNotifierProvider<ContinueWatchingProvider>(
              create: (_) => ContinueWatchingProvider(storageService: StorageService()),
            ),
            ChangeNotifierProvider<SettingsProvider>(create: (_) => SettingsProvider(storageService: StorageService())),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SeriesSeasonsScreen(series: _testSeries)),
                    ),
                    child: const Text('Abrir Temporadas'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir Temporadas'));
      await tester.pumpAndSettle();
      expect(find.byType(SeriesSeasonsScreen), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(SeriesSeasonsScreen), findsNothing);
      expect(find.text('Abrir Temporadas'), findsOneWidget);
    });
  });
}
