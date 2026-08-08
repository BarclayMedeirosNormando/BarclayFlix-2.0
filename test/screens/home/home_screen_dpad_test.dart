import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iptv_app/data/models/saved_profile.dart';
import 'package:iptv_app/data/models/watch_progress.dart';
import 'package:iptv_app/data/services/device_auth_service.dart';
import 'package:iptv_app/data/services/storage_service.dart';
import 'package:iptv_app/data/services/xtream_api_service.dart';
import 'package:iptv_app/providers/auth_provider.dart';
import 'package:iptv_app/providers/profiles_provider.dart';
import 'package:iptv_app/screens/activation/activation_screen.dart';
import 'package:iptv_app/screens/home/home_screen.dart';
import 'package:iptv_app/screens/player/player_screen.dart';
import 'package:iptv_app/screens/server_selection/server_selection_screen.dart';

import '../../test_helpers/fake_player.dart';

const _testDns = 'http://servidor-teste.com:8080';
const _testUser = 'cliente_teste';
const _testPass = 'senha_teste';

/// Dataset fixo usado por todos os testes deste arquivo:
/// - Live TV: 3 categorias ("Esportes", "Notícias", "Kids"), cada uma com 2 canais.
/// - VOD: 2 categorias ("Lançamentos", "Clássicos"), a categoria "10" com 13
///   filmes ("Filme 1".."Filme 13") — bastante folga acima do número de
///   colunas real do grid (AppCardSizes.posterGridDelegate, ~6 colunas na
///   largura de teste de 900px) pra garantir pelo menos uma segunda linha
///   completa mesmo que a densidade do grid mude de novo no futuro.
Future<http.Response> _xtreamHandler(http.Request request) async {
  final action = request.url.queryParameters['action'];
  final categoryId = request.url.queryParameters['category_id'];

  switch (action) {
    case null:
      // `login()` chama `_getJson({})`, sem `action` -- só relevante pros
      // testes do grupo "Trocar de servidor" (os demais testes deste
      // arquivo usam o seam `apiService:` do AuthProvider, que já entra
      // "autenticado" e nunca chama login() de verdade).
      return _json({
        'user_info': {'auth': 1, 'status': 'Active'},
        'server_info': {'url': 'servidor-teste.com', 'port': '8080'},
      });
    case 'get_live_categories':
      return _json([
        {'category_id': '1', 'category_name': 'Esportes', 'parent_id': 0},
        {'category_id': '2', 'category_name': 'Notícias', 'parent_id': 0},
        {'category_id': '3', 'category_name': 'Kids', 'parent_id': 0},
      ]);
    case 'get_live_streams':
      return _json([
        {'stream_id': 101, 'name': 'Canal A ($categoryId)', 'category_id': categoryId},
        {'stream_id': 102, 'name': 'Canal B ($categoryId)', 'category_id': categoryId},
      ]);
    case 'get_vod_categories':
      return _json([
        {'category_id': '10', 'category_name': 'Lançamentos', 'parent_id': 0},
        {'category_id': '11', 'category_name': 'Clássicos', 'parent_id': 0},
      ]);
    case 'get_vod_streams':
      return _json([
        for (var i = 1; i <= 13; i++)
          {
            'stream_id': 200 + i,
            'name': 'Filme $i',
            'category_id': categoryId,
            'container_extension': 'mp4',
            'rating': '0',
          },
      ]);
    case 'get_series_categories':
      return _json([
        {'category_id': '20', 'category_name': 'Séries', 'parent_id': 0},
      ]);
    case 'get_series':
      return _json(const []);
    default:
      return http.Response('Not Found', 404);
  }
}

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

/// Monta a HomeScreen com um [AuthProvider] já autenticado (via o seam
/// `apiService` — ver AuthProvider) apontando pro [_xtreamHandler] acima, e
/// com a janela larga o suficiente (>=700px) pra cair no layout
/// desktop/TV com sidebar fixa, que é o layout sob teste em toda a tarefa.
///
/// 900px (não mais largo) é proposital: com os 6 filmes fixos do dataset
/// acima, essa largura garante 2 linhas no grid (4 colunas), necessário
/// para testar navegação por linha/coluna. Confirmado empiricamente — em
/// 1400px as 6 colunas cabem numa linha só e não haveria uma "próxima
/// linha" pra descer.
/// [storageService], quando informado, entra como o `StorageService` do
/// [ProfilesProvider] montado junto com a HomeScreen -- necessário pro
/// botão "Reativar dispositivo" (ver `HomeScreen._reactivateDevice`), que
/// depende de `ProfilesProvider.clearSavedProfile()`, não só de
/// `AuthProvider.logout()`.
/// Devolve o [StorageService] usado, pra quem chamar poder inspecionar o que
/// sobrou salvo depois do teste (ex: confirmar que reativar limpou de
/// verdade, não só navegou pra ActivationScreen).
/// [deviceAuthHandler], quando informado, entra como o backend HTTP da
/// ativação de dispositivo (ver DeviceAuthService) -- necessário só pro
/// teste de "Trocar de servidor" (que dispara uma nova checagem de
/// ativação em segundo plano). Sem ele, o [AuthProvider] usa o
/// `DeviceAuthService()` padrão (rede de verdade), o que é aceitável pros
/// demais testes deste arquivo porque eles nunca disparam essa checagem.
Future<StorageService> pumpHomeScreen(
  WidgetTester tester, {
  Future<void> Function()? seedProgress,
  StorageService? storageService,
  Future<http.Response> Function(http.Request)? deviceAuthHandler,
}) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // Backend em memória do shared_preferences (progresso de "Continuar
  // Assistindo") — zerado a cada chamada; [seedProgress], se informado,
  // roda DEPOIS deste reset e ANTES do pumpWidget, pra popular progresso já
  // salvo sem correr o risco de ser apagado por este reset.
  SharedPreferences.setMockInitialValues({});
  await seedProgress?.call();

  // Só substitui o backend em memória quando NINGUÉM passou um
  // [storageService] pronto -- sobrescrever aqui sempre apagaria dados que o
  // chamador já tenha escrito ANTES de montar a tela (ver teste de logout
  // abaixo, que precisa de um perfil já salvo antes do pump).
  if (storageService == null) {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
  }
  final resolvedStorageService = storageService ?? StorageService(storage: const FlutterSecureStorage());

  final apiService = XtreamApiService(
    dns: _testDns,
    username: _testUser,
    password: _testPass,
    client: MockClient(_xtreamHandler),
  );

  await tester.pumpWidget(
    ChangeNotifierProvider<AuthProvider>(
      create: (_) => AuthProvider(
        apiService: apiService,
        deviceAuthService: deviceAuthHandler == null ? null : DeviceAuthService(client: MockClient(deviceAuthHandler)),
        xtreamHttpClient: deviceAuthHandler == null ? null : MockClient(_xtreamHandler),
      ),
      child: Builder(
        builder: (context) => ChangeNotifierProvider<ProfilesProvider>(
          create: (context) => ProfilesProvider(
            authProvider: context.read<AuthProvider>(),
            storageService: resolvedStorageService,
          ),
          child: const MaterialApp(home: HomeScreen()),
        ),
      ),
    ),
  );

  await tester.pumpAndSettle();
  return resolvedStorageService;
}

/// Ativa a aba VOD ("Filmes") e seleciona [categoryId], deixando o grid de
/// filmes carregado e pronto pra navegação.
Future<void> selectVodCategory(WidgetTester tester, String categoryId) async {
  await tester.tap(find.text('Filmes'));
  await tester.pumpAndSettle();

  final categoryName = categoryId == '10' ? 'Lançamentos' : 'Clássicos';
  await tester.tap(find.text(categoryName));
  await tester.pumpAndSettle();
}

/// [Focus.of] busca o FocusNode do ANCESTRAL mais próximo a partir do
/// contexto informado — por isso os finders usados aqui sempre apontam para
/// um `Text` (nome do item), que fica DENTRO do widget interativo
/// (ListTile/InkWell/ChoiceChip) que registra o FocusNode de verdade.
/// Confirmado como o padrão usado nos testes do próprio SDK do Flutter
/// (focus_traversal_test.dart).
bool isFocused(WidgetTester tester, Finder finder) {
  return Focus.of(tester.element(finder)).hasFocus;
}

void focusItem(WidgetTester tester, Finder finder) {
  Focus.of(tester.element(finder)).requestFocus();
}

/// Confirma que ALGUM nó de foco já está ativo assim que a tela abre, SEM
/// nenhuma chamada manual de `requestFocus()` (nem `focusItem` acima) —
/// essa é a condição real que faz o Escape/D-Pad funcionarem desde o
/// primeiro frame (ver `Focus(autofocus: true)` em home_screen.dart).
/// Localiza o `Focus` raiz da tela pelo `debugLabel` do seu `FocusNode`
/// (não por `autofocus`/`skipTraversal`: o próprio `Navigator` do Flutter
/// já cria um `Focus` interno com essa MESMA combinação de propriedades
/// para cada rota — achado rodando este teste, que por isso não pode
/// distinguir "nosso" nó do nó interno do framework só por elas).
bool _rootHasAutofocus(WidgetTester tester) {
  final finder = find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'home-screen-root');
  final focusNode = tester.widget<Focus>(finder).focusNode;
  return focusNode != null && focusNode.hasFocus;
}

void main() {
  group('Autofoco inicial (sem foco manual)', () {
    testWidgets('a tela já tem um nó de foco ativo assim que abre, sem nenhum requestFocus() manual', (tester) async {
      await pumpHomeScreen(tester);

      // Nenhum focusItem()/requestFocus() antes desta linha — é exatamente
      // essa ausência que reproduziria o bug relatado em dispositivo
      // físico (D-Pad sem efeito nenhum): sem autofoco, nada na árvore
      // teria foco de teclado pra receber a primeira seta ou o Escape.
      expect(_rootHasAutofocus(tester), isTrue);
    });

    testWidgets('a primeira categoria já fica focada sozinha, e a seta move pra próxima — tudo sem foco manual', (tester) async {
      await pumpHomeScreen(tester);

      // O salto automático do wrapper invisível pra primeira categoria já
      // aconteceu sozinho (ver `_handOffInitialFocusIfReady` em
      // home_screen.dart) — sem ele, nenhuma seta moveria o foco pra lugar
      // nenhum a partir daqui (achado empírico: busca DIRECIONAL, ao
      // contrário de `nextFocus`/Tab, não atravessa a fronteira de um nó
      // `skipTraversal` sozinha).
      expect(isFocused(tester, find.text('Esportes')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      expect(isFocused(tester, find.text('Notícias')), isTrue);
    });
  });

  group('Sidebar de categorias', () {
    testWidgets('seta para baixo move o foco sequencialmente entre os itens', (tester) async {
      await pumpHomeScreen(tester);

      focusItem(tester, find.text('Esportes'));
      await tester.pump();
      expect(isFocused(tester, find.text('Esportes')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(isFocused(tester, find.text('Notícias')), isTrue);
      expect(isFocused(tester, find.text('Esportes')), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(isFocused(tester, find.text('Kids')), isTrue);
      expect(isFocused(tester, find.text('Notícias')), isFalse);
    });
  });

  group('Sidebar <-> grid', () {
    testWidgets('seta direita no último item da sidebar move o foco pro primeiro item do grid', (tester) async {
      await pumpHomeScreen(tester);
      await selectVodCategory(tester, '11'); // "Clássicos" = última categoria da lista

      focusItem(tester, find.text('Clássicos'));
      await tester.pump();
      expect(isFocused(tester, find.text('Clássicos')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(isFocused(tester, find.text('Clássicos')), isFalse);
      expect(isFocused(tester, find.text('Filme 1')), isTrue);
    });

    testWidgets('seta esquerda na borda esquerda do grid volta o foco pra sidebar', (tester) async {
      await pumpHomeScreen(tester);
      await selectVodCategory(tester, '10');

      // "Filme 1" é o primeiro item do grid — coluna 0 garantidamente.
      focusItem(tester, find.text('Filme 1'));
      await tester.pump();
      expect(isFocused(tester, find.text('Filme 1')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(isFocused(tester, find.text('Filme 1')), isFalse);
      final onSidebar =
          isFocused(tester, find.text('Lançamentos')) || isFocused(tester, find.text('Clássicos'));
      expect(onSidebar, isTrue, reason: 'esperava o foco de volta em algum item da sidebar');
    });
  });

  group('Navegação dentro do grid', () {
    testWidgets('seta para baixo pula uma linha inteira (respeita colunas, não é sequencial)', (tester) async {
      await pumpHomeScreen(tester);
      await selectVodCategory(tester, '10');

      // Descobre empiricamente quantas colunas o grid tem nesta largura de
      // janela, em vez de presumir um número — робusto a mudanças de layout.
      final firstPos = tester.getTopLeft(find.text('Filme 1'));
      final secondPos = tester.getTopLeft(find.text('Filme 2'));
      final sameRow = (firstPos.dy - secondPos.dy).abs() < 1;

      expect(
        sameRow,
        isTrue,
        reason: 'este teste pressupõe >=2 colunas na largura de teste (900px); '
            'se falhar aqui, a densidade do grid mudou e o teste precisa ser revisto',
      );

      focusItem(tester, find.text('Filme 1'));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      // NÃO pode ser "Filme 2" (mesma linha, coluna seguinte) — isso
      // indicaria navegação sequencial de lista, não de grid 2D.
      expect(isFocused(tester, find.text('Filme 2')), isFalse);

      // Verifica dinamicamente qual filme recebeu o foco, em vez de
      // presumir um índice fixo -- robusto ao número real de colunas
      // (AppCardSizes.posterGridMaxExtent), que pode mudar no futuro sem
      // quebrar este teste.
      final focusedMovie = [for (var i = 2; i <= 13; i++) 'Filme $i']
          .where((name) => isFocused(tester, find.text(name)))
          .toList();
      expect(
        focusedMovie,
        hasLength(1),
        reason: 'esperava exatamente um filme da(s) próxima(s) linha(s) focado após ArrowDown',
      );

      // O item focado deve estar na MESMA coluna (mesmo X) que "Filme 1".
      final newPos = tester.getTopLeft(find.text(focusedMovie.single));
      expect((newPos.dx - firstPos.dx).abs(), lessThan(1));
      expect(newPos.dy, greaterThan(firstPos.dy));
    });
  });

  group('Ativação por teclado', () {
    testWidgets('Enter no item focado dispara a mesma ação do onTap (seleciona categoria)', (tester) async {
      await pumpHomeScreen(tester);

      focusItem(tester, find.text('Notícias'));
      await tester.pump();

      // Antes de ativar, os canais de "Notícias" ainda não foram pedidos.
      expect(find.text('Canal A (2)'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      // Sem pumpAndSettle: os canais de Live TV agora têm um badge "ao
      // vivo" com animação em loop (Bloco 3) que nunca converge — mesma
      // razão documentada nos testes da PlayerScreen mais abaixo neste
      // arquivo (buffering indeterminado). Uns poucos pumps bastam pra
      // deixar a requisição (MockClient) e o rebuild resultante assentarem.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Mesmo efeito de tocar no ListTile: a categoria "2" (Notícias) foi
      // selecionada e seus canais carregados — prova que o Enter chamou o
      // mesmíssimo onTap, não uma lógica duplicada.
      expect(find.text('Canal A (2)'), findsOneWidget);
      expect(find.text('Canal B (2)'), findsOneWidget);
    });

    testWidgets('abas são navegáveis por seta e ativáveis via Enter, trocando o conteúdo', (tester) async {
      await pumpHomeScreen(tester);

      // Sidebar de Live TV visível, VOD ainda não.
      expect(find.text('Esportes'), findsOneWidget);
      expect(find.text('Lançamentos'), findsNothing);

      focusItem(tester, find.text('Live TV'));
      await tester.pump();
      expect(isFocused(tester, find.text('Live TV')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(isFocused(tester, find.text('Filmes')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Lançamentos'), findsOneWidget);
    });
  });

  group('Voltar/Escape na raiz', () {
    testWidgets('Escape na HomeScreen abre o diálogo de confirmação de saída', (tester) async {
      await pumpHomeScreen(tester);

      expect(find.text('Sair do app?'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('Sair do app?'), findsOneWidget);
      expect(find.text('Tem certeza que deseja sair do BarclayFlix 2.0?'), findsOneWidget);

      // Fecha o diálogo tocando "Cancelar" pra não deixar estado pendente.
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.text('Sair do app?'), findsNothing);
    });
  });

  group('Preservação de foco (HomeScreen <-> Player)', () {
    testWidgets(
      'volta com o foco exatamente no item que estava focado antes de abrir o Player',
      (tester) async {
        await pumpHomeScreen(tester);
        await selectVodCategory(tester, '10');

        // De propósito o 3º filme, não o primeiro — pra não confundir com
        // "focou o topo por acaso"/reset para o início da lista.
        focusItem(tester, find.text('Filme 3'));
        await tester.pump();
        expect(isFocused(tester, find.text('Filme 3')), isTrue);

        // Empilha a mesma PlayerScreen real que _playMovie usaria, só que
        // com o PlayerProvider fake injetado (ver test_helpers/fake_player.dart)
        // — _playMovie em si sempre cria um PlayerProvider real (sem esse
        // seam, de propósito: não é código pensado pra teste), então não dá
        // pra disparar a navegação real aqui sem tentar carregar o media_kit
        // nativo. O que este teste valida — preservação de foco via
        // Navigator/FocusScope ao empilhar e desempilhar uma rota — é
        // idêntico não importa como a rota chegou lá.
        final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
        navigator.push(
          MaterialPageRoute(
            builder: (_) => PlayerScreen(
              url: 'http://servidor-teste.com:8080/movie/u/p/203.mp4',
              title: 'Filme 3',
              playerProvider: buildFakePlayerProvider().provider,
            ),
          ),
        );
        // Não dá pra usar pumpAndSettle aqui: assim que o PlayerProvider
        // abre a URL (mesmo fake), o status vira "buffering" e a
        // PlayerScreen mostra um CircularProgressIndicator indeterminado,
        // cuja animação nunca converge — pumpAndSettle ficaria esperando pra
        // sempre (descoberto rodando o teste; era `pumpAndSettle timed out`
        // antes desta troca). Uns poucos pumps com duração explícita bastam
        // pra estabilizar as transições (AnimatedOpacity/AnimatedContainer).
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byType(PlayerScreen), findsOneWidget);
        expect(find.text('Filme 3'), findsWidgets); // aparece também no título do player
        // HomeScreen continua MONTADA (MaterialPageRoute.maintainState é true
        // por padrão) — só fica coberta/sem hit-test. É exatamente essa
        // persistência que permite o foco sobreviver ao push/pop.
        expect(find.byType(HomeScreen), findsOneWidget);

        navigator.pop();
        await tester.pump();
        // A transição de saída do MaterialPageRoute (~300ms) some ANTES do
        // PlayerScreen ser de fato removido da árvore — sem essa folga, o
        // finder ainda encontrava a PlayerScreen a caminho de sumir.
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byType(PlayerScreen), findsNothing);
        expect(isFocused(tester, find.text('Filme 3')), isTrue);
      },
    );
  });

  group('Continuar Assistindo', () {
    WatchProgress buildProgress({
      String contentId = 'movie-1',
      String title = 'Filme Assistido',
      int positionSeconds = 300,
      int durationSeconds = 3600,
    }) {
      return WatchProgress(
        contentId: contentId,
        title: title,
        imageUrl: '',
        positionSeconds: positionSeconds,
        durationSeconds: durationSeconds,
        type: WatchProgressType.vod,
        playbackUrl: '$_testDns/movie/$_testUser/$_testPass/$contentId.mp4',
        lastWatchedAt: DateTime(2025, 1, 1),
      );
    }

    testWidgets('a aba "Continuar" sempre existe na TabBar, mesmo sem nada assistido (não oculta a aba inteira)', (
      tester,
    ) async {
      await pumpHomeScreen(tester);

      expect(find.text('Continuar'), findsOneWidget);

      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Nada assistido ainda'), findsOneWidget);
    });

    testWidgets('com progresso salvo, a aba "Continuar" mostra o card do item assistido', (tester) async {
      await pumpHomeScreen(
        tester,
        seedProgress: () => StorageService().saveProgress(buildProgress()),
      );

      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();

      expect(find.text('Filme Assistido'), findsOneWidget);
    });

    // Não há teste aqui de "tocar no card navega com startAtSeconds
    // correto" fim-a-fim: fazer isso exigiria montar uma PlayerScreen real
    // (sem playerProvider fake injetado), o que dispara
    // "MediaKit.ensureInitialized must be called" (nunca chamado neste
    // binário de teste) e vaza exceções assíncronas pra fora da janela do
    // teste — problema de infraestrutura pré-existente, não deste bloco.
    // A ligação HomeScreen -> PlayerScreen (contentId/startAtSeconds/tipo)
    // é um repasse de poucas linhas em _playContinueWatching, e o
    // comportamento de retomar na posição salva já está coberto em
    // player_provider_test.dart ("startAtSeconds faz seek...").
  });

  group('Reativar dispositivo', () {
    testWidgets('toca no botão, confirma o diálogo: limpa o perfil salvo e volta pra ActivationScreen', (tester) async {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
      final storageService = StorageService(storage: const FlutterSecureStorage());
      await storageService.addProfile(const SavedProfile(
        id: 'p1',
        nomeExibicao: 'Servidor Salvo',
        xtreamUsername: _testUser,
        xtreamPassword: _testPass,
        dns: _testDns,
      ));

      await pumpHomeScreen(tester, storageService: storageService);
      expect(await storageService.getSavedProfiles(), hasLength(1));

      await tester.tap(find.widgetWithIcon(IconButton, Icons.restart_alt));
      await tester.pumpAndSettle();

      expect(find.text('Reativar dispositivo?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Reativar'));
      await tester.pumpAndSettle();

      expect(find.byType(ActivationScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(
        await storageService.getSavedProfiles(),
        isEmpty,
        reason: 'sem isso a SplashScreen revalidaria o mesmo cliente de novo na próxima abertura do app',
      );
    });

    testWidgets('toca no botão, cancela o diálogo: nada muda, continua na HomeScreen', (tester) async {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
      final storageService = StorageService(storage: const FlutterSecureStorage());
      await storageService.addProfile(const SavedProfile(
        id: 'p1',
        nomeExibicao: 'Servidor Salvo',
        xtreamUsername: _testUser,
        xtreamPassword: _testPass,
        dns: _testDns,
      ));

      await pumpHomeScreen(tester, storageService: storageService);

      await tester.tap(find.widgetWithIcon(IconButton, Icons.restart_alt));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(await storageService.getSavedProfiles(), hasLength(1));
    });
  });

  group('Trocar de servidor', () {
    Future<http.Response> deviceAuthHandlerFn(http.Request request) async {
      return http.Response(
        jsonEncode({
          'status': 'ok',
          'nomeCliente': 'Cliente Teste',
          'servidores': [
            {'nome': 'TVPLAY', 'dns': 'http://tvplay.example:8080', 'username': 'u_tvplay', 'password': 'p_tvplay'},
            {'nome': 'P2BRAS', 'dns': 'http://p2bras.example:8080', 'username': 'u_p2bras', 'password': 'p_p2bras'},
          ],
        }),
        200,
      );
    }

    testWidgets(
      'toca em "Trocar de servidor": rebusca a lista pela ativação deste dispositivo (sem pedir nenhum input) e abre a ServerSelectionScreen',
      (tester) async {
        FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
        final storageService = StorageService(storage: const FlutterSecureStorage());
        await storageService.addProfile(const SavedProfile(
          id: 'p1',
          nomeExibicao: 'Servidor Atual',
          xtreamUsername: _testUser,
          xtreamPassword: _testPass,
          dns: _testDns,
        ));

        await pumpHomeScreen(tester, storageService: storageService, deviceAuthHandler: deviceAuthHandlerFn);
        final providerContext = tester.element(find.byType(HomeScreen));
        await Provider.of<ProfilesProvider>(providerContext, listen: false).loadProfiles();
        await tester.pump();

        await tester.tap(find.widgetWithIcon(IconButton, Icons.swap_horiz));
        await tester.pumpAndSettle();

        expect(find.byType(ServerSelectionScreen), findsOneWidget);
        expect(find.byType(ActivationScreen), findsNothing, reason: 'nunca deve pedir ativação de novo');
        expect(find.text('TVPLAY'), findsOneWidget);
        expect(find.text('P2BRAS'), findsOneWidget);
        // Nada foi apagado/alterado ainda -- só a re-busca aconteceu (só ao
        // ESCOLHER um servidor o perfil salvo muda).
        final stillSaved = await storageService.getSavedProfiles();
        expect(stillSaved, hasLength(1));
        expect(stillSaved.single.dns, _testDns, reason: 'servidor ativo não muda até uma escolha ser confirmada');
      },
    );

    testWidgets('escolher um novo servidor ATUALIZA o mesmo perfil salvo (mesmo id), não duplica', (tester) async {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
      final storageService = StorageService(storage: const FlutterSecureStorage());
      await storageService.addProfile(const SavedProfile(
        id: 'p1',
        nomeExibicao: 'Servidor Atual',
        xtreamUsername: _testUser,
        xtreamPassword: _testPass,
        dns: _testDns,
      ));

      await pumpHomeScreen(tester, storageService: storageService, deviceAuthHandler: deviceAuthHandlerFn);
      final providerContext = tester.element(find.byType(HomeScreen));
      await Provider.of<ProfilesProvider>(providerContext, listen: false).loadProfiles();
      await tester.pump();

      await tester.tap(find.widgetWithIcon(IconButton, Icons.swap_horiz));
      await tester.pumpAndSettle();

      await tester.tap(find.text('P2BRAS'));
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(ServerSelectionScreen), findsNothing);

      final updated = await storageService.getSavedProfiles();
      expect(updated, hasLength(1), reason: 'atualiza o perfil existente, não duplica');
      expect(updated.single.id, 'p1');
      expect(updated.single.dns, 'http://p2bras.example:8080');
      expect(updated.single.xtreamUsername, 'u_p2bras');
    });
  });
}
