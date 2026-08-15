import 'dart:async';
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
import 'package:iptv_app/providers/settings_provider.dart';
import 'package:iptv_app/providers/vod_details_provider.dart';
import 'package:iptv_app/screens/activation/activation_screen.dart';
import 'package:iptv_app/screens/home/home_screen.dart';
import 'package:iptv_app/screens/player/player_screen.dart';
import 'package:iptv_app/screens/server_selection/server_selection_screen.dart';
import 'package:iptv_app/screens/settings/settings_screen.dart';
import 'package:iptv_app/screens/vod_details/vod_details_screen.dart';
import 'package:iptv_app/widgets/section_sidebar.dart';

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
/// - Séries: 1 categoria ("Dramas"), com 2 séries ("Série A", "Série B") —
///   só o bastante pra testar a categoria "Todos" e a busca local (ver
///   grupo "Séries: categoria 'Todos' e busca inline local" abaixo).
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
        // Único canal com tag de qualidade no nome deste dataset -- usado
        // pelo grupo "Live TV: Todos/busca/card de qualidade" abaixo pra
        // provar que só ELE vira card com QualityBadge, os outros dois
        // continuam na lista simples (ver home_screen.dart._LiveStreamsPanel).
        {'stream_id': 103, 'name': 'Canal C ($categoryId) FHD', 'category_id': categoryId},
      ]);
    case 'get_short_epg':
      // Só "Canal A" (stream_id 101) tem EPG no dataset -- "Canal B" fica
      // sem, prova que a ausência (painel sem suporte/erro) não impede a
      // linha dela de aparecer normalmente (ver home_screen.dart._EpgSubtitle).
      if (request.url.queryParameters['stream_id'] != '101') {
        return http.Response('Not Found', 404);
      }
      return _json({
        'epg_listings': [
          {
            'title': base64Encode(utf8.encode('Jornal da Noite')),
            'start_timestamp': '1690000000',
            'stop_timestamp': '1690003600',
          },
          {
            'title': base64Encode(utf8.encode('Filme da Madrugada')),
            'start_timestamp': '1690003600',
            'stop_timestamp': '1690010800',
          },
        ],
      });
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
            // Categoria específica pedida (nenhuma mudança pros testes que
            // já selecionam '10'/'11' direto): quando "Todos" é buscado
            // (sem category_id, ver ContentProvider.allCategoriesId), o
            // painel real devolveria a categoria VERDADEIRA de cada item --
            // aqui simulada dividindo os 13 filmes entre as duas categorias
            // reais, necessário pro teste de bloqueio por PIN abaixo (ver
            // grupo "Configurações e bloqueio por PIN").
            'category_id': categoryId ?? (i <= 10 ? '10' : '11'),
            'container_extension': 'mp4',
            // "Filme 4" é o único com nota alta -- vira o destaque
            // (_FeaturedBanner, ver home_screen.dart._VodGrid), então
            // aparece duas vezes na árvore (banner + grid). Deliberadamente
            // NÃO é "Filme 1/2/3" -- esses três são usados em várias
            // asserções `find.text(...)` abaixo que esperam exatamente UM
            // widget; com nota igual (0) entre eles, nenhum vira destaque.
            'rating': i == 4 ? '9.5' : '0',
            // "Filme 1" é o único "adicionado" dentro da janela do NewBadge
            // (ver home_screen.dart._newBadgeWindow) -- "Filme 2" fica bem
            // fora dela, prova que o selo não aparece pra qualquer `added`,
            // só pro recente. Os demais (sem 'added') seguem o padrão de
            // painéis que não reportam essa data.
            if (i == 1)
              'added': (DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000).toString()
            else if (i == 2)
              'added': (DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000).toString(),
          },
      ]);
    case 'get_series_categories':
      // "Dramas" (não "Séries") de propósito -- o rótulo da ABA já é
      // "Séries" (ver TabBar em home_screen.dart), então uma categoria com
      // o mesmo nome tornaria `find.text('Séries')` ambíguo (aba x chip de
      // categoria) nos testes abaixo.
      return _json([
        {'category_id': '20', 'category_name': 'Dramas', 'parent_id': 0},
      ]);
    case 'get_vod_info':
      return _json({
        'info': {'plot': 'Sinopse de teste', 'rating': '0'},
        'movie_data': {},
      });
    case 'get_series':
      return _json([
        {'series_id': 1, 'name': 'Série A', 'category_id': categoryId, 'rating': '0'},
        {'series_id': 2, 'name': 'Série B', 'category_id': categoryId, 'rating': '0'},
        // Nota alta de propósito -- vira o destaque (_FeaturedBanner, ver
        // home_screen.dart._SeriesGrid), então aparece duas vezes na árvore
        // (banner + grid). "Série A"/"Série B" (não esta) são as duas
        // usadas nas asserções `find.text(...)` abaixo que esperam
        // exatamente UM widget.
        {'series_id': 3, 'name': 'Série C', 'category_id': categoryId, 'rating': '9.5'},
      ]);
    default:
      return http.Response('Not Found', 404);
  }
}

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

/// Substituto de `tester.pumpAndSettle()` usado NESTE ARQUIVO INTEIRO desde
/// o ajuste de UI que seleciona a categoria "Todos" por padrão na Live TV
/// (ver ContentProvider._loadLiveCategories): a partir dele, HomeScreen
/// sempre tem pelo menos um canal real visível assim que monta -- e o
/// badge "ao vivo" de cada canal da lista (_LivePulseBadge) anima em loop
/// infinito (`repeat(reverse: true)`), que nunca converge sozinho.
/// `pumpAndSettle()` ficaria esperando pra sempre a partir daí (mesmo
/// problema já documentado nos testes de "Preservação de foco"/PlayerScreen
/// mais abaixo, agora válido pro arquivo inteiro, já que a TabBarView
/// mantém a aba Live TV viva -- e a animação rodando -- mesmo com outra aba
/// em primeiro plano). Uns poucos pumps com duração explícita bastam pra
/// deixar requisições (MockClient) e transições reais (diálogos, troca de
/// aba) assentarem, sem depender de uma animação indeterminada convergir.
Future<void> pumpSettled(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1000));
}

/// Monta a HomeScreen com um [AuthProvider] já autenticado (via o seam
/// `apiService` — ver AuthProvider) apontando pro [_xtreamHandler] acima, e
/// com a janela larga o suficiente pra cair no layout desktop/TV: menu
/// lateral fixo (`SectionSidebar`, `sectionSidebarWidth = 220`) + dentro de
/// cada seção, a sidebar de categorias (`_sidebarBreakpoint = 700`, ver
/// home_screen.dart) em vez de chips horizontais.
///
/// 1100px (não 900px como antes do menu lateral existir) é proposital: o
/// `LayoutBuilder` de `_ContentTabView` decide sidebar-vs-chips a partir da
/// largura que SOBRA depois do `SectionSidebar` (220px) + divisor (1px), não
/// da largura total da janela — em 900px, sobrariam só ~679px pra
/// `_ContentTabView`, abaixo do próprio breakpoint de 700px que ele usa
/// internamente, fazendo a categoria virar chips por engano (achado
/// empírico corrigindo os testes deste arquivo pro menu lateral). 1100px
/// garante ~879px de sobra, folga confortável acima do breakpoint. Com os
/// 13 filmes fixos do dataset acima, essa largura ainda garante pelo menos
/// 2 linhas no grid — os testes de navegação descobrem o número real de
/// colunas empiricamente (ver `firstPos`/`secondPos` mais abaixo), não
/// presumem um valor fixo.
/// [storageService], quando informado, entra como o `StorageService` do
/// [ProfilesProvider] montado junto com a HomeScreen.
/// Devolve o [StorageService] usado, pra quem chamar poder inspecionar o que
/// sobrou salvo depois do teste.
/// [deviceAuthHandler], quando informado, entra como o backend HTTP da
/// ativação de dispositivo (ver DeviceAuthService) -- necessário só pro
/// teste de "Trocar de servidor" (que dispara uma nova checagem de
/// ativação em segundo plano). Sem ele, o [AuthProvider] usa o
/// `DeviceAuthService()` padrão (rede de verdade), o que é aceitável pros
/// demais testes deste arquivo porque eles nunca disparam essa checagem.
/// [size], quando informado, sobrescreve a largura larga (1100x900) padrão
/// -- usado pelo grupo "Layout estreito (mobile)" abaixo pra cair no
/// BottomNavigationBar em vez do SectionSidebar (mesmo corte de
/// `_sidebarBreakpoint`, ver home_screen.dart).
/// [xtreamHandler], quando informado, substitui [_xtreamHandler] como
/// backend da API Xtream -- usado pelo grupo "Foco: seção ainda carregando"
/// abaixo pra simular uma resposta de rede atrasada (ver
/// `_delayedVodCategoriesHandler`).
Future<StorageService> pumpHomeScreen(
  WidgetTester tester, {
  Future<void> Function()? seedProgress,
  StorageService? storageService,
  Future<http.Response> Function(http.Request)? deviceAuthHandler,
  Future<http.Response> Function(http.Request)? xtreamHandler,
  Size size = const Size(1100, 900),
}) async {
  tester.view.physicalSize = size;
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
    client: MockClient(xtreamHandler ?? _xtreamHandler),
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
          // Registrado no mesmo nível de main.dart (acima da HomeScreen,
          // não dentro do MultiProvider dela) -- VodDetailsScreen (empurrada
          // por cima ao tocar um filme, ver HomeScreen._openVodDetails)
          // depende deste provider existir como ancestral.
          child: ChangeNotifierProvider<VodDetailsProvider>(
            create: (_) => VodDetailsProvider(),
            // Mesmo StorageService (secure storage mockado) usado pelos
            // perfis acima -- PIN/categorias protegidas usam o mesmo
            // backend (ver StorageService.getPin/getProtectedCategoryIds).
            child: ChangeNotifierProvider<SettingsProvider>(
              create: (_) => SettingsProvider(storageService: resolvedStorageService)..load(),
              child: const MaterialApp(home: HomeScreen()),
            ),
          ),
        ),
      ),
    ),
  );

  await pumpSettled(tester);
  return resolvedStorageService;
}

/// Ativa a aba VOD ("Filmes") e seleciona [categoryId], deixando o grid de
/// filmes carregado e pronto pra navegação.
Future<void> selectVodCategory(WidgetTester tester, String categoryId) async {
  await tester.tap(find.text('Filmes'));
  await pumpSettled(tester);

  final categoryName = categoryId == '10' ? 'Lançamentos' : 'Clássicos';
  await tester.tap(find.text(categoryName));
  await pumpSettled(tester);
}

/// [Focus.of] busca o FocusNode do ANCESTRAL mais próximo a partir do
/// contexto informado — por isso os finders usados aqui sempre apontam para
/// um `Text` (nome do item), que fica DENTRO do widget interativo
/// (ListTile/InkWell/ChoiceChip) que registra o FocusNode de verdade.
/// Confirmado como o padrão usado nos testes do próprio SDK do Flutter
/// (focus_traversal_test.dart).
/// `.any` (não `tester.element`/`.single`) de propósito: o título de um
/// item em destaque (_FeaturedBanner, ver home_screen.dart._VodGrid/
/// _SeriesGrid) repete o MESMO texto do card dele no grid logo abaixo --
/// `find.text(name)` pode legitimamente casar 2 widgets agora. "Focado" aqui
/// significa "pelo menos uma das ocorrências está focada".
bool isFocused(WidgetTester tester, Finder finder) {
  return tester.elementList(finder).any((element) => Focus.of(element).hasFocus);
}

void focusItem(WidgetTester tester, Finder finder) {
  Focus.of(tester.element(finder)).requestFocus();
}

/// Restringe [matching] à aba de conteúdo [tabName] ("live"/"vod"/"series",
/// ver `HomeScreen._ContentTabView`'s `ValueKey('${type.name}_content_tab')`)
/// — necessário pra finders "genéricos" (`find.byIcon(Icons.search)`,
/// `find.text('Todos')`, `find.byType(TextField)`...) que hoje aparecem em
/// TRÊS abas ao mesmo tempo: a `TabBarView` não descarta uma aba já visitada
/// ao trocar pra outra (mesma razão documentada em [pumpSettled] pro badge
/// "ao vivo" da Live TV continuar animando fora de tela) -- sem esse escopo,
/// visitar mais de uma aba na mesma sessão de teste faria esses finders
/// encontrarem mais de um widget e o teste falhar por ambiguidade, não por
/// um bug de verdade.
Finder inTab(String tabName, Finder matching) {
  return find.descendant(
    of: find.byKey(ValueKey('${tabName}_content_tab')),
    matching: matching,
  );
}

/// `find.text(data)` também combina com o conteúdo digitado num
/// `TextField`/`EditableText` (ver `CommonFinders.text`) -- então buscar
/// exatamente pelo texto que acabou de ser digitado no campo de busca (ex:
/// digitar "Filme 3" e depois checar `find.text('Filme 3')`) encontra o
/// próprio campo além do item de verdade. Este finder restringe a um
/// widget `Text` propriamente dito, ignorando o campo de busca.
Finder textWidget(String data) {
  return find.byWidgetPredicate((widget) => widget is Text && widget.data == data);
}

void main() {
  group('Autofoco inicial (sem foco manual)', () {
    testWidgets('o item ativo do menu lateral (TV Ao Vivo) já fica focado sozinho, sem nenhum requestFocus() manual', (tester) async {
      await pumpHomeScreen(tester);

      // Nenhum focusItem()/requestFocus() antes desta linha — é exatamente
      // essa ausência que reproduziria o bug relatado em dispositivo físico
      // (D-Pad sem efeito nenhum): sem autofoco, nada na árvore teria foco
      // de teclado pra receber a primeira seta ou o Escape. Substitui o
      // hack antigo de `_rootFocusNode` (aposentado neste redesign, ver
      // home_screen.dart) -- o item concreto do menu já existe desde o 1º
      // frame, sem depender de categorias chegarem da rede.
      expect(isFocused(tester, find.text('TV Ao Vivo')), isTrue);
    });

    testWidgets('seta direita a partir do menu entra na sidebar de categorias da seção ativa (Live TV)', (tester) async {
      await pumpHomeScreen(tester);
      expect(isFocused(tester, find.text('TV Ao Vivo')), isTrue);

      // Fronteira de escopo GENUINAMENTE NOVA deste redesign (menu lateral
      // isolado do conteúdo via FocusScope, ver `_sectionSidebarScope`/
      // `_BoundaryDirectionalFocusAction` em home_screen.dart) -- sem a
      // travessia manual implementada lá, esta seta não moveria o foco pra
      // lugar nenhum (o FocusScope do menu não teria mais nenhum candidato
      // à direita dentro de si mesmo).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      // "Todos" (categoria sintética, ver ContentProvider.allLiveCategoriesId)
      // é sempre a PRIMEIRA opção em Live TV -- é ela quem recebe o foco ao
      // entrar no conteúdo pela primeira vez (nenhum item foi focado antes,
      // então `FocusScopeNode.requestFocus()` cai no primeiro descendente
      // focável, não num `focusedChild` lembrado).
      expect(isFocused(tester, find.text('Todos')), isTrue);
      expect(isFocused(tester, find.text('TV Ao Vivo')), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(isFocused(tester, find.text('Esportes')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(isFocused(tester, find.text('Notícias')), isTrue);
    });

    testWidgets('seta esquerda na sidebar de categorias devolve o foco pro item ativo do menu', (tester) async {
      await pumpHomeScreen(tester);

      focusItem(tester, find.text('Esportes'));
      await tester.pump();
      expect(isFocused(tester, find.text('Esportes')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(isFocused(tester, find.text('Esportes')), isFalse);
      expect(isFocused(tester, find.text('TV Ao Vivo')), isTrue, reason: 'esperava o foco de volta no item ativo do menu');
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
    testWidgets('seta direita no último item da sidebar move o foco pro banner de destaque; seta para baixo alcança o grid',
        (tester) async {
      await pumpHomeScreen(tester);
      await selectVodCategory(tester, '11'); // "Clássicos" = última categoria da lista

      focusItem(tester, find.text('Clássicos'));
      await tester.pump();
      expect(isFocused(tester, find.text('Clássicos')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(isFocused(tester, find.text('Clássicos')), isFalse);
      // Com o _FeaturedBanner ocupando o topo da área de conteúdo (mesma UX
      // de app de streaming: destaque antes do grid), "seta direita" a
      // partir da sidebar pousa NELE primeiro -- "Assistir" só existe
      // dentro do banner, prova que é ele (e não algum card do grid).
      expect(isFocused(tester, find.text('Assistir')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      // "Seta para baixo" a partir do banner (que ocupa a largura inteira)
      // pousa no card geometricamente mais próximo do grid abaixo -- não
      // necessariamente "Filme 1" (a primeira coluna), então descobre
      // dinamicamente qual, mesmo padrão do grupo "Navegação dentro do
      // grid" abaixo, em vez de presumir um índice fixo.
      expect(isFocused(tester, find.text('Assistir')), isFalse);
      final focusedMovie =
          [for (var i = 1; i <= 13; i++) 'Filme $i'].where((name) => isFocused(tester, find.text(name))).toList();
      expect(focusedMovie, hasLength(1), reason: 'esperava exatamente um filme do grid focado após ArrowDown');
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
      await pumpSettled(tester);

      // Mesmo efeito de tocar no ListTile: a categoria "2" (Notícias) foi
      // selecionada e seus canais carregados — prova que o Enter chamou o
      // mesmíssimo onTap, não uma lógica duplicada.
      expect(find.text('Canal A (2)'), findsOneWidget);
      expect(find.text('Canal B (2)'), findsOneWidget);
    });

    testWidgets('itens do menu lateral são navegáveis por seta e ativáveis via Enter, trocando a seção', (tester) async {
      await pumpHomeScreen(tester);

      // Sidebar de categorias de Live TV visível, VOD ainda não -- prova
      // que a seção só troca de verdade DEPOIS do Enter, não já na seta.
      expect(find.text('Esportes'), findsOneWidget);
      expect(find.text('Lançamentos'), findsNothing);

      expect(isFocused(tester, find.text('TV Ao Vivo')), isTrue);

      // Itens do menu ficam empilhados verticalmente (ver SectionSidebar) --
      // seta PRA BAIXO (não pra direita, que sairia do menu, ver grupo
      // "Autofoco inicial") move entre eles.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(isFocused(tester, find.text('Filmes')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpSettled(tester);

      expect(find.text('Lançamentos'), findsOneWidget);

      // [TESTE] Caso básico que faltava cobrir explicitamente: SEM nenhum
      // atraso de rede artificial (categorias já carregadas de verdade,
      // igual reportado pelo usuário testando no Windows -- "clica e
      // entra, porém não movimenta"), a seta direita logo em seguida
      // precisa entrar na coluna de categorias normalmente, mesmo
      // mecanismo que já funciona pra Live TV.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(isFocused(tester, find.text('Todos')), isTrue);
      expect(isFocused(tester, find.text('Filmes')), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(isFocused(tester, find.text('Lançamentos')), isTrue);

      // [TESTE] Bug real (relatado testando no Windows: "se eu iniciar por
      // Filmes, Filmes funciona e o resto não") -- `_contentScope` é
      // compartilhado por TODAS as seções (todas montadas ao mesmo tempo
      // dentro do IndexedStack). `focusedChild` guardava o último item
      // focado (aqui, "Lançamentos" de Filmes) mesmo depois da seção dele
      // ser excluída (`ExcludeFocus`) ao trocar pra outra -- `_enterContent`
      // tentava reaproveitar esse item ANTIGO/escondido, uma chamada de
      // `requestFocus()` que falha em silêncio, nunca focando a seção
      // NOVA de verdade. Sai de Filmes de volta pro menu e troca pra
      // Séries -- precisa navegar ali igualzinho a Filmes, não travar.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(isFocused(tester, find.text('Filmes')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(isFocused(tester, find.text('Séries')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpSettled(tester);
      expect(find.text('Dramas'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(isFocused(tester, find.text('Todos')), isTrue, reason: 'precisa entrar na coluna de categorias de Séries, não ficar preso');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(isFocused(tester, find.text('Dramas')), isTrue, reason: 'precisa MOVER dentro de Séries, não travar parado');
    });
  });

  group('Voltar/Escape na raiz', () {
    testWidgets('Escape na HomeScreen abre o diálogo de confirmação de saída', (tester) async {
      await pumpHomeScreen(tester);

      expect(find.text('Sair do app?'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpSettled(tester);

      expect(find.text('Sair do app?'), findsOneWidget);
      expect(find.text('Tem certeza que deseja sair do BarclayFlix 2.0?'), findsOneWidget);

      // Fecha o diálogo tocando "Cancelar" pra não deixar estado pendente.
      await tester.tap(find.text('Cancelar'));
      await pumpSettled(tester);
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

        // Empilha a mesma PlayerScreen real que VodDetailsScreen._play
        // usaria, só que com o PlayerProvider fake injetado (ver
        // test_helpers/fake_player.dart) — a rota real sempre cria um
        // PlayerProvider de verdade (sem esse seam, de propósito: não é
        // código pensado pra teste), então não dá pra disparar a navegação
        // real aqui sem tentar carregar o media_kit nativo. O que este
        // teste valida — preservação de foco via Navigator/FocusScope ao
        // empilhar e desempilhar uma rota — é idêntico não importa como a
        // rota chegou lá (direto da Home ou via VodDetailsScreen).
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

    testWidgets('o item "Continuar Assistindo" sempre existe no menu, mesmo sem nada assistido (não some sozinho)', (
      tester,
    ) async {
      await pumpHomeScreen(tester);

      expect(find.text('Continuar Assistindo'), findsOneWidget);

      await tester.tap(find.text('Continuar Assistindo'));
      await pumpSettled(tester);

      expect(find.textContaining('Nada assistido ainda'), findsOneWidget);
    });

    testWidgets('com progresso salvo, a seção "Continuar Assistindo" mostra o card do item assistido', (tester) async {
      await pumpHomeScreen(
        tester,
        seedProgress: () => StorageService().saveProgress(buildProgress()),
      );

      await tester.tap(find.text('Continuar Assistindo'));
      await pumpSettled(tester);

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

        await tester.tap(find.text('Trocar servidor'));
        await pumpSettled(tester);

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

      await tester.tap(find.text('Trocar servidor'));
      await pumpSettled(tester);

      await tester.tap(find.text('P2BRAS'));
      await pumpSettled(tester);

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(ServerSelectionScreen), findsNothing);

      final updated = await storageService.getSavedProfiles();
      expect(updated, hasLength(1), reason: 'atualiza o perfil existente, não duplica');
      expect(updated.single.id, 'p1');
      expect(updated.single.dns, 'http://p2bras.example:8080');
      expect(updated.single.xtreamUsername, 'u_p2bras');
    });
  });

  group('Live TV: categoria "Todos" e busca inline local', () {
    testWidgets(
      '"Todos" já vem selecionada ao abrir a tela: mostra os canais de TODAS as categorias, sem nenhum toque',
      (tester) async {
        await pumpHomeScreen(tester);

        // Sem tocar em nenhuma categoria -- "Todos" (categoria sintética,
        // primeira da lista, ver ContentProvider.allLiveCategoriesId) já foi
        // selecionada automaticamente e os canais já apareceram.
        expect(find.text('Todos'), findsOneWidget);
        expect(find.textContaining('Canal A'), findsOneWidget);
        expect(find.textContaining('Canal B'), findsOneWidget);
        expect(find.textContaining('Canal C'), findsOneWidget);
      },
    );

    testWidgets(
      'canal com tag de qualidade no nome vira card com QualityBadge; os demais continuam na lista',
      (tester) async {
        await pumpHomeScreen(tester);

        // "Canal C (...) FHD" é o único com tag reconhecida no dataset (ver
        // _xtreamHandler) -- só ele ganha o selo "FHD".
        expect(find.text('FHD'), findsOneWidget);
        expect(find.textContaining('Canal C'), findsOneWidget);

        // Canal A/B não têm tag no nome -- nenhum selo de qualidade pra eles.
        expect(find.text('HD'), findsNothing);
        expect(find.text('SD'), findsNothing);
      },
    );

    testWidgets(
      'lupa expande um campo de busca inline (nunca tela nova/overlay) e filtra os canais localmente',
      (tester) async {
        await pumpHomeScreen(tester);

        expect(find.byIcon(Icons.search), findsOneWidget);
        expect(find.byType(TextField), findsNothing);

        await tester.tap(find.byIcon(Icons.search));
        await tester.pump();

        // Campo aberto ali mesmo -- nunca uma rota nova nem um overlay.
        expect(find.byType(TextField), findsOneWidget);
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.byIcon(Icons.close), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'FHD');
        await tester.pump();

        // Filtro local, em tempo real (onChanged, sem debounce): só "Canal
        // C" (com FHD no nome) sobra -- sem NENHUMA chamada de rede nova.
        expect(find.textContaining('Canal C'), findsOneWidget);
        expect(find.textContaining('Canal A'), findsNothing);
        expect(find.textContaining('Canal B'), findsNothing);

        await tester.tap(find.byIcon(Icons.close));
        await tester.pump();

        // Fechar a busca limpa o filtro e volta a mostrar tudo.
        expect(find.byType(TextField), findsNothing);
        expect(find.textContaining('Canal A'), findsOneWidget);
        expect(find.textContaining('Canal B'), findsOneWidget);
        expect(find.textContaining('Canal C'), findsOneWidget);
      },
    );

    testWidgets('busca sem nenhum resultado mostra estado vazio próprio, sem travar a tela', (tester) async {
      await pumpHomeScreen(tester);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'canal que não existe');
      await tester.pump();

      expect(find.textContaining('Nenhum canal encontrado'), findsOneWidget);
      expect(find.textContaining('Canal A'), findsNothing);
    });

    testWidgets('a lupa é alcançável e ativável por D-Pad (Enter), igual um toque', (tester) async {
      await pumpHomeScreen(tester);

      focusItem(tester, find.byIcon(Icons.search));
      await tester.pump();
      expect(isFocused(tester, find.byIcon(Icons.search)), isTrue);

      expect(find.byType(TextField), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('EPG ("agora"/"a seguir") aparece sob demanda no canal que tem, some silenciosamente no que não tem',
        (tester) async {
      await pumpHomeScreen(tester);
      await pumpSettled(tester);

      // "Canal A" (stream_id 101) tem EPG no dataset -- "Canal B" não (ver
      // _xtreamHandler): a ausência não pode travar/quebrar a linha dela.
      expect(find.textContaining('Jornal da Noite'), findsOneWidget);
      expect(find.textContaining('Filme da Madrugada'), findsOneWidget);
      expect(find.textContaining('Canal B'), findsOneWidget);
    });
  });

  group('Filmes (VOD): categoria "Todos" e busca inline local', () {
    testWidgets(
      '"Todos" já vem selecionada ao abrir a aba: mostra os filmes sem nenhum toque em categoria',
      (tester) async {
        await pumpHomeScreen(tester);

        await tester.tap(find.text('Filmes'));
        await pumpSettled(tester);

        // Sem tocar em "Lançamentos"/"Clássicos" -- "Todos" (primeira
        // opção, ver ContentProvider.allCategoriesId) já foi selecionada
        // automaticamente e os filmes já apareceram.
        expect(inTab('vod', find.text('Todos')), findsOneWidget);
        expect(find.text('Filme 1'), findsOneWidget);
      },
    );

    testWidgets(
      'lupa expande um campo de busca inline (nunca tela nova/overlay) e filtra os filmes localmente',
      (tester) async {
        await pumpHomeScreen(tester);

        await tester.tap(find.text('Filmes'));
        await pumpSettled(tester);

        expect(find.byIcon(Icons.search), findsOneWidget);
        expect(inTab('vod', find.byType(TextField)), findsNothing);

        await tester.tap(find.byIcon(Icons.search));
        await tester.pump();

        // Campo aberto ali mesmo -- nunca uma rota nova nem um overlay.
        expect(inTab('vod', find.byType(TextField)), findsOneWidget);
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.byIcon(Icons.close), findsOneWidget);

        await tester.enterText(inTab('vod', find.byType(TextField)), 'Filme 3');
        await tester.pump();

        // Filtro local, em tempo real (onChanged, sem debounce): só "Filme
        // 3" sobra -- sem NENHUMA chamada de rede nova.
        expect(textWidget('Filme 3'), findsOneWidget);
        expect(find.text('Filme 1'), findsNothing);

        await tester.tap(find.byIcon(Icons.close));
        await tester.pump();

        // Fechar a busca limpa o filtro e volta a mostrar tudo.
        expect(inTab('vod', find.byType(TextField)), findsNothing);
        expect(find.text('Filme 1'), findsOneWidget);
        expect(find.text('Filme 3'), findsOneWidget);
      },
    );

    testWidgets('busca sem nenhum resultado mostra estado vazio próprio, sem travar a tela', (tester) async {
      await pumpHomeScreen(tester);

      await tester.tap(find.text('Filmes'));
      await pumpSettled(tester);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();

      await tester.enterText(inTab('vod', find.byType(TextField)), 'filme que não existe');
      await tester.pump();

      expect(find.textContaining('Nenhum filme encontrado'), findsOneWidget);
      expect(find.text('Filme 1'), findsNothing);
    });

    testWidgets('a lupa é alcançável e ativável por D-Pad (Enter), igual um toque', (tester) async {
      await pumpHomeScreen(tester);

      await tester.tap(find.text('Filmes'));
      await pumpSettled(tester);

      focusItem(tester, find.byIcon(Icons.search));
      await tester.pump();
      expect(isFocused(tester, find.byIcon(Icons.search)), isTrue);

      expect(inTab('vod', find.byType(TextField)), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(inTab('vod', find.byType(TextField)), findsOneWidget);
    });

    testWidgets('nunca mostra selo de qualidade (FHD/HD/SD) -- exclusivo de Live TV', (tester) async {
      await pumpHomeScreen(tester);

      await tester.tap(find.text('Filmes'));
      await pumpSettled(tester);

      expect(inTab('vod', find.textContaining('FHD')), findsNothing);
      expect(inTab('vod', find.textContaining('HD')), findsNothing);
      expect(inTab('vod', find.textContaining('SD')), findsNothing);
    });

    testWidgets('selo "Novo" aparece só no filme adicionado dentro da janela recente', (tester) async {
      await pumpHomeScreen(tester);

      await tester.tap(find.text('Filmes'));
      await pumpSettled(tester);

      // "Filme 1" foi adicionado ontem (dentro da janela) -- "Filme 2" há 30
      // dias (fora dela) e os demais 11 não reportam 'added' -- só o
      // primeiro ganha o selo (ver dataset em _xtreamHandler acima).
      expect(find.text('Novo'), findsOneWidget);
    });

    testWidgets('coração favorita um filme; botão "Só favoritos" da AppBar filtra só ele', (tester) async {
      await pumpHomeScreen(tester);

      await tester.tap(find.text('Filmes'));
      await pumpSettled(tester);

      // O coração de cada card é um GestureDetector simples (não um
      // IconButton) -- só o botão da AppBar (abaixo) é um IconButton de
      // verdade, o que distingue os dois em qualquer find.widgetWithIcon.
      final filme1Card = find.ancestor(of: find.text('Filme 1'), matching: find.byType(InkWell));
      await tester.tap(find.descendant(of: filme1Card, matching: find.byIcon(Icons.favorite_border)));
      await tester.pump();

      // Favoritar não deve navegar pro Player (o coração intercepta o toque
      // antes do InkWell do card inteiro).
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.descendant(of: filme1Card, matching: find.byIcon(Icons.favorite)), findsOneWidget);

      await tester.tap(find.widgetWithIcon(IconButton, Icons.favorite_border));
      await tester.pump();

      expect(find.text('Filme 1'), findsOneWidget);
      expect(find.text('Filme 2'), findsNothing);
      expect(find.text('Filme 3'), findsNothing);

      await tester.tap(find.widgetWithIcon(IconButton, Icons.favorite));
      await tester.pump();

      expect(find.text('Filme 2'), findsOneWidget);
    });

    testWidgets('tocar num filme abre a ficha de detalhes (VodDetailsScreen), não toca direto', (tester) async {
      await pumpHomeScreen(tester);

      await tester.tap(find.text('Filmes'));
      await pumpSettled(tester);

      // "Filme 4" é o destaque (ver _FeaturedBanner) -- toca em "Filme 2"
      // no grid normal em vez dele, pra este teste continuar válido
      // independente de qual card carrega o banner.
      final filme2Card = find.ancestor(of: find.text('Filme 2'), matching: find.byType(InkWell));
      await tester.tap(filme2Card);
      await pumpSettled(tester);

      expect(find.byType(VodDetailsScreen), findsOneWidget);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.text('Assistir'), findsOneWidget);
    });
  });

  group('Séries: categoria "Todos" e busca inline local', () {
    testWidgets(
      '"Todos" já vem selecionada ao abrir a aba: mostra as séries sem nenhum toque em categoria',
      (tester) async {
        await pumpHomeScreen(tester);

        await tester.tap(find.text('Séries'));
        await pumpSettled(tester);

        expect(inTab('series', find.text('Todos')), findsOneWidget);
        expect(find.text('Série A'), findsOneWidget);
        expect(find.text('Série B'), findsOneWidget);
      },
    );

    testWidgets(
      'lupa expande um campo de busca inline (nunca tela nova/overlay) e filtra as séries localmente',
      (tester) async {
        await pumpHomeScreen(tester);

        await tester.tap(find.text('Séries'));
        await pumpSettled(tester);

        expect(find.byIcon(Icons.search), findsOneWidget);
        expect(inTab('series', find.byType(TextField)), findsNothing);

        await tester.tap(find.byIcon(Icons.search));
        await tester.pump();

        expect(inTab('series', find.byType(TextField)), findsOneWidget);
        expect(find.byIcon(Icons.close), findsOneWidget);

        await tester.enterText(inTab('series', find.byType(TextField)), 'Série A');
        await tester.pump();

        expect(textWidget('Série A'), findsOneWidget);
        expect(find.text('Série B'), findsNothing);

        await tester.tap(find.byIcon(Icons.close));
        await tester.pump();

        expect(inTab('series', find.byType(TextField)), findsNothing);
        expect(find.text('Série A'), findsOneWidget);
        expect(find.text('Série B'), findsOneWidget);
      },
    );

    testWidgets('busca sem nenhum resultado mostra estado vazio próprio, sem travar a tela', (tester) async {
      await pumpHomeScreen(tester);

      await tester.tap(find.text('Séries'));
      await pumpSettled(tester);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();

      await tester.enterText(inTab('series', find.byType(TextField)), 'série que não existe');
      await tester.pump();

      expect(find.textContaining('Nenhuma série encontrada'), findsOneWidget);
      expect(find.text('Série A'), findsNothing);
    });

    testWidgets('categorias de Séries são independentes das de VOD/Live TV (nunca misturadas)', (tester) async {
      await pumpHomeScreen(tester);

      await tester.tap(find.text('Séries'));
      await pumpSettled(tester);

      // "Dramas" é a única categoria REAL vinda da API pra Séries -- as
      // categorias de VOD ("Lançamentos"/"Clássicos") e Live TV
      // ("Esportes"/"Notícias"/"Kids") nunca aparecem aqui.
      expect(inTab('series', find.text('Dramas')), findsOneWidget);
      expect(inTab('series', find.text('Lançamentos')), findsNothing);
      expect(inTab('series', find.text('Esportes')), findsNothing);
    });
  });

  group('Configurações e bloqueio por PIN', () {
    /// Ícone de Configurações/PIN da AppBar mudam o estado do
    /// [SettingsProvider] direto (sem passar pela UI) -- mais rápido que
    /// simular o fluxo inteiro de "abrir Configurações > definir PIN" pra
    /// testes que só precisam de um PIN já definido como pré-condição.
    SettingsProvider settingsOf(WidgetTester tester) =>
        Provider.of<SettingsProvider>(tester.element(find.byType(HomeScreen)), listen: false);

    testWidgets('sem PIN definido, nenhuma categoria mostra cadeado', (tester) async {
      await pumpHomeScreen(tester);

      await tester.tap(find.text('Filmes'));
      await pumpSettled(tester);

      expect(find.byIcon(Icons.lock), findsNothing);
      expect(find.byIcon(Icons.lock_open), findsNothing);
    });

    testWidgets(
      'trava "Clássicos": some da visão "Todos"; selecionar pede PIN; PIN errado bloqueia, PIN certo libera',
      (tester) async {
        await pumpHomeScreen(tester);
        await settingsOf(tester).setPin('1234');
        await pumpSettled(tester);

        await tester.tap(find.text('Filmes'));
        await pumpSettled(tester);

        // "Todos" (selecionada por padrão) mostra os 13 filmes -- "Filme 11"
        // pertence à categoria "Clássicos" (ver dataset em _xtreamHandler).
        expect(find.text('Filme 11'), findsOneWidget);

        final classicosRow = find.ancestor(of: find.text('Clássicos'), matching: find.byType(ListTile));
        await tester.tap(find.descendant(of: classicosRow, matching: find.byIcon(Icons.lock_open)));
        await tester.pump();

        expect(find.descendant(of: classicosRow, matching: find.byIcon(Icons.lock)), findsOneWidget);
        expect(
          find.text('Filme 11'),
          findsNothing,
          reason: '"Clássicos" travada -- seus itens não podem aparecer nem em "Todos"',
        );

        // Tocar na categoria travada pede o PIN, não seleciona direto.
        await tester.tap(find.text('Clássicos'));
        await pumpSettled(tester);
        expect(find.text('Digite o PIN pra ver esta categoria'), findsOneWidget);

        await tester.enterText(find.widgetWithText(TextField, 'PIN'), '0000');
        await tester.tap(find.text('Confirmar'));
        await pumpSettled(tester);

        expect(find.text('PIN incorreto.'), findsOneWidget);
        expect(find.text('Filme 11'), findsNothing, reason: 'PIN errado não desbloqueia nada');

        await tester.tap(find.text('Clássicos'));
        await pumpSettled(tester);
        await tester.enterText(find.widgetWithText(TextField, 'PIN'), '1234');
        await tester.tap(find.text('Confirmar'));
        await pumpSettled(tester);

        // PIN certo: seleciona "Clássicos" de verdade (mostra o conteúdo
        // dela) e desbloqueia a categoria pro resto da sessão.
        expect(find.text('Filme 11'), findsOneWidget);
      },
    );

    testWidgets('desproteger uma categoria já travada também pede PIN', (tester) async {
      await pumpHomeScreen(tester);
      await settingsOf(tester).setPin('1234');
      await pumpSettled(tester);

      await tester.tap(find.text('Filmes'));
      await pumpSettled(tester);

      final classicosRow = find.ancestor(of: find.text('Clássicos'), matching: find.byType(ListTile));
      await tester.tap(find.descendant(of: classicosRow, matching: find.byIcon(Icons.lock_open)));
      await tester.pump();
      expect(find.descendant(of: classicosRow, matching: find.byIcon(Icons.lock)), findsOneWidget);

      await tester.tap(find.descendant(of: classicosRow, matching: find.byIcon(Icons.lock)));
      await pumpSettled(tester);
      expect(find.text('Digite o PIN pra destravar esta categoria'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'PIN'), '1234');
      await tester.tap(find.text('Confirmar'));
      await pumpSettled(tester);

      expect(find.descendant(of: classicosRow, matching: find.byIcon(Icons.lock_open)), findsOneWidget);
      expect(find.text('Filme 11'), findsOneWidget, reason: 'desprotegida -- volta a aparecer em "Todos"');
    });
  });

  group('Layout estreito (mobile)', () {
    // Abaixo de `_sidebarBreakpoint` (700px, ver home_screen.dart), o menu
    // lateral fixo vira uma BottomNavigationBar -- baseado em TOQUE, não em
    // D-Pad (TVs renderizam largura >= 700px na prática; este layout só
    // ativa em celular). 360px é uma largura típica de celular em retrato.
    const narrowSize = Size(360, 800);

    testWidgets('abaixo do breakpoint, mostra BottomNavigationBar em vez do menu lateral', (tester) async {
      await pumpHomeScreen(tester, size: narrowSize);

      expect(find.byType(BottomNavigationBar), findsOneWidget);
      // O menu lateral largo tem um FocusScopeNode próprio (ver
      // home_screen.dart) -- ausente confirma que a árvore realmente trocou
      // de widget, não só ficou visualmente menor.
      expect(find.byWidgetPredicate((w) => w is SectionSidebar), findsNothing);
    });

    testWidgets('tocar num item da BottomNavigationBar troca de seção', (tester) async {
      await pumpHomeScreen(tester, size: narrowSize);

      expect(find.text('Esportes'), findsOneWidget);
      expect(find.text('Lançamentos'), findsNothing);

      await tester.tap(find.text('Filmes'));
      await pumpSettled(tester);

      expect(find.text('Lançamentos'), findsOneWidget);
    });

    testWidgets('menu de overflow (⋮) da AppBar abre Configurações', (tester) async {
      await pumpHomeScreen(tester, size: narrowSize);

      await tester.tap(find.byIcon(Icons.more_vert));
      await pumpSettled(tester);

      await tester.tap(find.text('Configurações'));
      await pumpSettled(tester);

      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  });

  group('Foco: seção ainda carregando (rede lenta)', () {
    // [TESTE] Bug real relatado testando na TV TCL e depois confirmado
    // também via teclado no Windows: ao contrário de Live TV (cujas
    // categorias já chegam da rede desde o 1º frame do app, ver
    // home_screen.dart initState), Filmes/Séries carregam categorias SOB
    // DEMANDA só ao trocar de seção -- se a seta direita (ou Enter) chegar
    // ANTES da resposta HTTP (fácil de acontecer numa conexão mais lenta
    // ao painel, mas também numa rede rápida se o usuário for ágil o
    // bastante), `_enterContent()` não achava nada focável ainda e
    // desistia em silêncio, sem tentar de novo depois que os dados
    // chegavam. Simula esse atraso segurando a resposta de
    // `get_vod_categories` atrás de um `Completer` controlado pelo teste.
    Future<http.Response> Function(http.Request) delayedVodCategoriesHandler(Completer<void> gate) {
      return (request) async {
        if (request.url.queryParameters['action'] == 'get_vod_categories') {
          await gate.future;
        }
        return _xtreamHandler(request);
      };
    }

    testWidgets(
      'seta direita no menu, com Filmes ainda carregando, foca a categoria automaticamente assim que a resposta chega',
      (tester) async {
        final gate = Completer<void>();
        await pumpHomeScreen(tester, xtreamHandler: delayedVodCategoriesHandler(gate));

        // `focusItem` só move o foco de TECLADO -- sozinho, não chama
        // `onTap`/`_selectSection` (achado corrigindo este teste: sem o
        // Enter aqui, a seção ativa continuava "TV Ao Vivo" o tempo todo, e
        // o teste "passava" testando Live TV por engano, não Filmes de
        // verdade). Enter é o que efetivamente SELECIONA a seção.
        focusItem(tester, find.text('Filmes'));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();

        // Resposta ainda presa no gate -- nada de Filmes deveria existir na
        // árvore ainda, a seta não deve ter derrubado o app, e o foco
        // continua exatamente onde estava (achado real: mover o foco pra
        // um "escopo vazio" nesse meio-tempo é um estado instável -- ver
        // `_enterContent` em home_screen.dart).
        expect(find.text('Lançamentos'), findsNothing);
        expect(isFocused(tester, find.text('Filmes')), isTrue);

        // Libera a resposta -- ContentProvider.notifyListeners() dispara,
        // e `_onContentProviderChanged` chama `_enterContent()` de novo --
        // confiável agora porque foca um FocusNode dedicado e endereçável
        // diretamente ([_firstCategoryFocusNodes] em home_screen.dart),
        // sem precisar de nenhuma seta extra do usuário.
        gate.complete();
        await pumpSettled(tester);

        expect(find.text('Lançamentos'), findsOneWidget);
        expect(isFocused(tester, find.text('Todos')), isTrue);
      },
    );

    testWidgets(
      'trocar de seção ANTES da resposta atrasada chegar não sequestra o foco pra seção abandonada',
      (tester) async {
        // [TESTE] Bug real (mais sério que o de cima, achado testando de
        // verdade): a 1ª versão deste fix guardava só um `bool` genérico
        // ("há algo pendente"), sem lembrar QUAL seção pediu. Se o usuário
        // trocasse de seção antes da resposta original chegar, a
        // retentativa checava a seção ATIVA no momento em que a resposta
        // tardía chegava -- puxando o foco pra QUALQUER seção que
        // estivesse ativa naquele instante, no meio da navegação normal do
        // usuário (relatado como "a navegação para depois de um tempo",
        // inclusive voltando pra Live TV). Este teste prova que uma
        // resposta tardia de uma seção ABANDONADA nunca mexe no foco.
        final gate = Completer<void>();
        await pumpHomeScreen(tester, xtreamHandler: delayedVodCategoriesHandler(gate));

        // Entra em Filmes de verdade (Enter seleciona a seção -- só focar
        // com `focusItem` não chama `_selectSection`, ver teste acima) --
        // categorias presas no gate, fica pendente.
        focusItem(tester, find.text('Filmes'));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(find.text('Lançamentos'), findsNothing);

        // Usuário desiste e troca pra Séries ANTES da resposta de Filmes
        // chegar. O foco NUNCA saiu de "Filmes" no menu (Filmes ainda não
        // tinha nada focável, ver `_enterContent` -- não move o foco pra
        // lugar nenhum nesse caso), então seta baixo até "Séries" + Enter
        // já é navegação de D-Pad real, direto -- não precisa "voltar" pro
        // menu primeiro.
        expect(isFocused(tester, find.text('Filmes')), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(isFocused(tester, find.text('Séries')), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await pumpSettled(tester);
        expect(find.text('Dramas'), findsOneWidget, reason: 'já deveria estar navegando em Séries normalmente');
        expect(isFocused(tester, find.text('Séries')), isTrue);

        // SÓ AGORA a resposta atrasada de Filmes chega -- não deveria fazer
        // NADA: nem focar nada de Filmes, nem tirar o foco de onde o
        // usuário está agora em Séries.
        gate.complete();
        await pumpSettled(tester);

        expect(find.text('Lançamentos'), findsNothing, reason: 'nunca deveria ter entrado em Filmes de verdade');
        expect(
          isFocused(tester, find.text('Séries')),
          isTrue,
          reason: 'o foco não pode ter sido puxado pra longe de onde o usuário está agora',
        );
      },
    );
  });
}
