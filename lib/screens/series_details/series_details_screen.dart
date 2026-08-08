import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/fade_slide_route.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/watch_progress.dart';
import '../../data/models/xtream_models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/content_provider.dart' show LoadStatus;
import '../../providers/series_details_provider.dart';
import '../../widgets/dpad_focus_highlight.dart';
import '../../widgets/network_image_with_fallback.dart';
import '../../widgets/skeleton_loader.dart';
import '../../widgets/state_illustration.dart';
import '../player/player_screen.dart';

/// Mesmo breakpoint da HomeScreen ([_sidebarBreakpoint] em `home_screen.dart`):
/// abaixo disso o header empilha verticalmente e os episódios ficam num
/// layout compacto; acima disso o header vira uma linha e os episódios
/// mostram mais detalhes (sinopse, duração).
const double _wideBreakpoint = 700;

/// Tela de detalhes de uma série: metadados + seletor de temporada +
/// episódios. Recebe o [Series] já carregado da HomeScreen (capa/nome/
/// sinopse aparecem imediatamente) e busca temporadas/episódios via
/// [SeriesDetailsProvider] — nenhuma chamada de rede direta aqui.
class SeriesDetailsScreen extends StatefulWidget {
  final Series series;

  const SeriesDetailsScreen({super.key, required this.series});

  @override
  State<SeriesDetailsScreen> createState() => _SeriesDetailsScreenState();
}

class _SeriesDetailsScreenState extends State<SeriesDetailsScreen> {
  String? _selectedSeason;
  final Map<String, FocusNode> _seasonFocusNodes = {};

  // Nó nomeado (não anônimo) de propósito: dá pra um teste de widget pegar
  // este `Focus` especificamente (via `find.byWidgetPredicate` + o próprio
  // `focusNode`) e afirmar `hasFocus == true` sem precisar chamar
  // `requestFocus()` manualmente — é isso que prova que o autofoco desta
  // tela funciona sozinho. Mesmo padrão já usado em `_inputFocusNode` da
  // PlayerScreen.
  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'series-details-screen-root');

  // Controla o "salto" único de foco do wrapper invisível acima pro
  // primeiro item de verdade (seletor de temporada ou botão de retry), ver
  // `_handOffInitialFocusIfReady`. Nunca mais depois da primeira vez.
  bool _didHandOffInitialFocus = false;

  // Guardado à parte (em vez de `context.read<SeriesDetailsProvider>()` de
  // novo em `dispose()`) de propósito: por volta do fim de um teste de
  // widget (ou de qualquer desmonte de árvore inteira), o Element desta
  // tela pode já estar desativado quando `dispose()` roda, e uma nova busca
  // de ancestral nesse momento é insegura ("Looking up a deactivated
  // widget's ancestor is unsafe" — achado rodando o teste). Guardar a
  // referência enquanto o contexto ainda está garantidamente ativo
  // (`initState`) evita essa busca tardia.
  late final SeriesDetailsProvider _seriesDetailsProvider = context.read<SeriesDetailsProvider>();

  String get _seriesId => widget.series.seriesId.toString();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadInfo());
    // `get_series_info` chega de forma assíncrona (rede) — escuta o
    // SeriesDetailsProvider pra saltar o foco assim que houver algo real
    // pra focar (ver `_handOffInitialFocusIfReady`).
    _seriesDetailsProvider.addListener(_handOffInitialFocusIfReady);
  }

  @override
  void dispose() {
    for (final node in _seasonFocusNodes.values) {
      node.dispose();
    }
    _seriesDetailsProvider.removeListener(_handOffInitialFocusIfReady);
    _rootFocusNode.dispose();
    super.dispose();
  }

  /// Salta o foco, uma única vez, do wrapper invisível (`_rootFocusNode`,
  /// ver `build` abaixo) pro seletor de temporada (ou botão de retry, em
  /// caso de erro) assim que a tela sair do estado de carregamento — sem
  /// isso, a primeira seta do D-Pad não move o foco pra lugar nenhum: esse
  /// wrapper fica FORA do `FocusTraversalGroup`/conteúdo de baixo, e busca
  /// DIRECIONAL (seta) não "entra" nele sozinha — só travessia por ORDEM
  /// (`nextFocus`, equivalente ao Tab) consegue atravessar essa fronteira
  /// (achado empírico rodando o teste que cobre esse cenário: ver "seta
  /// move o foco pro seletor de temporada, mesmo sem nenhum foco manual
  /// antes").
  void _handOffInitialFocusIfReady() {
    if (_didHandOffInitialFocus) return;
    if (_seriesDetailsProvider.activeSeriesId != _seriesId) return;
    if (_seriesDetailsProvider.status == LoadStatus.loading ||
        _seriesDetailsProvider.status == LoadStatus.idle) {
      return;
    }

    _didHandOffInitialFocus = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _rootFocusNode.nextFocus();
    });
  }

  void _loadInfo() {
    final apiService = context.read<AuthProvider>().apiService;
    if (apiService == null) return;
    context.read<SeriesDetailsProvider>().loadSeriesInfo(apiService, _seriesId);
  }

  void _retry() {
    final apiService = context.read<AuthProvider>().apiService;
    if (apiService == null) return;
    context.read<SeriesDetailsProvider>().retry(apiService, _seriesId);
  }

  FocusNode _seasonFocusNode(String season) {
    return _seasonFocusNodes.putIfAbsent(season, () => FocusNode(debugLabel: 'season_$season'));
  }

  void _playEpisode(Episode episode) {
    final apiService = context.read<AuthProvider>().apiService;
    if (apiService == null) return;

    final url = apiService.buildSeriesEpisodeUrl(episode.id, episode.containerExtension);
    final title = '${widget.series.name} - T${episode.season}E${episode.episodeNum} - ${episode.title}';
    // Episódios raramente têm capa própria (get_series_info costuma trazer
    // `info.movie_image` vazio) — cai pra capa da série, mesma imagem já
    // usada no header desta tela.
    final imageUrl = episode.info.movieImage.isNotEmpty ? episode.info.movieImage : widget.series.cover;

    Navigator.of(context).push(
      fadeSlideRoute((_) => PlayerScreen(
            url: url,
            title: title,
            contentId: episode.id,
            imageUrl: imageUrl,
            progressType: WatchProgressType.episode,
          )),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.series.name)),
        body: Focus(
          // Mesmo raciocínio do Focus autofocus/skipTraversal da HomeScreen:
          // garante foco de teclado real assim que a tela monta, para o
          // Escape acima já funcionar sem precisar de uma seta antes.
          focusNode: _rootFocusNode,
          autofocus: true,
          skipTraversal: true,
          child: Consumer<SeriesDetailsProvider>(
            builder: (context, provider, _) {
              final isActive = provider.activeSeriesId == _seriesId;
              final status = isActive ? provider.status : LoadStatus.loading;
              final info = isActive ? provider.info : null;
              final error = isActive ? provider.errorMessage : null;

              return LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= _wideBreakpoint;

                  return CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: _SeriesHeader(series: widget.series, details: info?.info, isWide: isWide),
                      ),
                      SliverToBoxAdapter(
                        child: _buildSeasonsBody(status: status, info: info, error: error, isWide: isWide),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSeasonsBody({
    required LoadStatus status,
    required SeriesInfo? info,
    required String? error,
    required bool isWide,
  }) {
    if (status == LoadStatus.loading && info == null) {
      return const _SeasonsBodySkeleton();
    }

    if (status == LoadStatus.error && info == null) {
      return _ErrorRetry(
        message: error ?? 'Erro ao carregar a série.',
        onRetry: _retry,
      );
    }

    if (info == null) return const SizedBox.shrink();

    final seasonKeys = info.seasons.keys.toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));

    if (seasonKeys.isEmpty) {
      return const _EmptyHint(
        icon: Icons.video_library_outlined,
        message: 'Nenhuma temporada encontrada para esta série.',
      );
    }

    final selectedSeason = _selectedSeason != null && seasonKeys.contains(_selectedSeason)
        ? _selectedSeason!
        : seasonKeys.first;

    final episodes = List<Episode>.from(info.seasons[selectedSeason] ?? const [])
      ..sort((a, b) => a.episodeNum.compareTo(b.episodeNum));

    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SeasonSelector(
            seasons: seasonKeys,
            selectedSeason: selectedSeason,
            focusNodeFor: _seasonFocusNode,
            onSelected: (season) => setState(() => _selectedSeason = season),
          ),
          const Divider(height: 1),
          episodes.isEmpty
              ? const _EmptyHint(
                  icon: Icons.movie_filter_outlined,
                  message: 'Nenhum episódio listado nesta temporada.',
                )
              : _EpisodesList(
                  episodes: episodes,
                  isWide: isWide,
                  seasonSelectorFocusNode: _seasonFocusNode(selectedSeason),
                  onEpisodeTap: _playEpisode,
                ),
        ],
      ),
    );
  }
}

/// Placeholder de carregamento do corpo de temporadas/episódios — mesma
/// silhueta geral do [_SeasonSelector] + [_EpisodesList] reais (chips
/// horizontais + linhas com círculo/barra), mostrada enquanto
/// `get_series_info` ainda não respondeu (o header acima já aparece
/// imediatamente com os dados do [Series] recebido da HomeScreen).
class _SeasonsBodySkeleton extends StatelessWidget {
  const _SeasonsBodySkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 56,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m, vertical: AppSpacing.s),
            itemCount: 4,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.s),
            itemBuilder: (context, index) => const SkeletonChip(width: 110),
          ),
        ),
        const Divider(height: 1),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s),
          itemCount: 6,
          itemBuilder: (context, index) => const SkeletonListRow(withSubtitle: true),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------

class _SeriesHeader extends StatelessWidget {
  final Series series;
  final SeriesDetails? details;
  final bool isWide;

  const _SeriesHeader({required this.series, required this.details, required this.isWide});

  /// `get_series` (listagem) às vezes traz `plot`/`cast`/`director` vazios,
  /// populados só em `get_series_info` — prefere o valor mais completo
  /// disponível no momento, sem esperar a rede para os campos que a
  /// HomeScreen já tinha.
  String _pick(String? primary, String fallback) {
    return (primary != null && primary.isNotEmpty) ? primary : fallback;
  }

  @override
  Widget build(BuildContext context) {
    final plot = _pick(details?.plot, series.plot);
    final genre = _pick(details?.genre, series.genre);
    final cast = _pick(details?.cast, series.cast);
    final director = _pick(details?.director, series.director);
    final rating = (details != null && details!.rating > 0) ? details!.rating : series.rating;

    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: _CoverImage(url: series.cover),
      ),
    );

    final texts = _SeriesHeaderTexts(
      name: series.name,
      genre: genre,
      cast: cast,
      director: director,
      plot: plot,
      rating: rating,
    );

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.l),
      child: isWide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 180, child: cover),
                const SizedBox(width: 20),
                Expanded(child: texts),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: SizedBox(width: 160, child: cover)),
                const SizedBox(height: AppSpacing.l),
                texts,
              ],
            ),
    );
  }
}

class _SeriesHeaderTexts extends StatelessWidget {
  final String name;
  final String genre;
  final String cast;
  final String director;
  final String plot;
  final double rating;

  const _SeriesHeaderTexts({
    required this.name,
    required this.genre,
    required this.cast,
    required this.director,
    required this.plot,
    required this.rating,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: AppSpacing.s),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            if (rating > 0) _MetaChip(icon: Icons.star, text: rating.toStringAsFixed(1)),
            if (genre.isNotEmpty) _MetaChip(icon: Icons.category_outlined, text: genre),
          ],
        ),
        if (plot.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.m),
          Text(plot, style: TextStyle(color: Colors.grey.shade300, height: 1.4)),
        ],
        if (cast.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s),
          Text('Elenco: $cast', style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
        ],
        if (director.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text('Direção: $director', style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
        ],
      ],
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MetaChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: AppTheme.primaryColor),
        const SizedBox(width: AppSpacing.xs),
        Text(text, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}

class _CoverImage extends StatelessWidget {
  final String url;

  const _CoverImage({required this.url});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: AppTheme.surfaceColor,
      alignment: Alignment.center,
      child: Icon(Icons.video_library, size: 40, color: Colors.grey.shade500),
    );

    return NetworkImageWithFallback(
      url: url,
      fallback: fallback,
      cacheWidth: 480,
    );
  }
}

// ---------------------------------------------------------------------
// Seletor de temporada
// ---------------------------------------------------------------------

class _SeasonSelector extends StatelessWidget {
  final List<String> seasons;
  final String selectedSeason;
  final FocusNode Function(String season) focusNodeFor;
  final ValueChanged<String> onSelected;

  const _SeasonSelector({
    required this.seasons,
    required this.selectedSeason,
    required this.focusNodeFor,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m, vertical: AppSpacing.s),
        itemCount: seasons.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.s),
        itemBuilder: (context, index) {
          final season = seasons[index];
          final selected = season == selectedSeason;

          return DpadFocusHighlight(
            key: ValueKey('season_chip_$season'),
            focusNode: focusNodeFor(season),
            scaleOnFocus: false,
            borderRadius: BorderRadius.circular(20),
            builder: (context, focusNode, hasFocus) => ChoiceChip(
              focusNode: focusNode,
              label: Text('Temporada $season'),
              selected: selected,
              onSelected: (_) => onSelected(season),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Lista de episódios
// ---------------------------------------------------------------------

class _EpisodesList extends StatelessWidget {
  final List<Episode> episodes;
  final bool isWide;
  final FocusNode seasonSelectorFocusNode;
  final ValueChanged<Episode> onEpisodeTap;

  const _EpisodesList({
    required this.episodes,
    required this.isWide,
    required this.seasonSelectorFocusNode,
    required this.onEpisodeTap,
  });

  /// A lista de episódios é uma coluna única (sem grid), então toda seta
  /// esquerda/direita está, por definição, numa "borda" — não há navegação
  /// direcional nativa para redirecionar (o seletor de temporada fica acima,
  /// não ao lado, então o algoritmo padrão de foco direcional do Flutter não
  /// o alcançaria como faz a sidebar<->grid da HomeScreen, que é lateral).
  /// Por isso a interceptação é explícita aqui, no mesmo espírito do
  /// `_handleSurfaceKeyEvent` da PlayerScreen: intercepta antes da
  /// navegação padrão (`Focus.onKeyEvent` é checado bubbling-up a partir do
  /// item focado, antes do `Shortcuts` de nível raiz) e devolve o foco para
  /// a temporada selecionada.
  KeyEventResult _redirectToSeasonSelector(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.arrowLeft &&
        event.logicalKey != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }

    seasonSelectorFocusNode.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _redirectToSeasonSelector,
      child: ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s),
        itemCount: episodes.length,
        itemBuilder: (context, index) {
          final episode = episodes[index];

          return DpadFocusHighlight(
            key: ValueKey('episode_${episode.id}'),
            scaleOnFocus: false,
            borderRadius: BorderRadius.circular(4),
            builder: (context, focusNode, hasFocus) => ListTile(
              focusNode: focusNode,
              leading: CircleAvatar(
                backgroundColor: AppTheme.surfaceColor,
                child: Text('${episode.episodeNum}'),
              ),
              title: Text(episode.title.isNotEmpty ? episode.title : 'Episódio ${episode.episodeNum}'),
              subtitle: isWide && episode.info.plot.isNotEmpty
                  ? Text(episode.info.plot, maxLines: 2, overflow: TextOverflow.ellipsis)
                  : null,
              trailing: episode.info.durationSecs > 0
                  ? Text(_formatDuration(episode.info.durationSecs), style: const TextStyle(fontSize: 12))
                  : null,
              onTap: () => onEpisodeTap(episode),
            ),
          );
        },
      ),
    );
  }

  String _formatDuration(double seconds) {
    final duration = Duration(seconds: seconds.round());
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final secs = twoDigits(duration.inSeconds.remainder(60));
    return hours > 0 ? '$hours:$minutes:$secs' : '$minutes:$secs';
  }
}

// ---------------------------------------------------------------------
// Estados compartilhados (mesmo padrão visual de _EmptyHint/_ErrorRetry da
// HomeScreen — não reaproveitados diretamente pois são classes privadas do
// arquivo `home_screen.dart`, inacessíveis daqui).
// ---------------------------------------------------------------------

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

  const _ErrorRetry({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
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
