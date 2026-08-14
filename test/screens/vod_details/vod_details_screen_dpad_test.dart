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
import 'package:iptv_app/providers/vod_details_provider.dart';
import 'package:iptv_app/screens/vod_details/vod_details_screen.dart';
import 'package:iptv_app/widgets/skeleton_loader.dart';

const _testDns = 'http://servidor-teste.com:8080';
const _testUser = 'cliente_teste';
const _testPass = 'senha_teste';

const _testMovie = VodStream(
  streamId: 5001,
  name: 'Filme Teste',
  streamIcon: '',
  categoryId: '10',
  containerExtension: 'mp4',
  rating: 7.0,
  added: null,
);

Future<http.Response> _vodInfoHandler(http.Request request) async {
  if (request.url.queryParameters['action'] != 'get_vod_info') {
    return http.Response('Not Found', 404);
  }
  return _json({
    'info': {
      'plot': 'Sinopse detalhada vinda da rede',
      'cast': 'Ator A, Ator B',
      'director': 'Diretor X',
      'genre': 'Ação',
      'release_date': '2020-01-01',
      'rating': '8.5',
      'duration_secs': 7200,
    },
    'movie_data': {'stream_id': 5001},
  });
}

/// Primeira chamada de `get_vod_info` falha (HTTP 500); as seguintes
/// respondem normalmente — usado para testar o retry inline da sinopse.
Future<http.Response> Function(http.Request) _failFirstThenSucceed() {
  var callCount = 0;
  return (request) async {
    if (request.url.queryParameters['action'] != 'get_vod_info') {
      return http.Response('Not Found', 404);
    }
    callCount++;
    if (callCount == 1) return http.Response('erro interno', 500);
    return _vodInfoHandler(request);
  };
}

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

Future<void> pumpVodDetailsScreen(
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
    client: MockClient(handler ?? _vodInfoHandler),
  );

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider(apiService: apiService)),
        ChangeNotifierProvider<VodDetailsProvider>(create: (_) => VodDetailsProvider()),
      ],
      child: const MaterialApp(home: VodDetailsScreen(movie: _testMovie)),
    ),
  );
}

bool isFocused(WidgetTester tester, Finder finder) {
  return Focus.of(tester.element(finder)).hasFocus;
}

/// Mesmo padrão de series_details_screen_dpad_test.dart: localiza o `Focus`
/// raiz pelo `debugLabel` do seu FocusNode (o Navigator interno do Flutter
/// cria um `Focus` com a MESMA combinação autofocus/skipTraversal, então não
/// dá pra distinguir os dois só por essas propriedades).
bool _rootHasAutofocus(WidgetTester tester) {
  final finder = find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'vod-details-screen-root');
  final focusNode = tester.widget<Focus>(finder).focusNode;
  return focusNode != null && focusNode.hasFocus;
}

void main() {
  group('Autofoco inicial (sem foco manual)', () {
    testWidgets('a tela já tem um nó de foco ativo assim que abre, sem nenhum requestFocus() manual', (tester) async {
      await pumpVodDetailsScreen(tester);
      await tester.pump();

      expect(_rootHasAutofocus(tester), isTrue);
    });

    testWidgets('o botão "Assistir" já fica focado sozinho, sem esperar get_vod_info', (tester) async {
      // Handler que demora (não "nunca responde") -- prova que o foco no
      // botão não depende do carregamento de metadados (ao contrário da
      // temporada em SeriesDetailsScreen, que só existe depois de
      // get_series_info). Completado no fim do teste: um completer que
      // nunca resolve deixaria o Timer de AppConstants.networkTimeout
      // pendente após o widget tree ser descartado -- accusado pelo
      // próprio framework de teste como vazamento.
      final delayed = Completer<http.Response>();
      await pumpVodDetailsScreen(tester, handler: (_) => delayed.future);
      await tester.pump();
      await tester.pump();

      expect(isFocused(tester, find.text('Assistir')), isTrue);

      delayed.complete(await _vodInfoHandler(http.Request('GET', Uri.parse('$_testDns?action=get_vod_info'))));
      await tester.pumpAndSettle();
    });
  });

  group('Header imediato', () {
    testWidgets('mostra dados do VodStream recebido antes da rede responder, depois troca pelos metadados',
        (tester) async {
      final completer = Completer<void>();
      Future<http.Response> delayedHandler(http.Request request) async {
        await completer.future;
        return _vodInfoHandler(request);
      }

      await pumpVodDetailsScreen(tester, handler: delayedHandler);
      await tester.pump();

      // Duas ocorrências: título do AppBar + nome no header.
      expect(find.text('Filme Teste'), findsNWidgets(2));
      // Nota já vem do VodStream (7.0) antes da rede responder.
      expect(find.text('7.0'), findsOneWidget);
      expect(find.text('Assistir'), findsOneWidget);
      expect(find.byType(SkeletonBox), findsWidgets);
      expect(find.textContaining('Sinopse'), findsNothing);

      completer.complete();
      await tester.pumpAndSettle();

      expect(find.text('Sinopse detalhada vinda da rede'), findsOneWidget);
      // A nota de get_vod_info (8.5) substitui a do VodStream (7.0).
      expect(find.text('8.5'), findsOneWidget);
      expect(find.text('7.0'), findsNothing);
      expect(find.textContaining('Elenco: Ator A, Ator B'), findsOneWidget);
      expect(find.textContaining('Direção: Diretor X'), findsOneWidget);
    });
  });

  group('Erro e retry (só da sinopse, nunca do botão Assistir)', () {
    testWidgets('mostra hint discreto com "Tentar novamente", sem esconder o botão Assistir', (tester) async {
      await pumpVodDetailsScreen(tester, handler: _failFirstThenSucceed());
      await tester.pumpAndSettle();

      expect(find.text('Tentar novamente'), findsOneWidget);
      expect(find.text('Assistir'), findsOneWidget, reason: 'reprodução não depende de get_vod_info');

      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();

      expect(find.text('Sinopse detalhada vinda da rede'), findsOneWidget);
      expect(find.text('Tentar novamente'), findsNothing);
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
                  client: MockClient(_vodInfoHandler),
                ),
              ),
            ),
            ChangeNotifierProvider<VodDetailsProvider>(create: (_) => VodDetailsProvider()),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const VodDetailsScreen(movie: _testMovie)),
                    ),
                    child: const Text('Abrir Filme'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir Filme'));
      await tester.pumpAndSettle();

      expect(find.byType(VodDetailsScreen), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(VodDetailsScreen), findsNothing);
      expect(find.text('Abrir Filme'), findsOneWidget);
    });
  });

  group('Botão Assistir', () {
    testWidgets(
      'tocar não lança ProviderNotFoundException<ContinueWatchingProvider> '
      '(regressão: VodDetailsScreen é uma rota IRMÃ da HomeScreen, não descendente dela -- '
      'ContinueWatchingProvider só existe na árvore local da HomeScreen, ver home_screen.dart)',
      (tester) async {
        // Mesma forma exata de árvore da produção: VodDetailsScreen empurrada
        // via Navigator.push a partir de uma rota que só tem AuthProvider/
        // VodDetailsProvider acima -- nenhum ContinueWatchingProvider em
        // lugar nenhum, igual a MaterialApp raiz de verdade (main.dart) +
        // HomeScreen (que só registra ContinueWatchingProvider dentro do
        // PRÓPRIO MultiProvider local, inacessível a rotas irmãs).
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<AuthProvider>(
                create: (_) => AuthProvider(
                  apiService: XtreamApiService(
                    dns: _testDns,
                    username: _testUser,
                    password: _testPass,
                    client: MockClient(_vodInfoHandler),
                  ),
                ),
              ),
              ChangeNotifierProvider<VodDetailsProvider>(create: (_) => VodDetailsProvider()),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const VodDetailsScreen(movie: _testMovie)),
                      ),
                      child: const Text('Abrir Filme'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Abrir Filme'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Assistir'));
        await tester.pump();

        // A PlayerScreen real não termina de montar em teste (precisa do
        // media_kit nativo, ver comentário em home_screen_dpad_test.dart
        // sobre "Continuar Assistindo") -- então uma exceção AQUI é
        // esperada. O que este teste garante é que NÃO é mais a
        // ProviderNotFoundException<ContinueWatchingProvider> (o bug real:
        // ela era lançada ANTES do Navigator.push acontecer, então o toque
        // no botão não fazia nada perceptível pro usuário).
        final thrown = tester.takeException();
        if (thrown != null) {
          expect(
            thrown.toString(),
            isNot(contains('ContinueWatchingProvider')),
            reason: 'Assistir não pode depender de um provider inacessível nesta tela',
          );
        }
      },
    );
  });

  group('Cache por vodId', () {
    testWidgets('reabrir o mesmo filme na mesma sessão não repete a chamada de rede', (tester) async {
      var callCount = 0;
      Future<http.Response> countingHandler(http.Request request) async {
        if (request.url.queryParameters['action'] == 'get_vod_info') callCount++;
        return _vodInfoHandler(request);
      }

      final vodDetailsProvider = VodDetailsProvider();
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
            ChangeNotifierProvider<VodDetailsProvider>.value(value: vodDetailsProvider),
          ],
          child: const MaterialApp(home: VodDetailsScreen(movie: _testMovie)),
        );
      }

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();
      expect(callCount, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      expect(callCount, 1, reason: 'esperava reaproveitar o cache em memória, sem nova chamada de rede');
      expect(find.text('Sinopse detalhada vinda da rede'), findsOneWidget);
    });
  });
}
