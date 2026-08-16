import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/fade_slide_route.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/watch_progress.dart';
import '../../data/models/xtream_models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/content_provider.dart' show ContentType, LoadStatus;
import '../../providers/continue_watching_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/series_details_provider.dart';
import '../../widgets/network_image_with_fallback.dart';
import '../../widgets/state_placeholders.dart';
import '../player/player_screen.dart';
import 'series_seasons_screen.dart';

/// Mesmo breakpoint de sempre: abaixo disso o header empilha verticalmente.
const double _wideBreakpoint = 700;

/// [TESTE] Tela de SINOPSE de uma série -- metadados + botões de ação
/// (Assistir/Continuar, Temporadas, Favoritar), estilo Duplecast: sinopse
/// primeiro, temporadas/episódios só depois de tocar no ícone dedicado
/// (ver [SeriesSeasonsScreen]). Antes esta mesma tela já mostrava a lista de
/// temporadas/episódios embutida -- agora é sempre um passo a mais,
/// intencional (mesmo padrão da referência visual).
class SeriesDetailsScreen extends StatefulWidget {
  final Series series;

  const SeriesDetailsScreen({super.key, required this.series});

  @override
  State<SeriesDetailsScreen> createState() => _SeriesDetailsScreenState();
}

class _SeriesDetailsScreenState extends State<SeriesDetailsScreen> {
  // Nó nomeado (não anônimo) de propósito: dá pra um teste de widget pegar
  // este `Focus` especificamente e afirmar `hasFocus == true` sem precisar
  // chamar `requestFocus()` manualmente -- prova que o autofoco desta tela
  // funciona sozinho. Mesmo padrão já usado em `_inputFocusNode` da
  // PlayerScreen.
  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'series-details-screen-root');
  final FocusNode _watchButtonFocusNode = FocusNode(debugLabel: 'series-details-watch');

  bool _didHandOffInitialFocus = false;

  late final SeriesDetailsProvider _seriesDetailsProvider = context.read<SeriesDetailsProvider>();

  String get _seriesId => widget.series.seriesId.toString();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadInfo());
    _seriesDetailsProvider.addListener(_handOffInitialFocusIfReady);
  }

  @override
  void dispose() {
    _seriesDetailsProvider.removeListener(_handOffInitialFocusIfReady);
    _rootFocusNode.dispose();
    _watchButtonFocusNode.dispose();
    super.dispose();
  }

  /// Salta o foco, uma única vez, do wrapper invisível (`_rootFocusNode`)
  /// pro botão "Assistir"/"Tentar novamente" assim que a tela sair do
  /// carregamento -- mesmo raciocínio já documentado em
  /// player_screen.dart/settings_screen.dart: sem isso, a primeira seta do
  /// D-Pad não move o foco pra lugar nenhum.
  void _handOffInitialFocusIfReady() {
    if (_didHandOffInitialFocus) return;
    if (_seriesDetailsProvider.activeSeriesId != _seriesId) return;
    if (_seriesDetailsProvider.status == LoadStatus.loading || _seriesDetailsProvider.status == LoadStatus.idle) {
      return;
    }

    _didHandOffInitialFocus = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _watchButtonFocusNode.requestFocus();
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

  void _openSeasons() {
    Navigator.of(context).push(fadeSlideRoute((_) => SeriesSeasonsScreen(series: widget.series)));
  }

  /// Episódio "alvo" do botão principal: o episódio com progresso salvo mais
  /// recente desta série (ainda não concluído, ver [WatchProgress.fraction])
  /// se existir algum -- senão, o primeiro episódio (menor temporada, menor
  /// número) da série inteira. `null` só quando a série não tem episódio
  /// nenhum listado.
  ({Episode episode, WatchProgress? progress})? _resolveTarget(
    SeriesInfo info,
    ContinueWatchingProvider continueWatching,
  ) {
    final allEpisodes = <Episode>[for (final list in info.seasons.values) ...list];
    if (allEpisodes.isEmpty) return null;

    WatchProgress? bestProgress;
    Episode? bestEpisode;
    for (final episode in allEpisodes) {
      for (final progress in continueWatching.items) {
        if (progress.type != WatchProgressType.episode) continue;
        if (progress.contentId != episode.id) continue;
        if (progress.fraction >= 0.95) continue; // já concluído -- não é "continuar"
        if (bestProgress == null || progress.lastWatchedAt.isAfter(bestProgress.lastWatchedAt)) {
          bestProgress = progress;
          bestEpisode = episode;
        }
      }
    }

    if (bestEpisode != null) return (episode: bestEpisode, progress: bestProgress);

    final sorted = List<Episode>.from(allEpisodes)
      ..sort((a, b) {
        final bySeason = a.season.compareTo(b.season);
        return bySeason != 0 ? bySeason : a.episodeNum.compareTo(b.episodeNum);
      });
    return (episode: sorted.first, progress: null);
  }

  void _playEpisode(Episode episode, {double startAtSeconds = 0}) {
    final apiService = context.read<AuthProvider>().apiService;
    if (apiService == null) return;

    final url = apiService.buildSeriesEpisodeUrl(episode.id, episode.containerExtension);
    final title = '${widget.series.name} - T${episode.season}E${episode.episodeNum} - ${episode.title}';
    // Episódios raramente têm capa própria (get_series_info costuma trazer
    // `info.movie_image` vazio) -- cai pra capa da série.
    final imageUrl = episode.info.movieImage.isNotEmpty ? episode.info.movieImage : widget.series.cover;
    final continueWatching = context.read<ContinueWatchingProvider>();

    Navigator.of(context)
        .push(
          fadeSlideRoute((_) => PlayerScreen(
                url: url,
                title: title,
                contentId: episode.id,
                imageUrl: imageUrl,
                progressType: WatchProgressType.episode,
                startAtSeconds: startAtSeconds,
              )),
        )
        .then((_) => continueWatching.load());
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
          focusNode: _rootFocusNode,
          autofocus: true,
          skipTraversal: true,
          child: Consumer2<SeriesDetailsProvider, ContinueWatchingProvider>(
            builder: (context, provider, continueWatching, _) {
              final isActive = provider.activeSeriesId == _seriesId;
              final status = isActive ? provider.status : LoadStatus.loading;
              final info = isActive ? provider.info : null;
              final error = isActive ? provider.errorMessage : null;

              final target = info != null ? _resolveTarget(info, continueWatching) : null;

              return LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= _wideBreakpoint;

                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SeriesHeader(series: widget.series, details: info?.info, isWide: isWide),
                        if (status == LoadStatus.error && info == null)
                          ErrorRetry(message: error ?? 'Erro ao carregar a série.', onRetry: _retry)
                        else
                          _SeriesActionRow(
                            watchButtonFocusNode: _watchButtonFocusNode,
                            loading: status == LoadStatus.loading && info == null,
                            target: target,
                            onWatch: target == null
                                ? null
                                : () => _playEpisode(
                                      target.episode,
                                      startAtSeconds: (target.progress?.positionSeconds ?? 0).toDouble(),
                                    ),
                            onOpenSeasons: (status == LoadStatus.loading && info == null) ? null : _openSeasons,
                            seriesId: _seriesId,
                          ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Fileira de ações abaixo do header, estilo Duplecast: botão principal
/// (Assistir/Continuar), depois 3 ícones -- Temporadas (abre
/// [SeriesSeasonsScreen]), Favoritar, e "Assistir do início" (só quando já
/// existe progresso salvo, reseta pro início do episódio-alvo em vez de
/// continuar de onde parou).
class _SeriesActionRow extends StatelessWidget {
  final FocusNode watchButtonFocusNode;
  final bool loading;
  final ({Episode episode, WatchProgress? progress})? target;
  final VoidCallback? onWatch;
  final VoidCallback? onOpenSeasons;
  final String seriesId;

  const _SeriesActionRow({
    required this.watchButtonFocusNode,
    required this.loading,
    required this.target,
    required this.onWatch,
    required this.onOpenSeasons,
    required this.seriesId,
  });

  @override
  Widget build(BuildContext context) {
    final favorites = context.watch<FavoritesProvider>();
    final isFavorite = favorites.isFavorite(ContentType.series, seriesId);
    final resuming = target?.progress != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.l),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              focusNode: watchButtonFocusNode,
              autofocus: true,
              onPressed: onWatch,
              icon: loading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4))
                  : const Icon(Icons.play_arrow),
              label: Text(
                resuming
                    ? 'Continuar T${target!.episode.season}E${target!.episode.episodeNum}'
                    : (target != null ? 'Assistir T${target!.episode.season}E${target!.episode.episodeNum}' : 'Assistir'),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.s),
          _ActionIconButton(
            icon: Icons.video_library_outlined,
            tooltip: 'Temporadas',
            onPressed: onOpenSeasons,
          ),
          const SizedBox(width: AppSpacing.s),
          _ActionIconButton(
            icon: isFavorite ? Icons.favorite : Icons.favorite_border,
            tooltip: isFavorite ? 'Remover dos favoritos' : 'Favoritar',
            iconColor: isFavorite ? AppTheme.primaryColor : null,
            onPressed: () => context.read<FavoritesProvider>().toggleFavorite(ContentType.series, seriesId),
          ),
        ],
      ),
    );
  }
}

class _ActionIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? iconColor;

  const _ActionIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.primaryColor.withAlpha(60)),
      ),
      child: IconButton(
        icon: Icon(icon, color: iconColor),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
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
    final releaseDate = details?.releaseDate ?? '';
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
      releaseDate: releaseDate,
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
  final String releaseDate;

  const _SeriesHeaderTexts({
    required this.name,
    required this.genre,
    required this.cast,
    required this.director,
    required this.plot,
    required this.rating,
    required this.releaseDate,
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
            const _SeriesBadge(),
            if (releaseDate.isNotEmpty) _MetaChip(icon: Icons.calendar_today_outlined, text: releaseDate),
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
        const SizedBox(height: AppSpacing.l),
      ],
    );
  }
}

class _SeriesBadge extends StatelessWidget {
  const _SeriesBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: AppTheme.primaryColor, borderRadius: BorderRadius.circular(4)),
      child: const Text('SÉRIES', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
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
