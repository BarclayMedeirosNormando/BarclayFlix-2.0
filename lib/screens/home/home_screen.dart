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
import '../../providers/auth_provider.dart';
import '../../providers/content_provider.dart';
import '../../providers/continue_watching_provider.dart';
import '../../providers/profiles_provider.dart';
import '../../services/stream_url_builder.dart';
import '../../widgets/category_filter_header.dart';
import '../../widgets/dpad_focus_highlight.dart';
import '../../widgets/network_image_with_fallback.dart';
import '../../widgets/quality_badge.dart';
import '../../widgets/skeleton_loader.dart';
import '../../widgets/state_illustration.dart';
import '../player/player_screen.dart';
import '../series_details/series_details_screen.dart';
import '../activation/activation_screen.dart';
import '../server_selection/server_selection_screen.dart';

/// Abaixo desta largura a seleção de categoria vira uma barra horizontal de
/// chips no topo; acima disso vira uma sidebar fixa à esquerda.
const double _sidebarBreakpoint = 700;

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

class _HomeScreenBodyState extends State<_HomeScreenBody>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // Nó nomeado (não anônimo) de propósito: dá pra um teste de widget pegar
  // este `Focus` especificamente (via `find.byWidgetPredicate` + o próprio
  // `focusNode`) e afirmar `hasFocus == true` sem precisar chamar
  // `requestFocus()` manualmente — é isso que prova que o autofoco desta
  // tela funciona sozinho. Mesmo padrão já usado em `_inputFocusNode` da
  // PlayerScreen.
  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'home-screen-root');

  // Controla o "salto" único de foco do wrapper invisível acima pro
  // primeiro item de verdade (primeira categoria carregada), assim que ele
  // existir (ver `_handOffInitialFocusIfReady`). Nunca mais depois da
  // primeira vez, pra não arrancar o foco de onde o usuário estiver a cada
  // notifyListeners() do ContentProvider (troca de categoria, etc).
  bool _didHandOffInitialFocus = false;

  // Guardado à parte (em vez de `context.read<ContentProvider>()` de novo
  // em `dispose()`) de propósito: por volta do fim de um teste de widget
  // (ou de qualquer desmonte de árvore inteira), o Element desta tela pode
  // já estar desativado quando `dispose()` roda, e uma nova busca de
  // ancestral nesse momento é insegura ("Looking up a deactivated widget's
  // ancestor is unsafe" — achado rodando o teste). Guardar a referência
  // enquanto o contexto ainda está garantidamente ativo (`initState`) evita
  // essa busca tardia.
  late final ContentProvider _contentProvider = context.read<ContentProvider>();

  // Liga só durante a re-busca de servidores de "Trocar de servidor" (ver
  // `_switchServer`) -- troca o ícone da ação por um spinner pra dar
  // feedback de que algo está acontecendo em segundo plano, sem travar
  // (nem escurecer) o resto da tela com um dialog.
  bool _switchingServer = false;

  @override
  void initState() {
    super.initState();
    // +1: a aba "Continuar Assistindo" não corresponde a nenhum
    // [ContentType] (não tem categorias/sidebar, ver `_ensureCategoriesLoaded`
    // e `_ContinueWatchingTab`) — por isso não faz parte de `ContentType.values`.
    _tabController = TabController(
      length: ContentType.values.length + 1,
      vsync: this,
    );
    _tabController.addListener(_onTabSettled);
    // Carrega as categorias da primeira aba e o progresso de "Continuar
    // Assistindo" assim que a tela monta.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureCategoriesLoaded(0);
      context.read<ContinueWatchingProvider>().load();
    });
    // As categorias da primeira aba chegam de forma assíncrona (rede) —
    // escuta o ContentProvider pra saltar o foco assim que a sidebar/chips
    // tiverem o primeiro item de verdade pra focar (ver
    // `_handOffInitialFocusIfReady`).
    _contentProvider.addListener(_handOffInitialFocusIfReady);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabSettled);
    _tabController.dispose();
    _contentProvider.removeListener(_handOffInitialFocusIfReady);
    _rootFocusNode.dispose();
    super.dispose();
  }

  void _onTabSettled() {
    if (!_tabController.indexIsChanging) {
      _ensureCategoriesLoaded(_tabController.index);
    }
  }

  /// Salta o foco, uma única vez, do wrapper invisível (`_rootFocusNode`,
  /// ver `build` abaixo) pra primeira categoria carregada — sem isso, a
  /// primeira seta do D-Pad não move o foco pra lugar nenhum: esse wrapper
  /// fica FORA do `FocusTraversalGroup` da sidebar/chips, e busca
  /// DIRECIONAL (seta) não "entra" nele sozinha — só travessia por ORDEM
  /// (`nextFocus`, equivalente ao Tab) consegue atravessar essa fronteira
  /// (achado empírico rodando o teste que cobre esse cenário: ver "seta
  /// move o foco pra sidebar de categorias, mesmo sem nenhum foco manual
  /// antes").
  void _handOffInitialFocusIfReady() {
    if (_didHandOffInitialFocus) return;
    // A aba inicial é sempre Live TV (índice 0, ver `TabController` acima)
    // -- esta guarda é só defensiva, pra nunca indexar `ContentType.values`
    // fora dos limites caso o índice inicial mude no futuro.
    if (_tabController.index >= ContentType.values.length) return;
    final type = ContentType.values[_tabController.index];
    if (_contentProvider.categoriesFor(type).isEmpty) return;

    _didHandOffInitialFocus = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _rootFocusNode.nextFocus();
    });
  }

  void _ensureCategoriesLoaded(int index) {
    // Aba "Continuar Assistindo" não tem categorias (ver
    // `_ContinueWatchingTab`) -- nada a carregar aqui pra ela.
    if (index >= ContentType.values.length) return;
    context.read<ContentProvider>().loadCategories(ContentType.values[index]);
  }

  /// Não existe "logout" real neste app: a identidade é o dispositivo, não
  /// uma sessão de usuário/senha, então não há pra onde "deslogar" (ver
  /// CLAUDE.md/arquitetura de ativação por código). Este botão serve pra
  /// MIGRAR o aparelho pra outro cliente: limpa o perfil salvo (senão a
  /// SplashScreen revalidaria o mesmo cliente de novo na próxima abertura,
  /// tornando este botão inútil), encerra a sessão ativa em memória, e
  /// volta pra ActivationScreen com o código deste dispositivo pronto pra
  /// ser reenviado ao suporte.
  Future<void> _reactivateDevice(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reativar dispositivo?'),
        content: const Text(
          'Isso desvincula este aparelho do cliente atual. Você vai precisar enviar o código '
          'de ativação para o suporte de novo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reativar'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!context.mounted) return;

    await context.read<ProfilesProvider>().clearSavedProfile();
    if (!context.mounted) return;

    context.read<AuthProvider>().logout();

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const ActivationScreen()),
      (route) => false,
    );
  }

  /// DIFERENTE de [_reactivateDevice]: rebusca a lista de servidores
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
            title: const Text('BarclayFlix 2.0'),
            actions: [
              // Ícone/tooltip DELIBERADAMENTE distintos de "Sair" logo ao
              // lado -- swap_horiz (troca) em vez de logout (saída), pra
              // não serem confundidos: um mantém a sessão (só troca de
              // servidor), o outro encerra tudo.
              IconButton(
                icon: _switchingServer
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : const Icon(Icons.swap_horiz),
                tooltip: 'Trocar de servidor',
                onPressed: _switchingServer ? null : () => _switchServer(context),
              ),
              IconButton(
                icon: const Icon(Icons.restart_alt),
                tooltip: 'Reativar dispositivo',
                onPressed: () => _reactivateDevice(context),
              ),
            ],
            bottom: TabBar(
              controller: _tabController,
              tabs: const [
                Tab(icon: Icon(Icons.live_tv), text: 'Live TV'),
                Tab(icon: Icon(Icons.movie), text: 'Filmes'),
                Tab(icon: Icon(Icons.video_library), text: 'Séries'),
                Tab(icon: Icon(Icons.history), text: 'Continuar'),
              ],
            ),
          ),
          body: Focus(
            // Garante que exista foco de teclado real assim que a tela
            // carrega — sem isso, o CallbackShortcuts do Escape (acima) fica
            // "surdo" até o usuário apertar alguma seta pela primeira vez: o
            // foco padrão de uma rota recém-aberta é o FocusScope da própria
            // rota, que fica ACIMA do CallbackShortcuts na árvore, e evento
            // de tecla só sobe (nunca desce) a partir do nó focado.
            // `skipTraversal` impede que Tab/D-Pad parem neste nó "invisível"
            // depois que o usuário começa a navegar de verdade.
            focusNode: _rootFocusNode,
            autofocus: true,
            skipTraversal: true,
            child: TabBarView(
              controller: _tabController,
              children: [
                _ContentTabView(
                  type: ContentType.live,
                  searchHintText: 'Buscar canal...',
                  streamsPanelBuilder: (query) => _LiveStreamsPanel(searchQuery: query),
                ),
                _ContentTabView(
                  type: ContentType.vod,
                  searchHintText: 'Buscar filme...',
                  streamsPanelBuilder: (query) => _VodGrid(searchQuery: query),
                ),
                _ContentTabView(
                  type: ContentType.series,
                  searchHintText: 'Buscar série...',
                  streamsPanelBuilder: (query) => _SeriesGrid(searchQuery: query),
                ),
                const _ContinueWatchingTab(),
              ],
            ),
          ),
        ),
      ),
    );
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
  final Widget Function(String searchQuery) streamsPanelBuilder;

  const _ContentTabView({
    required this.type,
    required this.searchHintText,
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

  void _openSearch() {
    setState(() => _searching = true);
    // Só depois do campo existir de verdade na árvore (próximo frame) — pedir
    // foco no mesmo build em que o campo aparece não tem efeito.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFieldFocusNode.requestFocus();
    });
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _query = '';
      _searchController.clear();
    });
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
          onOpenSearch: _openSearch,
          onCloseSearch: _closeSearch,
          onQueryChanged: (value) => setState(() => _query = value),
          narrowCategoriesWidget: _CategoriesChips(type: widget.type),
          wideCategoriesWidget: _CategoriesSidebar(type: widget.type),
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
                    Expanded(child: widget.streamsPanelBuilder(_query)),
                  ],
                )
              : Column(
                  children: [
                    header,
                    const Divider(height: 1),
                    Expanded(child: widget.streamsPanelBuilder(_query)),
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

  const _CategoriesSidebar({required this.type});

  @override
  Widget build(BuildContext context) {
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

            return DpadFocusHighlight(
              key: ValueKey('sidebar_category_${type.name}_${category.id}'),
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
                  onTap: () => context.read<ContentProvider>().selectCategory(
                    type,
                    category.id,
                  ),
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

  const _CategoriesChips({required this.type});

  @override
  Widget build(BuildContext context) {
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

              return DpadFocusHighlight(
                key: ValueKey('chip_category_${type.name}_${category.id}'),
                scaleOnFocus: false,
                borderRadius: BorderRadius.circular(20),
                builder: (context, focusNode, hasFocus) => ChoiceChip(
                  focusNode: focusNode,
                  label: Text(category.name),
                  selected: selected,
                  onSelected: (_) => context
                      .read<ContentProvider>()
                      .selectCategory(type, category.id),
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

  const _LiveStreamsPanel({this.searchQuery = ''});

  @override
  Widget build(BuildContext context) {
    return Consumer<ContentProvider>(
      builder: (context, provider, _) {
        final state = provider.live;

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
        final filtered = query.isEmpty
            ? state.streams
            : state.streams
                .where((channel) => channel.name.toLowerCase().contains(query))
                .toList();

        if (filtered.isEmpty) {
          return _EmptyHint(
            icon: Icons.search_off,
            message: 'Nenhum canal encontrado para "${searchQuery.trim()}".',
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
                          trailing: channel.tvArchive
                              ? const Icon(Icons.replay_circle_filled_outlined, size: 18)
                              : null,
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

  const _VodGrid({this.searchQuery = ''});

  @override
  Widget build(BuildContext context) {
    return Consumer<ContentProvider>(
      builder: (context, provider, _) {
        final state = provider.vod;

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
        final movies = query.isEmpty
            ? state.streams
            : state.streams.where((movie) => movie.name.toLowerCase().contains(query)).toList();

        if (movies.isEmpty) {
          return _EmptyHint(
            icon: Icons.search_off,
            message: 'Nenhum filme encontrado para "${searchQuery.trim()}".',
          );
        }

        return GridView.builder(
          padding: const EdgeInsets.all(AppSpacing.m),
          // VOD/Séries podem ter centenas de itens por categoria — um
          // cacheExtent moderado mantém uma folga de linhas pré-construídas
          // fora da viewport (rolagem mais suave, menos rebuild a cada
          // frame) sem carregar imagens demais de uma vez.
          scrollCacheExtent: const ScrollCacheExtent.pixels(500),
          gridDelegate: AppCardSizes.posterGridDelegate,
          itemCount: movies.length,
          itemBuilder: (context, index) {
            final movie = movies[index];

            return DpadFocusHighlight(
              key: ValueKey('vod_stream_${movie.streamId}'),
              builder: (context, focusNode, hasFocus) => _PosterCard(
                focusNode: focusNode,
                title: movie.name,
                imageUrl: movie.streamIcon,
                fallbackIcon: Icons.movie,
                rating: movie.rating,
                onTap: () => _playMovie(context, movie),
              ),
            );
          },
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

  const _SeriesGrid({this.searchQuery = ''});

  @override
  Widget build(BuildContext context) {
    return Consumer<ContentProvider>(
      builder: (context, provider, _) {
        final state = provider.series;

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
        final shows = query.isEmpty
            ? state.streams
            : state.streams.where((show) => show.name.toLowerCase().contains(query)).toList();

        if (shows.isEmpty) {
          return _EmptyHint(
            icon: Icons.search_off,
            message: 'Nenhuma série encontrada para "${searchQuery.trim()}".',
          );
        }

        return GridView.builder(
          padding: const EdgeInsets.all(AppSpacing.m),
          // VOD/Séries podem ter centenas de itens por categoria — um
          // cacheExtent moderado mantém uma folga de linhas pré-construídas
          // fora da viewport (rolagem mais suave, menos rebuild a cada
          // frame) sem carregar imagens demais de uma vez.
          scrollCacheExtent: const ScrollCacheExtent.pixels(500),
          gridDelegate: AppCardSizes.posterGridDelegate,
          itemCount: shows.length,
          itemBuilder: (context, index) {
            final show = shows[index];

            return DpadFocusHighlight(
              key: ValueKey('series_${show.seriesId}'),
              builder: (context, focusNode, hasFocus) => _PosterCard(
                focusNode: focusNode,
                title: show.name,
                imageUrl: show.cover,
                fallbackIcon: Icons.video_library,
                rating: show.rating,
                onTap: () => _openSeriesDetails(context, show),
              ),
            );
          },
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
    // refletir isso na prateleira, mesmo raciocínio de _playMovie abaixo.
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
  // com o fluxo atual, sem fallbackUrls, ver HomeScreen._playMovie).
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

void _playMovie(BuildContext context, VodStream movie) {
  final apiService = context.read<AuthProvider>().apiService;
  if (apiService == null) return;

  final url = apiService.buildVodStreamUrl(
    movie.streamId.toString(),
    movie.containerExtension,
  );
  final continueWatching = context.read<ContinueWatchingProvider>();

  Navigator.of(context)
      .push(
        fadeSlideRoute(
          (_) => PlayerScreen(
            url: url,
            title: movie.name,
            contentId: movie.streamId.toString(),
            imageUrl: movie.streamIcon,
            progressType: WatchProgressType.vod,
          ),
        ),
      )
      .then((_) {
        // Volta da Player com progresso possivelmente atualizado (ou removido,
        // se o filme foi concluído) — recarrega pra prateleira refletir o
        // estado atual sem precisar reabrir a HomeScreen inteira.
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
