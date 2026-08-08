import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:iptv_app/data/models/xtream_models.dart';
import 'package:iptv_app/data/services/xtream_api_service.dart';
import 'package:iptv_app/providers/auth_provider.dart';
import 'package:iptv_app/providers/series_details_provider.dart';
import 'package:iptv_app/screens/series_details/series_details_screen.dart';
import 'package:iptv_app/widgets/skeleton_loader.dart';

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

/// Dataset fixo: temporada "1" com 2 episódios, temporada "2" com 1
/// episódio, temporada "3" sem nenhum episódio (para o estado vazio).
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
      '3': [],
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
}) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

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
      ],
      child: const MaterialApp(home: SeriesDetailsScreen(series: _testSeries)),
    ),
  );
}

/// Mesmo padrão dos outros testes de D-Pad do projeto (ver
/// home_screen_dpad_test.dart): [Focus.of] busca o FocusNode do ancestral
/// mais próximo, então os finders apontam para algo DENTRO do widget
/// interativo real.
bool isFocused(WidgetTester tester, Finder finder) {
  return Focus.of(tester.element(finder)).hasFocus;
}

void focusItem(WidgetTester tester, Finder finder) {
  Focus.of(tester.element(finder)).requestFocus();
}

/// Confirma que ALGUM nó de foco já está ativo assim que a tela abre, SEM
/// nenhuma chamada manual de `requestFocus()` (nem `focusItem` acima) —
/// essa é a condição real que faz o Escape/D-Pad funcionarem desde o
/// primeiro frame (ver `Focus(autofocus: true)` em
/// series_details_screen.dart). Localiza o `Focus` raiz da tela pelo
/// `debugLabel` do seu `FocusNode` (não por `autofocus`/`skipTraversal`: o
/// próprio `Navigator` do Flutter já cria um `Focus` interno com essa
/// MESMA combinação de propriedades para cada rota — achado rodando este
/// teste, que por isso não pode distinguir "nosso" nó do nó interno do
/// framework só por elas).
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

      // Nenhum focusItem()/requestFocus() antes desta linha — é exatamente
      // essa ausência que reproduziria o bug relatado em dispositivo
      // físico (D-Pad sem efeito nenhum): sem autofoco, nada na árvore
      // teria foco de teclado pra receber a primeira seta ou o Escape.
      expect(_rootHasAutofocus(tester), isTrue);
    });

    testWidgets(
      'o seletor de temporada já fica focado sozinho, e a seta move pra próxima — tudo sem foco manual',
      (tester) async {
        await pumpSeriesDetailsScreen(tester);
        await tester.pumpAndSettle();

        // O salto automático do wrapper invisível pro seletor de
        // temporada já aconteceu sozinho (ver
        // `_handOffInitialFocusIfReady` em series_details_screen.dart) —
        // sem ele, nenhuma seta moveria o foco pra lugar nenhum a partir
        // daqui (achado empírico: busca DIRECIONAL, ao contrário de
        // `nextFocus`/Tab, não atravessa a fronteira de um nó
        // `skipTraversal` sozinha).
        expect(isFocused(tester, find.text('Temporada 1')), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();

        expect(isFocused(tester, find.text('Temporada 2')), isTrue);
      },
    );
  });

  group('Header imediato', () {
    testWidgets(
      'mostra dados do Series recebido antes da rede responder, depois troca pelos dados carregados',
      (tester) async {
        // MockClient resolve rápido demais (mesmo turno de evento) para
        // observar o estado "ainda carregando" com um handler sem atraso —
        // este completer segura a resposta até o teste liberar de propósito.
        final completer = Completer<void>();
        Future<http.Response> delayedHandler(http.Request request) async {
          await completer.future;
          return _seriesInfoHandler(request);
        }

        await pumpSeriesDetailsScreen(tester, handler: delayedHandler);
        await tester.pump();

        // Duas ocorrências esperadas: título do AppBar + nome no header.
        expect(find.text('Série Teste'), findsNWidgets(2));
        expect(find.text('Sinopse inicial (já vinda da HomeScreen)'), findsOneWidget);
        expect(find.text('Temporada 1'), findsNothing);
        // Skeleton loading no lugar do spinner genérico: mesma silhueta do
        // seletor de temporada + lista de episódios reais (ver Bloco 5).
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(SkeletonChip), findsWidgets);
        expect(find.byType(SkeletonListRow), findsWidgets);

        completer.complete();
        await tester.pumpAndSettle();

        expect(find.text('Sinopse detalhada vinda da rede'), findsOneWidget);
        expect(find.text('Sinopse inicial (já vinda da HomeScreen)'), findsNothing);
      },
    );
  });

  group('Seletor de temporada', () {
    testWidgets('navegável lateralmente e troca a lista de episódios ao ativar', (tester) async {
      await pumpSeriesDetailsScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('Piloto'), findsOneWidget);
      expect(find.text('Retorno'), findsNothing);

      focusItem(tester, find.text('Temporada 1'));
      await tester.pump();
      expect(isFocused(tester, find.text('Temporada 1')), isTrue);

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
      await pumpSeriesDetailsScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Temporada 3'));
      await tester.pumpAndSettle();

      expect(find.text('Nenhum episódio listado nesta temporada.'), findsOneWidget);
    });
  });

  group('Lista de episódios', () {
    testWidgets('seta para baixo move o foco sequencialmente entre os episódios', (tester) async {
      await pumpSeriesDetailsScreen(tester);
      await tester.pumpAndSettle();

      focusItem(tester, find.text('Piloto'));
      await tester.pump();
      expect(isFocused(tester, find.text('Piloto')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(isFocused(tester, find.text('Segundo Episódio')), isTrue);
      expect(isFocused(tester, find.text('Piloto')), isFalse);
    });

    testWidgets(
      'seta esquerda/direita em qualquer episódio devolve o foco para a temporada selecionada',
      (tester) async {
        await pumpSeriesDetailsScreen(tester);
        await tester.pumpAndSettle();

        focusItem(tester, find.text('Segundo Episódio'));
        await tester.pump();
        expect(isFocused(tester, find.text('Segundo Episódio')), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();

        expect(isFocused(tester, find.text('Segundo Episódio')), isFalse);
        expect(
          isFocused(tester, find.text('Temporada 1')),
          isTrue,
          reason: 'lista de episódios é uma coluna única — toda seta lateral é uma "borda"',
        );

        // A mesma redireção vale para a seta direita.
        focusItem(tester, find.text('Piloto'));
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();

        expect(isFocused(tester, find.text('Temporada 1')), isTrue);
      },
    );
  });

  group('Erro e retry', () {
    testWidgets('mostra erro com "Tentar novamente" e recupera ao tocar', (tester) async {
      await pumpSeriesDetailsScreen(tester, handler: _failFirstThenSucceed());
      await tester.pumpAndSettle();

      expect(find.text('Tentar novamente'), findsOneWidget);
      expect(find.text('Temporada 1'), findsNothing);

      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();

      expect(find.text('Temporada 1'), findsOneWidget);
      expect(find.text('Piloto'), findsOneWidget);
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
          ],
          child: const MaterialApp(home: SeriesDetailsScreen(series: _testSeries)),
        );
      }

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();
      expect(callCount, 1);

      // Simula "voltar e reabrir a mesma série": desmonta e monta uma nova
      // instância da tela, mas com o MESMO SeriesDetailsProvider (registrado
      // no topo da árvore, como em main.dart — sobrevive ao push/pop real).
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      expect(callCount, 1, reason: 'esperava reaproveitar o cache em memória, sem nova chamada de rede');
      expect(find.text('Piloto'), findsOneWidget);
    });
  });
}
