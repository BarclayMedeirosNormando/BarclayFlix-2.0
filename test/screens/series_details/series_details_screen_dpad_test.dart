import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iptv_app/data/models/watch_progress.dart';
import 'package:iptv_app/data/models/xtream_models.dart';
import 'package:iptv_app/data/services/storage_service.dart';
import 'package:iptv_app/data/services/xtream_api_service.dart';
import 'package:iptv_app/providers/auth_provider.dart';
import 'package:iptv_app/providers/continue_watching_provider.dart';
import 'package:iptv_app/providers/favorites_provider.dart';
import 'package:iptv_app/providers/series_details_provider.dart';
import 'package:iptv_app/screens/series_details/series_details_screen.dart';
import 'package:iptv_app/screens/series_details/series_seasons_screen.dart';

const _testDns = 'http://servidor-teste.com:8080';
const _testUser = 'cliente_teste';
const _testPass = 'senha_teste';

const _testSeries = Series(
  seriesId: 55,
  name: 'Série Teste',
  cover: '',
  plot: 'Sinopse inicial (já vinda da HomeScreen)',
  cast: 'Ator A, Ator B',
  director: 'Diretor X',
  genre: 'Drama',
  releaseDate: '2020-01-01',
  rating: 7.0,
  categoryId: '20',
);

/// Dataset fixo: temporada "1" com 2 episódios (id 101/102), temporada "2"
/// com 1 episódio (id 201) -- o episódio "alvo" default (sem progresso
/// salvo) é sempre T1E1 ("Piloto", id 101), o de menor temporada/número.
Future<http.Response> _seriesInfoHandler(http.Request request) async {
  if (request.url.queryParameters['action'] != 'get_series_info') {
    return http.Response('Not Found', 404);
  }

  return _json({
    'info': {
      'name': 'Série Teste',
      'cover': '',
      'plot': 'Sinopse detalhada vinda da rede',
      'cast': 'Ator A, Ator B',
      'director': 'Diretor X',
      'genre': 'Drama',
      'release_date': '2020-01-01',
      'rating': '8.5',
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
    },
  });
}

/// Primeira chamada de `get_series_info` falha (HTTP 500); as seguintes
/// respondem normalmente — usado para testar o botão "Tentar novamente".
Future<http.Response> Function(http.Request) _failFirstThenSucceed() {
  var callCount = 0;
  return (request) async {
    if (request.url.queryParameters['action'] != 'get_series_info') {
      return http.Response('Not Found', 404);
    }
    callCount++;
    if (callCount == 1) {
      return http.Response('erro interno', 500);
    }
    return _seriesInfoHandler(request);
  };
}

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

Future<void> pumpSeriesDetailsScreen(
  WidgetTester tester, {
  Future<http.Response> Function(http.Request)? handler,
  ContinueWatchingProvider? continueWatchingProvider,
}) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // Só reseta o mock quando NINGUÉM já preparou um ContinueWatchingProvider
  // de propósito (ver o teste de "Continuar") -- chamar de novo aqui
  // apagaria o progresso salvo por quem chamou antes desta função.
  if (continueWatchingProvider == null) {
    SharedPreferences.setMockInitialValues({});
  }

  final apiService = XtreamApiService(
    dns: _testDns,
    username: _testUser,
    password: _testPass,
    client: MockClient(handler ?? _seriesInfoHandler),
  );

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider(apiService: apiService)),
        ChangeNotifierProvider<SeriesDetailsProvider>(create: (_) => SeriesDetailsProvider()),
        ChangeNotifierProvider<ContinueWatchingProvider>.value(
          value: continueWatchingProvider ?? ContinueWatchingProvider(storageService: StorageService()),
        ),
        ChangeNotifierProvider<FavoritesProvider>(create: (_) => FavoritesProvider(storageService: StorageService())),
      ],
      child: const MaterialApp(home: SeriesDetailsScreen(series: _testSeries)),
    ),
  );
}

/// Mesmo padrão dos outros testes de D-Pad do projeto: [Focus.of] busca o
/// FocusNode do ancestral mais próximo, então os finders apontam para algo
/// DENTRO do widget interativo real.
bool isFocused(WidgetTester tester, Finder finder) {
  return Focus.of(tester.element(finder)).hasFocus;
}

/// Confirma que ALGUM nó de foco já está ativo assim que a tela abre, SEM
/// nenhuma chamada manual de `requestFocus()` — essa é a condição real que
/// faz o Escape/D-Pad funcionarem desde o primeiro frame.
bool _rootHasAutofocus(WidgetTester tester) {
  final finder = find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'series-details-screen-root');
  final focusNode = tester.widget<Focus>(finder).focusNode;
  return focusNode != null && focusNode.hasFocus;
}

void main() {
  group('Autofoco inicial (sem foco manual)', () {
    testWidgets('a tela já tem um nó de foco ativo assim que abre, sem nenhum requestFocus() manual', (tester) async {
      await pumpSeriesDetailsScreen(tester);
      await tester.pump();

      expect(_rootHasAutofocus(tester), isTrue);
    });

    testWidgets('o botão "Assistir T1E1" já fica focado sozinho assim que os episódios carregam', (tester) async {
      await pumpSeriesDetailsScreen(tester);
      await tester.pumpAndSettle();

      // O salto automático do wrapper invisível pro botão de assistir já
      // aconteceu sozinho (ver `_handOffInitialFocusIfReady`) -- sem ele,
      // nenhuma seta moveria o foco pra lugar nenhum a partir daqui.
      expect(isFocused(tester, find.text('Assistir T1E1')), isTrue);
    });
  });

  group('Header imediato', () {
    testWidgets(
      'mostra dados do Series recebido antes da rede responder, depois troca pelos dados carregados',
      (tester) async {
        final completer = Completer<void>();
        Future<http.Response> delayedHandler(http.Request request) async {
          await completer.future;
          return _seriesInfoHandler(request);
        }

        await pumpSeriesDetailsScreen(tester, handler: delayedHandler);
        await tester.pump();

        expect(find.text('Série Teste'), findsNWidgets(2));
        expect(find.text('Sinopse inicial (já vinda da HomeScreen)'), findsOneWidget);
        // Sem episódios ainda carregados, o botão mostra "Assistir" genérico
        // (sem T{s}E{e}, ver SeriesDetailsScreen._resolveTarget == null) e
        // fica em estado de loading.
        expect(find.text('Assistir'), findsOneWidget);

        completer.complete();
        await tester.pumpAndSettle();

        expect(find.text('Sinopse detalhada vinda da rede'), findsOneWidget);
        expect(find.text('Sinopse inicial (já vinda da HomeScreen)'), findsNothing);
        expect(find.text('Assistir T1E1'), findsOneWidget);
      },
    );
  });

  group('Ação principal (Assistir/Continuar)', () {
    testWidgets('sem progresso salvo, mostra "Assistir T1E1" (primeiro episódio da série)', (tester) async {
      await pumpSeriesDetailsScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('Assistir T1E1'), findsOneWidget);
      expect(find.text('Continuar T1E1'), findsNothing);
    });

    testWidgets('com progresso salvo num episódio, mostra "Continuar" pra esse episódio', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storageService = StorageService();
      await storageService.saveProgress(WatchProgress(
        contentId: '102',
        title: 'Segundo Episódio',
        imageUrl: '',
        positionSeconds: 120,
        durationSeconds: 1200,
        type: WatchProgressType.episode,
        playbackUrl: 'http://exemplo.com/102.mp4',
        lastWatchedAt: DateTime.now(),
      ));
      final continueWatching = ContinueWatchingProvider(storageService: storageService);
      await continueWatching.load();

      await pumpSeriesDetailsScreen(tester, continueWatchingProvider: continueWatching);
      await tester.pumpAndSettle();

      expect(find.text('Continuar T1E2'), findsOneWidget);
      expect(find.text('Assistir T1E1'), findsNothing);
    });
  });

  group('Ícone de Temporadas', () {
    testWidgets('abre SeriesSeasonsScreen', (tester) async {
      await pumpSeriesDetailsScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Temporadas'));
      await tester.pumpAndSettle();

      expect(find.byType(SeriesSeasonsScreen), findsOneWidget);
    });
  });

  group('Erro e retry', () {
    testWidgets('mostra erro com "Tentar novamente" e recupera ao tocar', (tester) async {
      await pumpSeriesDetailsScreen(tester, handler: _failFirstThenSucceed());
      await tester.pumpAndSettle();

      expect(find.text('Tentar novamente'), findsOneWidget);
      expect(find.text('Assistir T1E1'), findsNothing);

      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();

      expect(find.text('Assistir T1E1'), findsOneWidget);
    });
  });

  group('Voltar/Escape', () {
    testWidgets('Escape volta para a tela anterior', (tester) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>(
              create: (_) => AuthProvider(
                apiService: XtreamApiService(
                  dns: _testDns,
                  username: _testUser,
                  password: _testPass,
                  client: MockClient(_seriesInfoHandler),
                ),
              ),
            ),
            ChangeNotifierProvider<SeriesDetailsProvider>(create: (_) => SeriesDetailsProvider()),
            ChangeNotifierProvider<ContinueWatchingProvider>(
              create: (_) => ContinueWatchingProvider(storageService: StorageService()),
            ),
            ChangeNotifierProvider<FavoritesProvider>(create: (_) => FavoritesProvider(storageService: StorageService())),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SeriesDetailsScreen(series: _testSeries)),
                    ),
                    child: const Text('Abrir Série'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir Série'));
      await tester.pumpAndSettle();

      expect(find.byType(SeriesDetailsScreen), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(SeriesDetailsScreen), findsNothing);
      expect(find.text('Abrir Série'), findsOneWidget);
    });
  });

  group('Cache por seriesId', () {
    testWidgets('reabrir a mesma série na mesma sessão não repete a chamada de rede', (tester) async {
      var callCount = 0;
      Future<http.Response> countingHandler(http.Request request) async {
        if (request.url.queryParameters['action'] == 'get_series_info') callCount++;
        return _seriesInfoHandler(request);
      }

      final seriesDetailsProvider = SeriesDetailsProvider();
      final apiService = XtreamApiService(
        dns: _testDns,
        username: _testUser,
        password: _testPass,
        client: MockClient(countingHandler),
      );

      Widget buildApp() {
        return MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider(apiService: apiService)),
            ChangeNotifierProvider<SeriesDetailsProvider>.value(value: seriesDetailsProvider),
            ChangeNotifierProvider<ContinueWatchingProvider>(
              create: (_) => ContinueWatchingProvider(storageService: StorageService()),
            ),
            ChangeNotifierProvider<FavoritesProvider>(create: (_) => FavoritesProvider(storageService: StorageService())),
          ],
          child: const MaterialApp(home: SeriesDetailsScreen(series: _testSeries)),
        );
      }

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();
      expect(callCount, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      expect(callCount, 1, reason: 'esperava reaproveitar o cache em memória, sem nova chamada de rede');
      expect(find.text('Assistir T1E1'), findsOneWidget);
    });
  });
}
