import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/fade_slide_route.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/watch_progress.dart';
import '../../data/models/xtream_models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/content_provider.dart' show LoadStatus;
import '../../providers/continue_watching_provider.dart';
import '../../providers/series_details_provider.dart';
import '../../widgets/dpad_focus_highlight.dart';
import '../../widgets/skeleton_loader.dart';
import '../../widgets/state_placeholders.dart';
import '../player/player_screen.dart';

/// [TESTE] Temporadas + episódios de UMA série -- tela própria, alcançada
/// pelo ícone "Temporadas" em [SeriesDetailsScreen] (antes vivia embutida
/// naquela mesma tela). Reaproveita o [SeriesDetailsProvider] já carregado
/// por ela (mesmo provider, escopo de app inteiro, ver main.dart) -- nunca
/// refaz a chamada de rede.
class SeriesSeasonsScreen extends StatefulWidget {
  final Series series;

  const SeriesSeasonsScreen({super.key, required this.series});

  @override
  State<SeriesSeasonsScreen> createState() => _SeriesSeasonsScreenState();
}

class _SeriesSeasonsScreenState extends State<SeriesSeasonsScreen> {
  String? _selectedSeason;
  final Map<String, FocusNode> _seasonFocusNodes = {};

  String get _seriesId => widget.series.seriesId.toString();

  @override
  void dispose() {
    for (final node in _seasonFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _retry() {
    final apiService = context.read<AuthProvider>().apiService;
    if (apiService == null) return;
    context.read<SeriesDetailsProvider>().retry(apiService, _seriesId);
  }

  FocusNode _seasonFocusNode(String season) {
    return _seasonFocusNodes.putIfAbsent(season, () => FocusNode(debugLabel: 'season_$season'));
  }

  void _playEpisode(Episode episode, {double startAtSeconds = 0}) {
    final apiService = context.read<AuthProvider>().apiService;
    if (apiService == null) return;

    final url = apiService.buildSeriesEpisodeUrl(episode.id, episode.containerExtension);
    final title = '${widget.series.name} - T${episode.season}E${episode.episodeNum} - ${episode.title}';
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
        appBar: AppBar(title: Text('Temporadas -- ${widget.series.name}')),
        body: Consumer<SeriesDetailsProvider>(
          builder: (context, provider, _) {
            final isActive = provider.activeSeriesId == _seriesId;
            final status = isActive ? provider.status : LoadStatus.loading;
            final info = isActive ? provider.info : null;
            final error = isActive ? provider.errorMessage : null;

            if (status == LoadStatus.loading && info == null) {
              return const _SeasonsBodySkeleton();
            }
            if (status == LoadStatus.error && info == null) {
              return ErrorRetry(message: error ?? 'Erro ao carregar a série.', onRetry: _retry);
            }
            if (info == null) return const SizedBox.shrink();

            final seasonKeys = info.seasons.keys.toList()
              ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));

            if (seasonKeys.isEmpty) {
              return const EmptyHint(
                icon: Icons.video_library_outlined,
                message: 'Nenhuma temporada encontrada para esta série.',
              );
            }

            final selectedSeason = _selectedSeason != null && seasonKeys.contains(_selectedSeason)
                ? _selectedSeason!
                : seasonKeys.first;

            final episodes = List<Episode>.from(info.seasons[selectedSeason] ?? const [])
              ..sort((a, b) => a.episodeNum.compareTo(b.episodeNum));

            return LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 700;

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
                      Expanded(
                        child: episodes.isEmpty
                            ? const EmptyHint(
                                icon: Icons.movie_filter_outlined,
                                message: 'Nenhum episódio listado nesta temporada.',
                              )
                            : _EpisodesList(
                                episodes: episodes,
                                isWide: isWide,
                                seasonSelectorFocusNode: _seasonFocusNode(selectedSeason),
                                onEpisodeTap: _playEpisode,
                              ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

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
              autofocus: index == 0,
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

class _EpisodesList extends StatelessWidget {
  final List<Episode> episodes;
  final bool isWide;
  final FocusNode seasonSelectorFocusNode;
  final void Function(Episode episode, {double startAtSeconds}) onEpisodeTap;

  const _EpisodesList({
    required this.episodes,
    required this.isWide,
    required this.seasonSelectorFocusNode,
    required this.onEpisodeTap,
  });

  /// A lista de episódios é uma coluna única (sem grid), então toda seta
  /// esquerda/direita está, por definição, numa "borda". Intercepta antes
  /// da navegação padrão e devolve o foco pro seletor de temporada, mesmo
  /// espírito do `_handleSurfaceKeyEvent` da PlayerScreen.
  KeyEventResult _redirectToSeasonSelector(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.arrowLeft && event.logicalKey != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }

    seasonSelectorFocusNode.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final continueWatching = context.watch<ContinueWatchingProvider>();

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _redirectToSeasonSelector,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s),
        itemCount: episodes.length,
        itemBuilder: (context, index) {
          final episode = episodes[index];
          final matchingProgress = continueWatching.items
              .where((p) => p.type == WatchProgressType.episode && p.contentId == episode.id);
          final progress = matchingProgress.isEmpty ? null : matchingProgress.first;

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
                  : (progress != null
                      ? Text(
                          '${(progress.fraction * 100).round()}% assistido',
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                        )
                      : null),
              trailing: episode.info.durationSecs > 0
                  ? Text(_formatDuration(episode.info.durationSecs), style: const TextStyle(fontSize: 12))
                  : null,
              onTap: () => onEpisodeTap(episode, startAtSeconds: (progress?.positionSeconds ?? 0).toDouble()),
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
