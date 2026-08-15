import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/fade_slide_route.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/category_icons.dart';
import '../../core/utils/channel_quality.dart';
import '../../data/models/watch_progress.dart';
import '../../data/models/xtream_models.dart';
import '../../data/services/xtream_api_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/content_provider.dart';
import '../../providers/continue_watching_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/profiles_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/stream_url_builder.dart';
import '../../widgets/category_filter_header.dart';
import '../../widgets/dpad_focus_highlight.dart';
import '../../widgets/network_image_with_fallback.dart';
import '../../widgets/new_badge.dart';
import '../../widgets/quality_badge.dart';
import '../../widgets/section_sidebar.dart';
import '../../widgets/skeleton_loader.dart';
import '../../widgets/state_illustration.dart';
import '../player/player_screen.dart';
import '../series_details/series_details_screen.dart';
import '../settings/settings_screen.dart';
import '../vod_details/vod_details_screen.dart';
import '../activation/activation_screen.dart';
import '../server_selection/server_selection_screen.dart';

/// Abaixo desta largura a seleção de categoria vira uma barra horizontal de
/// chips no topo; acima disso vira uma sidebar fixa à esquerda.
const double _sidebarBreakpoint = 700;

/// Janela pra um filme ainda ganhar o selo [NewBadge] (ver `_VodGrid`),
/// contada a partir de `VodStream.added` (data que o painel Xtream reporta
/// como "adicionado ao catálogo" -- não é a data de lançamento do filme).
const Duration _newBadgeWindow = Duration(days: 7);

bool _isRecentlyAdded(DateTime? added) =>
    added != null && DateTime.now().difference(added) <= _newBadgeWindow;

/// Tela principal pós-login: 4 abas (Live TV, Filmes, Séries, Continuar
/// Assistindo). As 3 primeiras têm categorias à esquerda/topo e o
/// grid/lista de streams da categoria selecionada — estado vindo do
/// [ContentProvider]. A 4ª é um grid liso (sem categorias) do progresso
/// salvo, vindo do [ContinueWatchingProvider]. Nenhum widget aqui chama o
/// [XtreamApiService] diretamente.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final apiService = context.read<AuthProvider>().apiService;

    if (apiService == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Sessão expirada. Ative o dispositivo novamente.'),
                const SizedBox(height: AppSpacing.l),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const ActivationScreen()),
                    (route) => false,
                  ),
                  child: const Text('Ir para a ativação'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => ContentProvider(apiService: apiService),
        ),
        ChangeNotifierProvider(create: (_) => ContinueWatchingProvider()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()),
      ],
      child: const _HomeScreenBody(),
    );
  }
}

class _HomeScreenBody extends StatefulWidget {
  const _HomeScreenBody();

  @override
  State<_HomeScreenBody> createState() => _HomeScreenBodyState();
}

class _HomeScreenBodyState extends State<_HomeScreenBody> {
  // [TESTE] Substitui o `TabController` antigo — a HomeScreen sempre abre em
  // Live TV, mesmo índice inicial que o TabController tinha (0). Ver
  // SectionSidebar, que dá autofoco direto ao item correspondente a esta
  // seção desde o 1º frame (não depende mais de esperar categorias
  // chegarem da rede como o hack antigo de `_rootFocusNode`/`nextFocus()`
  // fazia).
  HomeSection _selectedSection = HomeSection.liveTv;

  // [TESTE] Isolam a busca DIRECIONAL (seta) do menu lateral e do conteúdo
  // um do outro -- ao contrário de `FocusTraversalGroup` (que só afeta
  // travessia por ORDEM/Tab), `FocusScope` genuinamente restringe a busca
  // por seta aos descendentes de cada um. Necessário porque, sem isso, o
  // algoritmo padrão do Flutter varre a árvore inteira e pode preferir um
  // item do menu (mais alinhado verticalmente) a uma categoria mais
  // próxima horizontalmente dentro do conteúdo -- "pulo" incorreto
  // confirmado empiricamente rodando os testes deste redesenho (seta
  // esquerda na coluna 0 do grid aterrissando em "Continuar Assistindo" do
  // menu em vez da sidebar de categorias). A transição INTENCIONAL entre os
  // dois escopos é feita à mão por `_enterMenu`/`_enterContent`, disparada
  // só quando a busca padrão não encontra nenhum alvo dentro do próprio
  // escopo -- ver `_BoundaryDirectionalFocusAction` mais abaixo.
  final FocusScopeNode _sectionSidebarScope = FocusScopeNode(debugLabel: 'section_sidebar_scope');
  final FocusScopeNode _contentScope = FocusScopeNode(debugLabel: 'home_content_scope');

  late final List<FocusNode> _sectionFocusNodes = [
    for (final section in HomeSection.values) FocusNode(debugLabel: 'menu_${section.name}'),
  ];

  // [TESTE] Um FocusNode dedicado por [ContentType], plugado na categoria
  // "Todos" (sempre a primeira, ver `ContentProvider._withAllCategory`) de
  // cada seção -- mesmo mecanismo, pelo mesmo motivo, já usado com sucesso
  // por [_sectionFocusNodes] no menu lateral. Substitui uma tentativa
  // anterior baseada em `FocusTraversalPolicy.findFirstFocus`/`nextFocus`,
  // que se mostrou pouco confiável quando chamada de fora do fluxo normal
  // de tecla/D-Pad (achado empírico: às vezes devolvia o próprio
  // `FocusScopeNode`, ou pousava num item errado, mesmo com a categoria já
  // carregada e presente na árvore) -- um `FocusNode` endereçável
  // diretamente não depende de nenhuma busca/travessia, então funciona
  // igual não importa de onde é chamado (evento de tecla real ou este
  // listener assíncrono).
  late final Map<ContentType, FocusNode> _firstCategoryFocusNodes = {
    for (final type in ContentType.values) type: FocusNode(debugLabel: 'first_category_${type.name}'),
  };

  // [TESTE] Guardado à parte (mesmo raciocínio do antigo `_contentProvider`
  // desta classe, aposentado no redesenho do menu lateral e ressuscitado
  // aqui por um motivo novo): `_onContentProviderChanged` precisa remover
  // este mesmo listener em `dispose()`, e buscar `context.read<ContentProvider>()`
  // de novo lá pode ser inseguro se o Element já estiver desativado.
  late final ContentProvider _contentProvider = context.read<ContentProvider>();

  // [TESTE] Qual seção `_enterContent()` tentou focar sem achar nada ainda
  // (ver comentário lá) -- `null` quando não há nenhuma tentativa pendente.
  // PRECISA ser a seção específica, não um bool genérico: guardar só
  // "há algo pendente" e checar a seção ATIVA no momento em que os dados
  // chegam (em vez da seção que realmente pediu) é o que causava um bug
  // real -- se o usuário trocasse de seção antes da resposta da seção
  // ORIGINAL chegar, o foco acabava sendo puxado pra QUALQUER seção que
  // estivesse ativa quando aquela resposta tardia finalmente notificasse,
  // no meio da navegação normal do usuário, mesmo em Live TV (que nunca
  // pede isso sozinha) -- relatado como "a navegação para depois de um
  // tempo, mesmo na Live TV" testando de verdade.
  HomeSection? _pendingContentFocusSection;

  @override
  void initState() {
    super.initState();
    // Carrega as categorias da seção inicial e o progresso de "Continuar
    // Assistindo" assim que a tela monta.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureCategoriesLoaded(_selectedSection);
      context.read<ContinueWatchingProvider>().load();
      context.read<FavoritesProvider>().load();
    });
    _contentProvider.addListener(_onContentProviderChanged);
  }

  @override
  void dispose() {
    _contentProvider.removeListener(_onContentProviderChanged);
    _sectionSidebarScope.dispose();
    _contentScope.dispose();
    for (final node in _sectionFocusNodes) {
      node.dispose();
    }
    for (final node in _firstCategoryFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// [TESTE] Chama `_enterContent()` de novo assim que as categorias da
  /// seção que estava esperando chegarem -- confiável AGORA porque
  /// `_enterContent()` foca um `FocusNode` dedicado e endereçável
  /// diretamente ([_firstCategoryFocusNodes], plugado na categoria "Todos"
  /// de cada tipo), não mais uma busca de traversal-policy (`findFirstFocus`/
  /// `nextFocus`) -- essas se mostraram pouco confiáveis quando chamadas de
  /// fora do fluxo normal de tecla/D-Pad (achado empírico: às vezes
  /// devolviam o próprio `FocusScopeNode`, ou pousavam num item errado,
  /// mesmo com a categoria já carregada e presente na árvore). Um
  /// `FocusNode.requestFocus()` direto não tem essa ambiguidade, então
  /// funciona igual não importa de onde é chamado.
  ///
  /// Só age se a seção pendente ainda for a seção ATIVA agora -- se o
  /// usuário já trocou de seção antes dos dados chegarem, a intenção
  /// original de entrar ali não faz mais sentido; simplesmente espera (sem
  /// limpar [_pendingContentFocusSection]) até o usuário voltar pra ela,
  /// se algum dia voltar.
  void _onContentProviderChanged() {
    final pendingSection = _pendingContentFocusSection;
    if (pendingSection == null || pendingSection != _selectedSection) return;

    final type = pendingSection.contentType;
    if (type == null || _contentProvider.categoriesFor(type).isEmpty) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _enterContent();
    });
  }

  /// Devolve o foco pro item do menu correspondente à seção ATIVA --
  /// chamado quando seta esquerda no conteúdo não encontra mais nenhum alvo
  /// dentro do próprio `_contentScope` (já na borda esquerda).
  void _enterMenu() => _sectionFocusNodes[_selectedSection.index].requestFocus();

  /// Entra no conteúdo vindo do menu.
  ///
  /// [TESTE] Live TV/Filmes/Séries usam [_firstCategoryFocusNodes] (um
  /// `FocusNode` dedicado por [ContentType], plugado na categoria "Todos")
  /// -- endereçável direto, sem busca de traversal-policy nenhuma, o mesmo
  /// mecanismo confiável já usado pro menu lateral ([_sectionFocusNodes]).
  /// "Continuar Assistindo" (sem [ContentType]/sem categorias) ainda usa
  /// `findFirstFocus` como reserva -- menos crítico ali, o progresso salvo
  /// carrega local (sem espera de rede), então a janela de "nada focável
  /// ainda" é bem mais curta.
  ///
  /// Achado testando numa TV real: ao contrário de Live TV (cujas
  /// categorias já carregam desde o 1º frame do app, ver `initState`),
  /// Filmes/Séries carregam SOB DEMANDA só quando a seção é selecionada
  /// (`_selectSection` -> `_ensureCategoriesLoaded`) -- se a seta direita
  /// chegar antes da resposta da rede (bem provável numa conexão mais
  /// lenta ao painel), o nó dedicado ainda não está pronto/anexado. Quando
  /// isso acontece, NÃO move o foco pra `_contentScope` diretamente --
  /// achado empírico: focar um `FocusScopeNode` sem nenhum descendente
  /// focável não é um estado estável/previsível (o Flutter pode devolver
  /// `primaryFocus` como um nó `Focus` ambíguo/ancestral qualquer, fazendo
  /// a PRÓXIMA seta se comportar de forma imprevisível). Só marca
  /// [_pendingContentFocusSection] (ver `_onContentProviderChanged`) e
  /// deixa o foco exatamente onde já estava -- no item do menu que
  /// disparou esta chamada.
  void _enterContent() {
    // [TESTE] Bug real (o motivo de só a PRIMEIRA seção visitada continuar
    // navegável): `_contentScope` é UM SÓ, compartilhado por todas as 4
    // seções (todas montadas ao mesmo tempo dentro do IndexedStack, ver
    // `_buildContentStack`) -- `focusedChild` guarda o ÚLTIMO item
    // focado, mesmo depois da seção dele ter sido excluída (`ExcludeFocus`)
    // ao trocar pra outra seção. Sem o `canRequestFocus` abaixo, esta
    // função tentava reaproveitar esse item ANTIGO/escondido -- uma
    // chamada de `requestFocus()` que falha em silêncio (o nó não pode
    // mais receber foco), nunca caindo no branch de baixo que focaria a
    // categoria certa da seção ATUAL.
    final focusedChild = _contentScope.focusedChild;
    if (focusedChild != null && focusedChild.canRequestFocus) {
      _pendingContentFocusSection = null;
      focusedChild.requestFocus();
      return;
    }

    final type = _selectedSection.contentType;
    if (type != null) {
      final firstCategoryNode = _firstCategoryFocusNodes[type];
      if (firstCategoryNode == null || !firstCategoryNode.canRequestFocus) {
        _pendingContentFocusSection = _selectedSection;
        return;
      }
      _pendingContentFocusSection = null;
      firstCategoryNode.requestFocus();
      return;
    }

    final target = ReadingOrderTraversalPolicy().findFirstFocus(_contentScope, ignoreCurrentFocus: true);
    if (target == null || target == _contentScope) {
      _pendingContentFocusSection = _selectedSection;
      return;
    }
    _pendingContentFocusSection = null;
    target.requestFocus();
  }

  // Liga só durante a re-busca de servidores de "Trocar de servidor" (ver
  // `_switchServer`) -- troca o ícone da ação por um spinner pra dar
  // feedback de que algo está acontecendo em segundo plano, sem travar
  // (nem escurecer) o resto da tela com um dialog.
  bool _switchingServer = false;

  // Uma GlobalKey por seção de conteúdo -- dá pro botão de lupa GLOBAL da
  // AppBar (ver `build` abaixo) abrir/fechar a busca da seção ATUALMENTE
  // visível sem precisar levantar todo o estado de busca (_searching,
  // _searchController etc.) pra cá: ele só invoca `_toggleSearch()` no
  // `_ContentTabViewState` certo através da key. Indexado por
  // `ContentType`, não por `HomeSection` -- "Continuar Assistindo" não tem
  // uma (ver `_currentContentTabKey`).
  final List<GlobalKey<_ContentTabViewState>> _contentTabKeys =
      List.generate(ContentType.values.length, (_) => GlobalKey<_ContentTabViewState>());

  /// null na seção "Continuar Assistindo" (sem [ContentType], mesma guarda
  /// usada em `_ensureCategoriesLoaded`) -- ela não tem busca.
  GlobalKey<_ContentTabViewState>? get _currentContentTabKey {
    final type = _selectedSection.contentType;
    return type == null ? null : _contentTabKeys[type.index];
  }

  /// [TESTE] Troca a seção exibida (chamado pelo `SectionSidebar`) --
  /// substitui o antigo listener de `_tabController`. Categorias são
  /// carregadas sob demanda na primeira vez que cada seção é selecionada
  /// (mesma lógica de antes, só sem depender de `TabController.indexIsChanging`
  /// pra evitar disparo duplicado -- aqui só existe UM ponto de entrada).
  void _selectSection(HomeSection section) {
    if (section == _selectedSection) return;
    setState(() => _selectedSection = section);
    _ensureCategoriesLoaded(section);
  }

  void _ensureCategoriesLoaded(HomeSection section) {
    // "Continuar Assistindo" não tem categorias (ver `_ContinueWatchingTab`)
    // -- nada a carregar aqui pra ela.
    final type = section.contentType;
    if (type == null) return;
    context.read<ContentProvider>().loadCategories(type);
  }

  /// Rebusca a lista de servidores
  /// vinculados a este MESMO dispositivo já ativado e leva pra
  /// ServerSelectionScreen -- nunca apaga nada do StorageService, nunca
  /// desvincula o dispositivo. Só depois de escolher um servidor lá é que o
  /// perfil salvo é atualizado (ver ServerSelectionScreen/ProfilesProvider.
  /// chooseServer).
  Future<void> _switchServer(BuildContext context) async {
    final profilesProvider = context.read<ProfilesProvider>();
    final profile = profilesProvider.savedProfile;
    if (profile == null) return;

    setState(() => _switchingServer = true);

    final result = await profilesProvider.checkDeviceActivation();

    if (!context.mounted) return;
    setState(() => _switchingServer = false);

    if (result == null) {
      // Erro real do backend (ex: dispositivo inativo, expirado nesse meio
      // tempo) -- nunca trava a tela: só avisa e deixa o usuário continuar
      // usando a sessão atual normalmente.
      final message = context.read<AuthProvider>().errorMessage ?? 'Não foi possível buscar os servidores.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServerSelectionScreen(
          servers: result.servidores,
          existingProfileId: profile.id,
          nomeCliente: result.nomeCliente,
        ),
      ),
    );
  }

  /// Abre/fecha a busca da aba de conteúdo atualmente visível através da
  /// `GlobalKey` correspondente (ver `_currentContentTabKey`) -- `setState`
  /// aqui é necessário mesmo o toggle de verdade acontecendo dentro do
  /// `_ContentTabViewState` (que já se auto-redesenha sozinho): sem ele,
  /// o ÍCONE deste botão na AppBar (busca vs. fechar, calculado em `build`
  /// a partir de `_isCurrentTabSearching`) não saberia que precisa mudar,
  /// já que AppBar e a aba são State objects diferentes e não se escutam.
  void _toggleCurrentSearch() {
    setState(() {
      _currentContentTabKey?.currentState?._toggleSearch();
    });
  }

  bool get _isCurrentTabSearching => _currentContentTabKey?.currentState?._searching ?? false;

  /// Idem `_toggleCurrentSearch`, pro botão de coração ("só favoritos").
  void _toggleCurrentFavoritesOnly() {
    setState(() {
      _currentContentTabKey?.currentState?._toggleFavoritesOnly();
    });
  }

  bool get _isCurrentTabFavoritesOnly => _currentContentTabKey?.currentState?._favoritesOnly ?? false;

  /// [TESTE] Liga só durante `_refreshCurrent` -- sem isso, o botão
  /// "Atualizar" não dava NENHUM feedback visual (sem spinner, sem
  /// confirmação): quando o painel não tinha nada novo pra trazer, parecia
  /// que o toque não tinha feito efeito nenhum, mesmo a releitura de
  /// verdade tendo acontecido (relatado pelo usuário testando). Mesmo
  /// padrão já usado por `_switchingServer`.
  bool _refreshing = false;

  /// Botão de atualizar da AppBar: na seção atual, força releitura ignorando
  /// cache (ver `ContentProvider.refresh`); na seção "Continuar Assistindo"
  /// (sem `ContentType`, ver `_currentContentTabKey`), recarrega o
  /// progresso salvo em vez disso.
  Future<void> _refreshCurrent(BuildContext context) async {
    setState(() => _refreshing = true);

    final type = _selectedSection.contentType;
    if (type != null) {
      await context.read<ContentProvider>().refresh(type);
    } else {
      await context.read<ContinueWatchingProvider>().load();
    }

    if (!context.mounted) return;
    setState(() => _refreshing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Atualizado.'), duration: Duration(seconds: 2)),
    );
  }

  /// HomeScreen é a única rota na pilha (splash/login chegam aqui via
  /// `pushReplacement`), então sem essa interceptação o botão/tecla Voltar
  /// já derrubaria o app direto — aqui vira uma saída deliberada, com
  /// confirmação, igual o padrão esperado em apps de Android TV.
  Future<void> _confirmExit(BuildContext context) async {
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sair do app?'),
        content: const Text('Tem certeza que deseja sair do BarclayFlix 2.0?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sair'),
          ),
        ],
      ),
    );

    if (shouldExit == true) {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // `watch` (não `read`): o título precisa re-renderizar sozinho quando
    // _switchServer (acima) troca o perfil salvo por um servidor diferente,
    // sem precisar de nenhum setState manual aqui.
    final connectedServerName = context.watch<ProfilesProvider>().savedProfile?.nomeExibicao;

    // [TESTE] Mesmo corte que `_ContentTabView` já usa (`_sidebarBreakpoint`)
    // pra decidir sidebar-de-categoria-vs-chips, agora também no nível
    // raiz: acima dele, menu lateral fixo (SectionSidebar); abaixo,
    // BottomNavigationBar (o app também roda em Android mobile por toque,
    // ver CLAUDE.md -- um menu lateral fixo de 220px não cabe bem numa tela
    // de celular em retrato). `MediaQuery.sizeOf` (não outro `LayoutBuilder`
    // aninhado) porque essa decisão também afeta a AppBar (menu de
    // overflow vs. botões diretos), construída fora da árvore do `body`.
    final isWide = MediaQuery.sizeOf(context).width >= _sidebarBreakpoint;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            _confirmExit(context),
      },
      child: PopScope(
        // Intercepta o Back do sistema (D-Pad "Voltar" no Android TV, botão
        // físico/gesto no Android) para confirmar antes de fechar o app, em
        // vez de derrubar a tela sem aviso.
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _confirmExit(context);
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(connectedServerName ?? 'BarclayFlix 2.0'),
            actions: [
              // Ausente na aba "Continuar Assistindo" (_currentContentTabKey
              // null ali, ver getter) -- essa aba não tem nenhum conteúdo
              // filtrável por texto.
              if (_currentContentTabKey != null)
                IconButton(
                  icon: Icon(_isCurrentTabSearching ? Icons.close : Icons.search),
                  tooltip: _isCurrentTabSearching ? 'Fechar busca' : 'Buscar',
                  onPressed: _toggleCurrentSearch,
                ),
              if (_currentContentTabKey != null)
                IconButton(
                  icon: Icon(_isCurrentTabFavoritesOnly ? Icons.favorite : Icons.favorite_border),
                  tooltip: _isCurrentTabFavoritesOnly ? 'Mostrar tudo' : 'Só favoritos',
                  onPressed: _toggleCurrentFavoritesOnly,
                ),
              IconButton(
                icon: _refreshing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : const Icon(Icons.refresh),
                tooltip: 'Atualizar',
                onPressed: _refreshing ? null : () => _refreshCurrent(context),
              ),
              // No layout largo, Configurações/Trocar servidor/Sair moram
              // no grupo inferior do SectionSidebar (ver `body` abaixo) --
              // no estreito, sem menu lateral pra guardá-los, viram um
              // menu de overflow aqui na AppBar, reaproveitando os MESMOS
              // callbacks (nenhuma lógica nova, só outro widget de entrada).
              if (!isWide)
                PopupMenuButton<VoidCallback>(
                  tooltip: 'Mais opções',
                  onSelected: (action) => action(),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SettingsScreen()),
                      ),
                      child: const Text('Configurações'),
                    ),
                    PopupMenuItem(
                      value: () => _switchServer(context),
                      child: const Text('Trocar servidor'),
                    ),
                    PopupMenuItem(
                      value: () => _confirmExit(context),
                      child: const Text('Sair'),
                    ),
                  ],
                ),
            ],
          ),
          body: isWide ? _buildWideBody(context) : _buildNarrowBody(),
        ),
      ),
    );
  }

  /// Menu lateral fixo (SectionSidebar) + conteúdo lado a lado -- ver
  /// `_buildContentStack` pro porquê do `IndexedStack`/`ExcludeFocus`, e o
  /// `Actions`/`FocusScope` duplo pro porquê da travessia de foco entre os
  /// dois lados ser feita à mão (`_enterContent`/`_enterMenu`).
  Widget _buildWideBody(BuildContext context) {
    return Row(
      children: [
        // [TESTE] `Actions` sobrepõe SÓ `DirectionalFocusIntent` (não mexe
        // em Enter/Ativação) -- deixa a busca por seta padrão tentar
        // primeiro (`FocusNode.focusInDirection`, mesma coisa que o
        // framework já faz por baixo dos panos) e só chama `_enterContent`
        // quando ela não encontra NADA dentro do `_sectionSidebarScope`
        // isolado (ou seja, seta direita já na borda direita do menu).
        Actions(
          actions: {
            DirectionalFocusIntent: _BoundaryDirectionalFocusAction(
              onBoundary: (direction) {
                if (direction == TraversalDirection.right) _enterContent();
              },
            ),
          },
          child: SectionSidebar(
            selected: _selectedSection,
            onSelectSection: _selectSection,
            onOpenSettings: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
            onSwitchServer: () => _switchServer(context),
            onExit: () => _confirmExit(context),
            switchingServer: _switchingServer,
            focusScopeNode: _sectionSidebarScope,
            sectionFocusNodes: _sectionFocusNodes,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          // Espelha o `Actions` do menu acima, na direção oposta: seta
          // esquerda já na borda esquerda do `_contentScope` (nada mais pra
          // focar ali dentro) devolve o foco pro item ativo do menu.
          child: Actions(
            actions: {
              DirectionalFocusIntent: _BoundaryDirectionalFocusAction(
                onBoundary: (direction) {
                  if (direction == TraversalDirection.left) _enterMenu();
                },
              ),
            },
            child: FocusScope(
              node: _contentScope,
              child: _buildContentStack(),
            ),
          ),
        ),
      ],
    );
  }

  /// [TESTE] BottomNavigationBar no lugar do menu lateral -- só os 4 itens
  /// de conteúdo (Configurações/Trocar servidor/Sair viram overflow na
  /// AppBar, ver `build`). Sem `FocusScope`/`Actions` de travessia como no
  /// layout largo: TVs renderizam largura >= `_sidebarBreakpoint` na
  /// prática, então este layout só ativa em celular (touch-first) -- não há
  /// D-Pad real pra testar aqui.
  Widget _buildNarrowBody() {
    return Column(
      children: [
        Expanded(child: _buildContentStack()),
        BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          currentIndex: _selectedSection.index,
          onTap: (index) => _selectSection(HomeSection.values[index]),
          items: [
            for (final section in HomeSection.values)
              BottomNavigationBarItem(icon: Icon(section.icon), label: section.label),
          ],
        ),
      ],
    );
  }

  /// [TESTE] IndexedStack no lugar da TabBarView antiga. IndexedStack
  /// mantém os 4 painéis sempre montados (mesma propriedade que a
  /// TabBarView já tinha, crítica pra preservar scroll/categoria/busca por
  /// seção e o foco ao voltar do PlayerScreen) -- mas, ao contrário da
  /// TabBarView (cujo PageView translada páginas offscreen fisicamente pra
  /// longe), o IndexedStack sobrepõe todos os filhos na MESMA caixa. Sem o
  /// ExcludeFocus abaixo, o foco poderia "vazar" pra um item de uma seção
  /// invisível sem nenhum sinal visual na tela.
  Widget _buildContentStack() {
    return IndexedStack(
      index: _selectedSection.index,
      children: [
        for (final section in HomeSection.values)
          ExcludeFocus(
            excluding: section != _selectedSection,
            child: _panelFor(section),
          ),
      ],
    );
  }

  Widget _panelFor(HomeSection section) {
    switch (section) {
      case HomeSection.liveTv:
        return _ContentTabView(
          key: _contentTabKeys[ContentType.live.index],
          type: ContentType.live,
          searchHintText: 'Buscar canal...',
          firstCategoryFocusNode: _firstCategoryFocusNodes[ContentType.live]!,
          streamsPanelBuilder: (query, favoritesOnly) =>
              _LiveStreamsPanel(searchQuery: query, favoritesOnly: favoritesOnly),
        );
      case HomeSection.vod:
        return _ContentTabView(
          key: _contentTabKeys[ContentType.vod.index],
          type: ContentType.vod,
          searchHintText: 'Buscar filme...',
          firstCategoryFocusNode: _firstCategoryFocusNodes[ContentType.vod]!,
          streamsPanelBuilder: (query, favoritesOnly) =>
              _VodGrid(searchQuery: query, favoritesOnly: favoritesOnly),
        );
      case HomeSection.series:
        return _ContentTabView(
          key: _contentTabKeys[ContentType.series.index],
          type: ContentType.series,
          searchHintText: 'Buscar série...',
          firstCategoryFocusNode: _firstCategoryFocusNodes[ContentType.series]!,
          streamsPanelBuilder: (query, favoritesOnly) =>
              _SeriesGrid(searchQuery: query, favoritesOnly: favoritesOnly),
        );
      case HomeSection.continueWatching:
        return const _ContinueWatchingTab();
    }
  }
}

/// [TESTE] Sobrepõe o `DirectionalFocusIntent` padrão do Flutter (ligado a
/// setas de teclado/D-Pad) só pra observar quando a busca NÃO encontra
/// nenhum alvo dentro do escopo isolado atual (`FocusNode.focusInDirection`
/// devolve `false`) -- isso é exatamente "já está na borda do escopo nessa
/// direção". Delega a busca de verdade pro mesmo mecanismo que o Flutter já
/// usa por baixo dos panos (`FocusNode.focusInDirection`), então direções
/// que TÊM alvo dentro do escopo continuam funcionando idênticas a antes;
/// só a direção de borda (configurada via [onBoundary]) ganha um
/// comportamento extra de "sair do escopo".
///
/// [TESTE] Achado empírico rodando os testes deste redesign:
/// `FocusNode.focusInDirection` pode mudar `primaryFocus` pra um nó `Focus`
/// ambíguo/ancestral (sem `debugLabel`, não um item de verdade da árvore)
/// mesmo quando devolve `false` (não achou nenhum alvo) -- um efeito
/// colateral do próprio Flutter, não um bug deste código. Sem desfazer
/// isso, a seta SEGUINTE (mesmo numa direção diferente) parte desse nó
/// ambíguo em vez de de onde o usuário realmente estava, produzindo saltos
/// imprevisíveis (ex: seta direita sem efeito aparente, seguida de seta
/// baixo pousando em "TV Ao Vivo" no menu em vez do item seguinte ao que
/// estava focado). Por isso [origin] é sempre restaurado explicitamente
/// antes de chamar [onBoundary] quando a busca falha.
class _BoundaryDirectionalFocusAction extends Action<DirectionalFocusIntent> {
  _BoundaryDirectionalFocusAction({required this.onBoundary});

  final void Function(TraversalDirection direction) onBoundary;

  @override
  Object? invoke(DirectionalFocusIntent intent) {
    final origin = FocusManager.instance.primaryFocus;
    final moved = origin?.focusInDirection(intent.direction) ?? false;
    if (!moved) {
      origin?.requestFocus();
      onBoundary(intent.direction);
    }
    return null;
  }
}

/// Uma aba de conteúdo completa: seletor de categorias (sidebar ou chips,
/// conforme a largura disponível, com a lupa de busca local — ver
/// [CategoryFilterHeader]) + grid/lista de streams da categoria
/// selecionada. Envolvida em [FocusTraversalGroup] para deixar a navegação
/// por teclado/D-Pad estruturada.
///
/// Genérico pras 3 abas (Live TV/VOD/Séries) de propósito — evita 3
/// implementações quase idênticas de "sidebar/chips + lupa": só
/// [streamsPanelBuilder] (o grid/lista específico de cada uma) e
/// [searchHintText] variam por [type].
class _ContentTabView extends StatefulWidget {
  final ContentType type;
  final String searchHintText;
  final Widget Function(String searchQuery, bool favoritesOnly) streamsPanelBuilder;

  /// [TESTE] Plugado na categoria "Todos" (sempre a primeira, ver
  /// `ContentProvider._withAllCategory`) de `_CategoriesSidebar`/
  /// `_CategoriesChips` -- dá pra `_HomeScreenBodyState._enterContent()`
  /// focar direto ao entrar vindo do menu lateral, sem depender de nenhuma
  /// busca de traversal-policy (ver doc de `_firstCategoryFocusNodes` lá).
  final FocusNode firstCategoryFocusNode;

  const _ContentTabView({
    super.key,
    required this.type,
    required this.searchHintText,
    required this.firstCategoryFocusNode,
    required this.streamsPanelBuilder,
  });

  @override
  State<_ContentTabView> createState() => _ContentTabViewState();
}

class _ContentTabViewState extends State<_ContentTabView> {
  final TextEditingController _searchController = TextEditingController();
  late final FocusNode _searchFieldFocusNode = FocusNode(debugLabel: '${widget.type.name}_search_field');
  bool _searching = false;
  String _query = '';
  bool _favoritesOnly = false;

  void _openSearch() {
    setState(() => _searching = true);
    // Só depois do campo existir de verdade na árvore (próximo frame) — pedir
    // foco no mesmo build em que o campo aparece não tem efeito.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFieldFocusNode.requestFocus();
      // Em Android TV (ex.: Google TV/TCL), o foco pedido por controle remoto
      // (sem touchscreen) nem sempre dispara o teclado virtual sozinho — o
      // SO só mostra o IME automaticamente em resposta a um toque real.
      // Força a exibição explicitamente aqui; em telas com touch isso é um
      // no-op inofensivo (o teclado já estaria visível pelo requestFocus).
      SystemChannels.textInput.invokeMethod('TextInput.show');
    });
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _query = '';
      _searchController.clear();
    });
  }

  /// Chamado a partir do botão de lupa global na AppBar (ver
  /// `_HomeScreenBodyState`), via `GlobalKey<_ContentTabViewState>` -- este
  /// State não tem mais nenhum toggle próprio (ver CategoryFilterHeader).
  void _toggleSearch() {
    if (_searching) {
      _closeSearch();
    } else {
      _openSearch();
    }
  }

  /// Idem acima, mas pro botão de coração ("só favoritos") da AppBar.
  void _toggleFavoritesOnly() {
    setState(() => _favoritesOnly = !_favoritesOnly);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFieldFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _sidebarBreakpoint;

        final header = CategoryFilterHeader(
          isWide: isWide,
          searching: _searching,
          searchController: _searchController,
          searchFocusNode: _searchFieldFocusNode,
          searchHintText: widget.searchHintText,
          onQueryChanged: (value) => setState(() => _query = value),
          narrowCategoriesWidget:
              _CategoriesChips(type: widget.type, firstItemFocusNode: widget.firstCategoryFocusNode),
          wideCategoriesWidget:
              _CategoriesSidebar(type: widget.type, firstItemFocusNode: widget.firstCategoryFocusNode),
        );

        // `key` identifica esta aba especificamente em testes (ver
        // home_screen_dpad_test.dart) -- a TabBarView mantém as 3 abas de
        // conteúdo montadas ao mesmo tempo (mesmo fora de tela), então
        // finders genéricos (ex: `find.byIcon(Icons.search)`) sozinhos
        // encontrariam as 3 lupas de uma vez sem esse escopo.
        return FocusTraversalGroup(
          key: ValueKey('${widget.type.name}_content_tab'),
          child: isWide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 260, child: header),
                    const VerticalDivider(width: 1),
                    Expanded(child: widget.streamsPanelBuilder(_query, _favoritesOnly)),
                  ],
                )
              : Column(
                  children: [
                    header,
                    const Divider(height: 1),
                    Expanded(child: widget.streamsPanelBuilder(_query, _favoritesOnly)),
                  ],
                ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// Continuar Assistindo
// ---------------------------------------------------------------------

/// 4ª aba da HomeScreen, no mesmo nível de Live TV/Filmes/Séries — SEMPRE
/// presente na TabBar (mesmo sem nada assistido ainda, ver
/// [_ContinueWatchingGrid]), ao contrário da antiga prateleira fixa que
/// sumia inteira quando vazia. Sem sidebar/categorias (não é um
/// [ContentType], ver `_ensureCategoriesLoaded`) — só o grid liso do
/// progresso salvo.
class _ContinueWatchingTab extends StatelessWidget {
  const _ContinueWatchingTab();

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(child: const _ContinueWatchingGrid());
  }
}

/// Grid do progresso de VOD/episódios salvo — mesmo padrão visual (mesmo
/// [AppCardSizes.posterGridDelegate], mesmo [_PosterCard]) usado pelos
/// grids de VOD/Séries, pra a aba parecer consistente com as outras 3.
class _ContinueWatchingGrid extends StatelessWidget {
  const _ContinueWatchingGrid();

  @override
  Widget build(BuildContext context) {
    return Consumer<ContinueWatchingProvider>(
      builder: (context, provider, _) {
        final items = provider.items;

        if (items.isEmpty) {
          return const _EmptyHint(
            icon: Icons.history,
            message: 'Nada assistido ainda. O que você continuar aqui '
                'aparece automaticamente.',
          );
        }

        return GridView.builder(
          padding: const EdgeInsets.all(AppSpacing.m),
          // Mesmo raciocínio do _VodGrid/_SeriesGrid: folga de linhas
          // pré-construídas fora da viewport pra rolagem mais suave.
          scrollCacheExtent: const ScrollCacheExtent.pixels(500),
          gridDelegate: AppCardSizes.posterGridDelegate,
          itemCount: items.length,
          itemBuilder: (context, index) {
            final progress = items[index];

            return DpadFocusHighlight(
              key: ValueKey('continue_watching_${progress.contentId}'),
              builder: (context, focusNode, hasFocus) => _PosterCard(
                focusNode: focusNode,
                title: progress.title,
                imageUrl: progress.imageUrl,
                fallbackIcon: progress.type == WatchProgressType.episode
                    ? Icons.video_library
                    : Icons.movie,
                rating: 0,
                progressFraction: progress.fraction,
                onTap: () => _playContinueWatching(context, progress),
              ),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// Seleção de categoria
// ---------------------------------------------------------------------

class _CategoriesSidebar extends StatelessWidget {
  final ContentType type;

  /// [TESTE] Plugado só no item de índice 0 (sempre "Todos", ver
  /// `ContentProvider._withAllCategory`) -- ver doc completa em
  /// `_HomeScreenBodyState._firstCategoryFocusNodes`.
  final FocusNode firstItemFocusNode;

  const _CategoriesSidebar({required this.type, required this.firstItemFocusNode});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    return Consumer<ContentProvider>(
      builder: (context, provider, _) {
        final status = provider.categoriesStatusFor(type);
        final error = provider.categoriesErrorFor(type);
        final categories = provider.categoriesFor(type);
        final selectedId = provider.selectedCategoryIdFor(type);

        if (status == LoadStatus.loading && categories.isEmpty) {
          return ListView.builder(
            itemCount: 8,
            itemBuilder: (context, index) => const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: SkeletonBox(height: 16),
            ),
          );
        }

        if (status == LoadStatus.error && categories.isEmpty) {
          return _ErrorRetry(
            message: error ?? 'Erro ao carregar categorias.',
            onRetry: () => context.read<ContentProvider>().refresh(type),
          );
        }

        if (categories.isEmpty) {
          return const _EmptyHint(
            icon: Icons.folder_off_outlined,
            message: 'Nenhuma categoria encontrada.',
          );
        }

        return ListView.builder(
          itemCount: categories.length,
          itemBuilder: (context, index) {
            final category = categories[index];
            final selected = category.id == selectedId;
            // "Todos" (ver ContentProvider.allCategoriesId) nunca é
            // travável -- ela já agrega o conteúdo de TODAS as categorias
            // reais numa chamada só, então "proteger" ela sozinha não
            // protegeria nada de verdade (o filtro em
            // _LiveStreamsPanel/_VodGrid/_SeriesGrid cuida de tirar os itens
            // de categorias travadas de dentro dela).
            final lockable = category.id != ContentProvider.allCategoriesId;
            final protectedCategory = lockable && settings.isProtectedCategory(type, category.id);

            return DpadFocusHighlight(
              key: ValueKey('sidebar_category_${type.name}_${category.id}'),
              focusNode: index == 0 ? firstItemFocusNode : null,
              scaleOnFocus: false,
              borderRadius: BorderRadius.circular(4),
              // `Material(type: transparency)` próprio: o `DecoratedBox` do
              // `DpadFocusHighlight` acima (que pinta o fundo/glow de foco)
              // fica ENTRE este ListTile e o Material mais próximo da
              // Scaffold, escondendo o próprio fundo/ink splash do
              // `selectedTileColor` — sem este Material intermediário, o
              // framework acusa em debug ("ListTile background color or
              // ink splashes may be invisible"), achado rodando o teste que
              // foca este item automaticamente ao abrir a tela (ver
              // `_handOffInitialFocusIfReady`).
              builder: (context, focusNode, hasFocus) => Material(
                type: MaterialType.transparency,
                child: ListTile(
                  focusNode: focusNode,
                  selected: selected,
                  selectedTileColor: AppTheme.primaryColor.withAlpha(40),
                  leading: Icon(
                    categoryIcon(category.name),
                    color: selected
                        ? AppTheme.primaryColor
                        : Colors.grey.shade400,
                  ),
                  title: Text(category.name, overflow: TextOverflow.ellipsis),
                  trailing: (lockable && settings.hasPin)
                      ? GestureDetector(
                          onTap: () => _toggleCategoryLock(context, type, category.id),
                          child: Icon(
                            protectedCategory ? Icons.lock : Icons.lock_open,
                            size: 18,
                            color: protectedCategory ? AppTheme.primaryColor : Colors.grey.shade500,
                          ),
                        )
                      : null,
                  onTap: () => _selectCategoryGated(context, type, category.id),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _CategoriesChips extends StatelessWidget {
  final ContentType type;

  /// [TESTE] Mesmo raciocínio de `_CategoriesSidebar.firstItemFocusNode`.
  final FocusNode firstItemFocusNode;

  const _CategoriesChips({required this.type, required this.firstItemFocusNode});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    return Consumer<ContentProvider>(
      builder: (context, provider, _) {
        final status = provider.categoriesStatusFor(type);
        final error = provider.categoriesErrorFor(type);
        final categories = provider.categoriesFor(type);
        final selectedId = provider.selectedCategoryIdFor(type);

        if (status == LoadStatus.loading && categories.isEmpty) {
          return SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.m,
                vertical: AppSpacing.s,
              ),
              itemCount: 6,
              separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.s),
              itemBuilder: (context, index) => const SkeletonChip(),
            ),
          );
        }

        if (status == LoadStatus.error && categories.isEmpty) {
          return SizedBox(
            height: 56,
            child: _ErrorRetry(
              message: error ?? 'Erro ao carregar categorias.',
              onRetry: () => context.read<ContentProvider>().refresh(type),
              compact: true,
            ),
          );
        }

        if (categories.isEmpty) {
          return const SizedBox.shrink();
        }

        return SizedBox(
          height: 56,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.m,
              vertical: AppSpacing.s,
            ),
            itemCount: categories.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.s),
            itemBuilder: (context, index) {
              final category = categories[index];
              final selected = category.id == selectedId;
              // Mesmo raciocínio de _CategoriesSidebar: "Todos" nunca é
              // travável.
              final lockable = category.id != ContentProvider.allCategoriesId;
              final protectedCategory = lockable && settings.isProtectedCategory(type, category.id);

              return DpadFocusHighlight(
                key: ValueKey('chip_category_${type.name}_${category.id}'),
                focusNode: index == 0 ? firstItemFocusNode : null,
                scaleOnFocus: false,
                borderRadius: BorderRadius.circular(20),
                builder: (context, focusNode, hasFocus) => ChoiceChip(
                  focusNode: focusNode,
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(category.name),
                      if (lockable && settings.hasPin) ...[
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () => _toggleCategoryLock(context, type, category.id),
                          child: Icon(
                            protectedCategory ? Icons.lock : Icons.lock_open,
                            size: 14,
                            color: protectedCategory ? AppTheme.primaryColor : Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ],
                  ),
                  selected: selected,
                  onSelected: (_) => _selectCategoryGated(context, type, category.id),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// Live TV
// ---------------------------------------------------------------------

class _LiveStreamsPanel extends StatelessWidget {
  /// Filtro local (item 3 do ajuste de UI) — sempre aplicado em cima de
  /// [TabState.streams] já carregado, nunca dispara chamada de rede nova
  /// (ver _LiveTabView/_LiveSearchField).
  final String searchQuery;

  /// Quando true, mostra só os canais favoritados (ver botão de coração da
  /// AppBar em _HomeScreenBodyState).
  final bool favoritesOnly;

  const _LiveStreamsPanel({this.searchQuery = '', this.favoritesOnly = false});

  @override
  Widget build(BuildContext context) {
    return Consumer<ContentProvider>(
      builder: (context, provider, _) {
        final state = provider.live;
        final favorites = context.watch<FavoritesProvider>();
        final settings = context.watch<SettingsProvider>();
        // Lido uma vez aqui (não dentro do itemBuilder da lista) e repassado
        // pronto pra cada _EpgSubtitle -- evita um context.read novo por
        // linha a cada rebuild da lista inteira.
        final apiService = context.read<AuthProvider>().apiService;

        if (state.selectedCategoryId == null) {
          return const _EmptyHint(
            icon: Icons.live_tv,
            message: 'Selecione uma categoria para ver os canais.',
          );
        }

        if (state.streamsStatus == LoadStatus.loading &&
            state.streams.isEmpty) {
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s),
            itemCount: 8,
            itemBuilder: (context, index) => const SkeletonListRow(),
          );
        }

        if (state.streamsStatus == LoadStatus.error && state.streams.isEmpty) {
          return _ErrorRetry(
            message: state.streamsError ?? 'Erro ao carregar os canais.',
            onRetry: () =>
                context.read<ContentProvider>().refresh(ContentType.live),
          );
        }

        if (state.streams.isEmpty) {
          return const _EmptyHint(
            icon: Icons.live_tv_outlined,
            message: 'Nenhum canal nesta categoria.',
          );
        }

        final query = searchQuery.trim().toLowerCase();
        var filtered = query.isEmpty
            ? state.streams
            : state.streams
                .where((channel) => channel.name.toLowerCase().contains(query))
                .toList();
        if (favoritesOnly) {
          filtered = filtered
              .where((channel) => favorites.isFavorite(ContentType.live, channel.streamId.toString()))
              .toList();
        }
        // Tira os canais de categorias travadas -- essencial em "Todos"
        // (que agrega tudo numa chamada só, ver ContentProvider), senão o
        // cadeado da categoria não protegeria nada de verdade ali.
        filtered = filtered.where((channel) => !settings.isLocked(ContentType.live, channel.categoryId)).toList();

        if (filtered.isEmpty) {
          return _EmptyHint(
            icon: favoritesOnly ? Icons.favorite_border : Icons.search_off,
            message: switch ((favoritesOnly, query.isEmpty)) {
              (true, true) => 'Nenhum canal favoritado ainda.',
              (true, false) => 'Nenhum canal favoritado encontrado para "${searchQuery.trim()}".',
              (false, _) => 'Nenhum canal encontrado para "${searchQuery.trim()}".',
            },
          );
        }

        // Canais com tag de qualidade (FHD/HD/SD) no nome viram cards num
        // grid, no mesmo padrão visual de VOD/Séries (mesmo _PosterCard,
        // mesmas dimensões/raio/espaçamento — ver AppCardSizes.
        // posterGridDelegate); os demais continuam na lista simples de
        // sempre. Os dois convivem no MESMO scroll (CustomScrollView),
        // nunca dois scrolls independentes um do lado do outro.
        final cardChannels = <LiveStream>[];
        final listChannels = <LiveStream>[];
        for (final channel in filtered) {
          if (parseChannelQuality(channel.name) != null) {
            cardChannels.add(channel);
          } else {
            listChannels.add(channel);
          }
        }

        return CustomScrollView(
          slivers: [
            if (cardChannels.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.m,
                  AppSpacing.m,
                  AppSpacing.m,
                  AppSpacing.s,
                ),
                sliver: SliverGrid(
                  gridDelegate: AppCardSizes.posterGridDelegate,
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final channel = cardChannels[index];
                      final quality = parseChannelQuality(channel.name)!;
                      final channelId = channel.streamId.toString();

                      return DpadFocusHighlight(
                        key: ValueKey('live_stream_card_${channel.streamId}'),
                        builder: (context, focusNode, hasFocus) => _PosterCard(
                          focusNode: focusNode,
                          title: channel.name,
                          imageUrl: channel.streamIcon,
                          fallbackIcon: Icons.tv,
                          rating: 0,
                          titleStyle: AppTheme.liveChannelNameStyle,
                          topLeftBadge: QualityBadge(quality: quality),
                          isFavorite: favorites.isFavorite(ContentType.live, channelId),
                          onToggleFavorite: () =>
                              context.read<FavoritesProvider>().toggleFavorite(ContentType.live, channelId),
                          onTap: () => _playLiveChannel(context, channel),
                        ),
                      );
                    },
                    childCount: cardChannels.length,
                  ),
                ),
              ),
            if (listChannels.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.s),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final channel = listChannels[index];
                      final channelId = channel.streamId.toString();
                      final isFavorite = favorites.isFavorite(ContentType.live, channelId);

                      return DpadFocusHighlight(
                        key: ValueKey('live_stream_${channel.streamId}'),
                        scaleOnFocus: false,
                        borderRadius: BorderRadius.circular(4),
                        builder: (context, focusNode, hasFocus) => ListTile(
                          focusNode: focusNode,
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          leading: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              _StreamThumb(
                                url: channel.streamIcon,
                                fallbackIcon: Icons.tv,
                                size: AppCardSizes.liveThumbSize,
                                shape: BoxShape.circle,
                              ),
                              const Positioned(
                                right: -2,
                                bottom: -2,
                                child: _LivePulseBadge(),
                              ),
                            ],
                          ),
                          title: Text(
                            channel.name,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.liveChannelNameStyle,
                          ),
                          subtitle: apiService == null
                              ? null
                              : _EpgSubtitle(apiService: apiService, streamId: channel.streamId),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (channel.tvArchive)
                                const Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: Icon(Icons.replay_circle_filled_outlined, size: 18),
                                ),
                              GestureDetector(
                                onTap: () => context
                                    .read<FavoritesProvider>()
                                    .toggleFavorite(ContentType.live, channelId),
                                child: Icon(
                                  isFavorite ? Icons.favorite : Icons.favorite_border,
                                  size: 18,
                                  color: isFavorite ? AppTheme.primaryColor : null,
                                ),
                              ),
                            ],
                          ),
                          onTap: () => _playLiveChannel(context, channel),
                        ),
                      );
                    },
                    childCount: listChannels.length,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// VOD (filmes)
// ---------------------------------------------------------------------

class _VodGrid extends StatelessWidget {
  /// Filtro local (mesmo padrão da Live TV, ver _LiveStreamsPanel) — sempre
  /// aplicado em cima de [TabState.streams] já carregado, nunca dispara
  /// chamada de rede nova.
  final String searchQuery;

  /// Quando true, mostra só os filmes favoritados (ver botão de coração da
  /// AppBar em _HomeScreenBodyState) -- outro filtro local, composto com
  /// [searchQuery] em cima do mesmo [TabState.streams] já carregado.
  final bool favoritesOnly;

  const _VodGrid({this.searchQuery = '', this.favoritesOnly = false});

  @override
  Widget build(BuildContext context) {
    return Consumer<ContentProvider>(
      builder: (context, provider, _) {
        final state = provider.vod;
        final favorites = context.watch<FavoritesProvider>();
        final settings = context.watch<SettingsProvider>();

        if (state.selectedCategoryId == null) {
          return const _EmptyHint(
            icon: Icons.movie_outlined,
            message: 'Selecione uma categoria para ver os filmes.',
          );
        }

        if (state.streamsStatus == LoadStatus.loading &&
            state.streams.isEmpty) {
          return const _PosterGridSkeleton();
        }

        if (state.streamsStatus == LoadStatus.error && state.streams.isEmpty) {
          return _ErrorRetry(
            message: state.streamsError ?? 'Erro ao carregar os filmes.',
            onRetry: () =>
                context.read<ContentProvider>().refresh(ContentType.vod),
          );
        }

        if (state.streams.isEmpty) {
          return const _EmptyHint(
            icon: Icons.movie_outlined,
            message: 'Nenhum filme nesta categoria.',
          );
        }

        final query = searchQuery.trim().toLowerCase();
        var movies = query.isEmpty
            ? state.streams
            : state.streams.where((movie) => movie.name.toLowerCase().contains(query)).toList();
        if (favoritesOnly) {
          movies = movies
              .where((movie) => favorites.isFavorite(ContentType.vod, movie.streamId.toString()))
              .toList();
        }
        // Mesmo raciocínio de _LiveStreamsPanel: essencial em "Todos".
        movies = movies.where((movie) => !settings.isLocked(ContentType.vod, movie.categoryId)).toList();

        if (movies.isEmpty) {
          return _EmptyHint(
            icon: favoritesOnly ? Icons.favorite_border : Icons.search_off,
            message: switch ((favoritesOnly, query.isEmpty)) {
              (true, true) => 'Nenhum filme favoritado ainda.',
              (true, false) => 'Nenhum filme favoritado encontrado para "${searchQuery.trim()}".',
              (false, _) => 'Nenhum filme encontrado para "${searchQuery.trim()}".',
            },
          );
        }

        // Destaque só faz sentido em cima da lista "inteira" da categoria
        // (sem filtro nenhum aplicado ainda) -- durante busca/"só
        // favoritos", mostrar um "destaque" que pode nem bater com o filtro
        // seria estranho (ver _FeaturedBanner).
        final featured = (!favoritesOnly && query.isEmpty)
            ? movies.reduce((a, b) => b.rating > a.rating ? b : a)
            : null;

        return CustomScrollView(
          // VOD/Séries podem ter centenas de itens por categoria — um
          // cacheExtent moderado mantém uma folga de linhas pré-construídas
          // fora da viewport (rolagem mais suave, menos rebuild a cada
          // frame) sem carregar imagens demais de uma vez.
          scrollCacheExtent: const ScrollCacheExtent.pixels(500),
          slivers: [
            if (featured != null)
              SliverToBoxAdapter(
                child: _FeaturedBanner(
                  title: featured.name,
                  imageUrl: featured.streamIcon,
                  rating: featured.rating,
                  fallbackIcon: Icons.movie,
                  onTap: () => _openVodDetails(context, featured),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.all(AppSpacing.m),
              sliver: SliverGrid(
                gridDelegate: AppCardSizes.posterGridDelegate,
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final movie = movies[index];
                    final movieId = movie.streamId.toString();

                    return DpadFocusHighlight(
                      key: ValueKey('vod_stream_${movie.streamId}'),
                      builder: (context, focusNode, hasFocus) => _PosterCard(
                        focusNode: focusNode,
                        title: movie.name,
                        imageUrl: movie.streamIcon,
                        fallbackIcon: Icons.movie,
                        rating: movie.rating,
                        topLeftBadge: _isRecentlyAdded(movie.added) ? const NewBadge() : null,
                        isFavorite: favorites.isFavorite(ContentType.vod, movieId),
                        onToggleFavorite: () =>
                            context.read<FavoritesProvider>().toggleFavorite(ContentType.vod, movieId),
                        onTap: () => _openVodDetails(context, movie),
                      ),
                    );
                  },
                  childCount: movies.length,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// Séries
// ---------------------------------------------------------------------

class _SeriesGrid extends StatelessWidget {
  /// Filtro local (mesmo padrão da Live TV, ver _LiveStreamsPanel) — sempre
  /// aplicado em cima de [TabState.streams] já carregado, nunca dispara
  /// chamada de rede nova.
  final String searchQuery;

  /// Quando true, mostra só as séries favoritadas (ver botão de coração da
  /// AppBar em _HomeScreenBodyState).
  final bool favoritesOnly;

  const _SeriesGrid({this.searchQuery = '', this.favoritesOnly = false});

  @override
  Widget build(BuildContext context) {
    return Consumer<ContentProvider>(
      builder: (context, provider, _) {
        final state = provider.series;
        final favorites = context.watch<FavoritesProvider>();
        final settings = context.watch<SettingsProvider>();

        if (state.selectedCategoryId == null) {
          return const _EmptyHint(
            icon: Icons.video_library_outlined,
            message: 'Selecione uma categoria para ver as séries.',
          );
        }

        if (state.streamsStatus == LoadStatus.loading &&
            state.streams.isEmpty) {
          return const _PosterGridSkeleton();
        }

        if (state.streamsStatus == LoadStatus.error && state.streams.isEmpty) {
          return _ErrorRetry(
            message: state.streamsError ?? 'Erro ao carregar as séries.',
            onRetry: () =>
                context.read<ContentProvider>().refresh(ContentType.series),
          );
        }

        if (state.streams.isEmpty) {
          return const _EmptyHint(
            icon: Icons.video_library_outlined,
            message: 'Nenhuma série nesta categoria.',
          );
        }

        final query = searchQuery.trim().toLowerCase();
        var shows = query.isEmpty
            ? state.streams
            : state.streams.where((show) => show.name.toLowerCase().contains(query)).toList();
        if (favoritesOnly) {
          shows = shows
              .where((show) => favorites.isFavorite(ContentType.series, show.seriesId.toString()))
              .toList();
        }
        // Mesmo raciocínio de _LiveStreamsPanel: essencial em "Todos".
        shows = shows.where((show) => !settings.isLocked(ContentType.series, show.categoryId)).toList();

        if (shows.isEmpty) {
          return _EmptyHint(
            icon: favoritesOnly ? Icons.favorite_border : Icons.search_off,
            message: switch ((favoritesOnly, query.isEmpty)) {
              (true, true) => 'Nenhuma série favoritada ainda.',
              (true, false) => 'Nenhuma série favoritada encontrada para "${searchQuery.trim()}".',
              (false, _) => 'Nenhuma série encontrada para "${searchQuery.trim()}".',
            },
          );
        }

        final featured = (!favoritesOnly && query.isEmpty)
            ? shows.reduce((a, b) => b.rating > a.rating ? b : a)
            : null;

        return CustomScrollView(
          // VOD/Séries podem ter centenas de itens por categoria — um
          // cacheExtent moderado mantém uma folga de linhas pré-construídas
          // fora da viewport (rolagem mais suave, menos rebuild a cada
          // frame) sem carregar imagens demais de uma vez.
          scrollCacheExtent: const ScrollCacheExtent.pixels(500),
          slivers: [
            if (featured != null)
              SliverToBoxAdapter(
                child: _FeaturedBanner(
                  title: featured.name,
                  imageUrl: featured.cover,
                  rating: featured.rating,
                  fallbackIcon: Icons.video_library,
                  onTap: () => _openSeriesDetails(context, featured),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.all(AppSpacing.m),
              sliver: SliverGrid(
                gridDelegate: AppCardSizes.posterGridDelegate,
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final show = shows[index];
                    final seriesId = show.seriesId.toString();

                    return DpadFocusHighlight(
                      key: ValueKey('series_${show.seriesId}'),
                      builder: (context, focusNode, hasFocus) => _PosterCard(
                        focusNode: focusNode,
                        title: show.name,
                        imageUrl: show.cover,
                        fallbackIcon: Icons.video_library,
                        rating: show.rating,
                        isFavorite: favorites.isFavorite(ContentType.series, seriesId),
                        onToggleFavorite: () =>
                            context.read<FavoritesProvider>().toggleFavorite(ContentType.series, seriesId),
                        onTap: () => _openSeriesDetails(context, show),
                      ),
                    );
                  },
                  childCount: shows.length,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

void _openSeriesDetails(BuildContext context, Series series) {
  final continueWatching = context.read<ContinueWatchingProvider>();
  Navigator.of(
    context,
  ).push(fadeSlideRoute((_) => SeriesDetailsScreen(series: series))).then((_) {
    // A série pode ter episódios assistidos via a própria SeriesDetailsScreen
    // (que empurra o Player por cima) — recarrega ao voltar pra Home pra
    // refletir isso na prateleira, mesmo raciocínio de _openVodDetails abaixo.
    continueWatching.load();
  });
}

/// Guarda o instante do último toque efetivado em [_playLiveChannel] —
/// protege contra double-tap (touch) ou Enter repetido rápido no D-Pad
/// empilhando duas telas de player (duas chamadas a `Navigator.push` para
/// o mesmo canal ou dois canais em sequência) antes da transição de tela
/// completar. Variável de módulo (não campo de State) porque
/// `_playLiveChannel` é uma função livre chamada a partir de `onTap` em
/// vários pontos da árvore (grid de cards e lista simples, ver
/// `_LiveStreamsPanel`), sem um `State` único que a possua.
DateTime? _lastLiveChannelTapAt;

/// Janela mínima entre duas navegações efetivas para o player a partir da
/// lista de Live TV — toques dentro desta janela são ignorados.
const _liveChannelTapDebounce = Duration(milliseconds: 350);

void _playLiveChannel(BuildContext context, LiveStream channel) {
  final now = DateTime.now();
  if (_lastLiveChannelTapAt != null &&
      now.difference(_lastLiveChannelTapAt!) < _liveChannelTapDebounce) {
    return;
  }
  _lastLiveChannelTapAt = now;

  final apiService = context.read<AuthProvider>().apiService;
  if (apiService == null) return;

  // Cadeia de URLs alternativas (TS direto -> HLS direto -> get.php TS ->
  // get.php HLS) que o PlaybackHealthMonitor percorre sozinho se a
  // reprodução falhar — só para Live TV por enquanto (VOD/série continuam
  // com o fluxo atual, sem fallbackUrls, ver VodDetailsScreen._play).
  final fallbackUrls = StreamUrlBuilder.buildFallbackChain(
    dns: apiService.dns,
    username: apiService.username,
    password: apiService.password,
    streamId: channel.streamId.toString(),
    contentType: StreamContentType.live,
  );

  // Live TV nunca gera progresso salvo (sem contentId/progressType aqui,
  // ver PlayerProvider) — nada a recarregar ao voltar.
  Navigator.of(context).push(fadeSlideRoute((_) => PlayerScreen(
        url: fallbackUrls.first,
        fallbackUrls: fallbackUrls,
        title: channel.name,
      )));
}

/// Seleciona [categoryId] normalmente, A NÃO SER que esteja travada por PIN
/// (ver SettingsProvider.isLocked) -- nesse caso pede o PIN antes,
/// desbloqueia pra ESTA sessão (SettingsProvider.unlockForSession, nunca
/// persistido) só depois de confirmado, e só então seleciona. PIN errado ou
/// diálogo cancelado: não seleciona nada, categoria continua travada.
Future<void> _selectCategoryGated(BuildContext context, ContentType type, String categoryId) async {
  final settings = context.read<SettingsProvider>();
  final contentProvider = context.read<ContentProvider>();

  if (!settings.isLocked(type, categoryId)) {
    contentProvider.selectCategory(type, categoryId);
    return;
  }

  final pin = await showEnterPinDialog(context, title: 'Digite o PIN pra ver esta categoria');
  if (pin == null || !context.mounted) return;

  final valid = await settings.verifyPin(pin);
  if (!context.mounted) return;
  if (!valid) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN incorreto.')));
    return;
  }

  settings.unlockForSession(type, categoryId);
  contentProvider.selectCategory(type, categoryId);
}

/// Alterna o cadeado de [categoryId] -- TRAVAR não pede PIN (sempre
/// permitido, "fechar a porta" nunca precisa da chave). DESTRAVAR pede o
/// PIN antes de tirar a proteção, senão o cadeado seria decorativo: bastaria
/// tocar nele de novo pra desproteger sem confirmar nada.
Future<void> _toggleCategoryLock(BuildContext context, ContentType type, String categoryId) async {
  final settings = context.read<SettingsProvider>();

  if (!settings.isProtectedCategory(type, categoryId)) {
    settings.toggleProtectedCategory(type, categoryId);
    return;
  }

  final pin = await showEnterPinDialog(context, title: 'Digite o PIN pra destravar esta categoria');
  if (pin == null || !context.mounted) return;

  final valid = await settings.verifyPin(pin);
  if (!context.mounted) return;
  if (!valid) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN incorreto.')));
    return;
  }

  settings.toggleProtectedCategory(type, categoryId);
}

/// Abre a ficha do filme (VodDetailsScreen) em vez de tocar direto -- mesmo
/// padrão de _openSeriesDetails logo acima. A reprodução em si (URL/Player)
/// agora vive dentro da própria VodDetailsScreen (ver seu método `_play`).
void _openVodDetails(BuildContext context, VodStream movie) {
  final continueWatching = context.read<ContinueWatchingProvider>();
  Navigator.of(context).push(fadeSlideRoute((_) => VodDetailsScreen(movie: movie))).then((_) {
    // O filme pode ter sido assistido/progredido via a própria
    // VodDetailsScreen (que empurra o Player por cima) -- recarrega ao
    // voltar pra Home pra refletir isso na prateleira, mesmo raciocínio de
    // _openSeriesDetails.
    continueWatching.load();
  });
}

/// Abre um item da seção "Continuar Assistindo" — a URL/contentId/tipo já
/// vêm prontos do [WatchProgress] salvo, sem precisar reconstruir nada a
/// partir de credenciais/IDs (ver WatchProgress.playbackUrl).
void _playContinueWatching(BuildContext context, WatchProgress progress) {
  final continueWatching = context.read<ContinueWatchingProvider>();

  Navigator.of(context)
      .push(
        fadeSlideRoute(
          (_) => PlayerScreen(
            url: progress.playbackUrl,
            title: progress.title,
            contentId: progress.contentId,
            imageUrl: progress.imageUrl,
            progressType: progress.type,
            startAtSeconds: progress.positionSeconds.toDouble(),
          ),
        ),
      )
      .then((_) => continueWatching.load());
}

// ---------------------------------------------------------------------
// Widgets compartilhados
// ---------------------------------------------------------------------

/// Placeholder de carregamento para o grid de VOD/Séries — mesmo
/// `gridDelegate`/padding do grid real (ver AppCardSizes.posterGridDelegate,
/// compartilhado entre os dois grids reais e este skeleton).
class _PosterGridSkeleton extends StatelessWidget {
  const _PosterGridSkeleton();

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(AppSpacing.m),
      gridDelegate: AppCardSizes.posterGridDelegate,
      itemCount: 12,
      itemBuilder: (context, index) => const SkeletonPosterCard(),
    );
  }
}

class _PosterCard extends StatelessWidget {
  final String title;
  final String imageUrl;
  final IconData fallbackIcon;
  final double rating;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  /// 0.0-1.0 — quando não nulo, sobrepõe uma barra fina de progresso na
  /// base do pôster (usado só pela seção "Continuar Assistindo"; `null` em
  /// todo o resto do app, onde o card não representa progresso nenhum).
  final double? progressFraction;

  /// Selo extra no canto SUPERIOR ESQUERDO do pôster (ex: [QualityBadge]
  /// dos canais de Live TV, ver _LiveStreamsPanel) — `null` em VOD/Séries/
  /// Continuar Assistindo, que só usam o selo de nota (canto superior
  /// direito, ver [rating]).
  final Widget? topLeftBadge;

  /// Estilo do título abaixo do pôster — default [AppTheme.cardTitleStyle]
  /// (mesmo de sempre em VOD/Séries/Continuar Assistindo). Live TV passa
  /// [AppTheme.liveChannelNameStyle], menor.
  final TextStyle? titleStyle;

  /// `null` (nos dois) = sem coração nenhum -- usado pela aba "Continuar
  /// Assistindo", que reaproveita este mesmo card mas não tem noção de
  /// favorito (ver HomeScreen._ContinueWatchingGrid). Toque/mouse apenas de
  /// propósito (sem FocusNode próprio) -- não vira um segundo parada de
  /// foco no D-Pad dentro do card, que já tem sua navegação por grid
  /// própria; ver AppBar "Só favoritos" (_HomeScreenBodyState) como o
  /// caminho 100% navegável por D-Pad pra ver/filtrar favoritos.
  final bool? isFavorite;
  final VoidCallback? onToggleFavorite;

  const _PosterCard({
    required this.title,
    required this.imageUrl,
    required this.fallbackIcon,
    required this.rating,
    required this.onTap,
    this.focusNode,
    this.progressFraction,
    this.topLeftBadge,
    this.titleStyle,
    this.isFavorite,
    this.onToggleFavorite,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      focusNode: focusNode,
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _PosterImage(
                    url: imageUrl,
                    fallbackIcon: fallbackIcon,
                  ),
                ),
                if (rating > 0)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _RatingBadge(rating: rating),
                  ),
                if (topLeftBadge != null)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: topLeftBadge!,
                  ),
                if (progressFraction != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _ProgressBar(fraction: progressFraction!),
                  ),
                if (isFavorite != null && onToggleFavorite != null)
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: _FavoriteToggle(
                      isFavorite: isFavorite!,
                      onPressed: onToggleFavorite!,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: titleStyle ?? AppTheme.cardTitleStyle,
          ),
        ],
      ),
    );
  }
}

class _PosterImage extends StatelessWidget {
  final String url;
  final IconData fallbackIcon;

  const _PosterImage({required this.url, required this.fallbackIcon});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: AppTheme.surfaceColor,
      alignment: Alignment.center,
      child: Icon(fallbackIcon, size: AppCardSizes.posterFallbackIconSize, color: Colors.grey.shade500),
    );

    return NetworkImageWithFallback(
      url: url,
      fallback: fallback,
      // 3x a largura lógica do pôster (AppCardSizes.posterGridMaxExtent) —
      // mesma proporção de antes desta constante existir, cobrindo telas de
      // até devicePixelRatio 3 sem decodificar mais pixels do que o card
      // consegue exibir.
      cacheWidth: (AppCardSizes.posterGridMaxExtent * 3).round(),
    );
  }
}

class _StreamThumb extends StatelessWidget {
  final String url;
  final IconData fallbackIcon;
  final double size;
  final BoxShape shape;

  const _StreamThumb({
    required this.url,
    required this.fallbackIcon,
    this.size = 40,
    this.shape = BoxShape.rectangle,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        shape: shape,
        borderRadius: shape == BoxShape.rectangle
            ? BorderRadius.circular(6)
            : null,
      ),
      child: Icon(fallbackIcon, color: Colors.grey.shade500, size: size * 0.55),
    );

    return ClipRRect(
      borderRadius: shape == BoxShape.circle
          ? BorderRadius.circular(size / 2)
          : BorderRadius.circular(6),
      child: NetworkImageWithFallback(
        url: url,
        fallback: fallback,
        width: size,
        height: size,
        // 3x o tamanho lógico exibido (mesma regra de _PosterImage) — cobre
        // devicePixelRatio até 3 sem decodificar mais que o necessário. Fixa
        // também cacheHeight (não só cacheWidth): a caixa é sempre quadrada
        // aqui, mas o logo de origem raramente é 1:1, então sem isso o
        // decoder infere a altura pela proporção ORIGINAL da imagem em vez
        // da proporção da caixa.
        cacheWidth: (size * 3).round(),
        cacheHeight: (size * 3).round(),
      ),
    );
  }
}

/// Indicador pulsante de "ao vivo" sobreposto no canto da miniatura de um
/// canal — só o ponto (equivalente compacto de "● AO VIVO": o texto por
/// extenso não cabe legível num badge de poucos pixels sobre uma miniatura
/// de 40px). Opacidade oscilando entre 0.6 e 1.0 a cada ~1.5s, sutil o
/// bastante pra não competir com o resto da lista.
/// Subtítulo "Agora: X (HH:mm-HH:mm) · A seguir: Y" de um canal na lista
/// simples de Live TV (ver `_LiveStreamsPanel`) -- busca `get_short_epg`
/// SOB DEMANDA, só quando esta linha específica é construída (a
/// `ListView.builder` só constrói o que está visível na tela, então rolar a
/// lista é o que naturalmente limita quantos canais pedem EPG de uma vez,
/// nunca todos de uma categoria inteira num único carregamento).
///
/// Nunca bloqueia nem quebra a linha do canal: enquanto carrega ou se o
/// painel não suportar/EPG falhar, simplesmente não mostra nada (mesmo
/// espírito do "erro só da sinopse" em VodDetailsScreen -- informação
/// secundária, não pode atrapalhar o essencial).
class _EpgSubtitle extends StatefulWidget {
  final XtreamApiService apiService;
  final int streamId;

  const _EpgSubtitle({required this.apiService, required this.streamId});

  @override
  State<_EpgSubtitle> createState() => _EpgSubtitleState();
}

class _EpgSubtitleState extends State<_EpgSubtitle> {
  /// Cache em memória, por streamId, COMPARTILHADO entre todas as
  /// instâncias desta sessão (não por-widget) -- rolar pra cima/baixo na
  /// lista (o que descarta e reconstrói as linhas fora da viewport) não
  /// repete a chamada de rede pro mesmo canal ao voltar pra tela.
  static final Map<int, List<EpgProgram>> _cache = {};

  List<EpgProgram>? _programs;

  @override
  void initState() {
    super.initState();
    final cached = _cache[widget.streamId];
    if (cached != null) {
      _programs = cached;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final programs = await widget.apiService.getShortEpg(widget.streamId.toString());
      _cache[widget.streamId] = programs;
      if (mounted) setState(() => _programs = programs);
    } catch (_) {
      // Painel sem suporte a EPG, ou erro de rede -- some silenciosamente
      // (ver doc da classe).
    }
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final programs = _programs;
    if (programs == null || programs.isEmpty) return const SizedBox.shrink();

    final now = programs.first;
    final next = programs.length > 1 ? programs[1] : null;

    final text = StringBuffer('Agora: ${now.title}');
    if (now.start != null && now.end != null) {
      text.write(' (${_formatTime(now.start!)}-${_formatTime(now.end!)})');
    }
    if (next != null && next.title.isNotEmpty) {
      text.write(' · A seguir: ${next.title}');
    }

    return Text(
      text.toString(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
    );
  }
}

class _LivePulseBadge extends StatefulWidget {
  const _LivePulseBadge();

  @override
  State<_LivePulseBadge> createState() => _LivePulseBadgeState();
}

class _LivePulseBadgeState extends State<_LivePulseBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween<double>(
    begin: 0.6,
    end: 1,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Ao vivo',
      child: FadeTransition(
        opacity: _opacity,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: AppTheme.errorColor,
            shape: BoxShape.circle,
            border: Border.all(color: AppTheme.backgroundColor, width: 1.5),
          ),
        ),
      ),
    );
  }
}

/// Card grande de destaque no topo de VOD/Séries (ver _VodGrid/_SeriesGrid)
/// -- reaproveita SEMPRE dados já carregados (o item com maior nota da
/// categoria/busca atual), nenhuma chamada de rede extra. Some sozinho
/// durante busca/"só favoritos" (ver os dois call sites): faria pouco
/// sentido "destacar" algo enquanto o usuário já está filtrando por outra
/// coisa.
class _FeaturedBanner extends StatelessWidget {
  final String title;
  final String imageUrl;
  final double rating;
  final IconData fallbackIcon;
  final VoidCallback onTap;

  const _FeaturedBanner({
    required this.title,
    required this.imageUrl,
    required this.rating,
    required this.fallbackIcon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.m, AppSpacing.m, AppSpacing.m, 0),
      child: DpadFocusHighlight(
        borderRadius: BorderRadius.circular(12),
        builder: (context, focusNode, hasFocus) => InkWell(
          focusNode: focusNode,
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 180,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NetworkImageWithFallback(
                    url: imageUrl,
                    fallback: Container(
                      color: AppTheme.surfaceColor,
                      alignment: Alignment.center,
                      child: Icon(fallbackIcon, size: 48, color: Colors.grey.shade600),
                    ),
                  ),
                  // Só um scrim escurecendo a BASE (onde fica o texto) --
                  // nunca a imagem inteira, pra continuar reconhecível.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [0.4, 1.0],
                        colors: [Colors.transparent, Colors.black87],
                      ),
                    ),
                  ),
                  Positioned(
                    top: 12,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'DESTAQUE',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        if (rating > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.star, size: 14, color: Colors.amber),
                                const SizedBox(width: 4),
                                Text(rating.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontSize: 13)),
                              ],
                            ),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.play_circle_fill, size: 20, color: AppTheme.primaryColor),
                            const SizedBox(width: 6),
                            const Text(
                              'Assistir',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RatingBadge extends StatelessWidget {
  final double rating;

  const _RatingBadge({required this.rating});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(180),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, size: 12, color: Colors.amber),
          const SizedBox(width: 2),
          Text(
            rating.toStringAsFixed(1),
            style: const TextStyle(fontSize: 11, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// Coração de favoritar sobreposto no canto inferior direito de um pôster
/// (ver _PosterCard.isFavorite/onToggleFavorite) — `GestureDetector` PRÓPRIO
/// (não outro `InkWell`) de propósito: fica dentro do `InkWell` maior do
/// card inteiro (que toca/reproduz), e o Flutter resolve o toque pro
/// gesture recognizer mais interno automaticamente, sem precisar de
/// `HitTestBehavior` nem `Listener` explícitos.
class _FavoriteToggle extends StatelessWidget {
  final bool isFavorite;
  final VoidCallback onPressed;

  const _FavoriteToggle({required this.isFavorite, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(180),
          shape: BoxShape.circle,
        ),
        child: Icon(
          isFavorite ? Icons.favorite : Icons.favorite_border,
          size: 14,
          color: isFavorite ? AppTheme.primaryColor : Colors.white,
        ),
      ),
    );
  }
}

/// Barra fina de progresso sobreposta na base de um pôster — usada só pela
/// seção "Continuar Assistindo" (ver _PosterCard.progressFraction). Um
/// fundo semitransparente sob a barra em si garante contraste mesmo sobre
/// capas muito claras.
class _ProgressBar extends StatelessWidget {
  final double fraction;

  const _ProgressBar({required this.fraction});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 4,
      color: Colors.black.withAlpha(120),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: fraction.clamp(0, 1),
        child: Container(color: AppTheme.primaryColor),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String message;

  const _EmptyHint({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StateIllustration(icon: icon),
            const SizedBox(height: AppSpacing.m),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade400),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final bool compact;

  const _ErrorRetry({
    required this.message,
    required this.onRetry,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Center(
        child: TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: Text(message, overflow: TextOverflow.ellipsis),
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const StateIllustration(icon: Icons.error_outline, isError: true),
            const SizedBox(height: AppSpacing.m),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.l),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar novamente'),
            ),
          ],
        ),
      ),
    );
  }
}
