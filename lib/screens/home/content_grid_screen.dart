import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/fade_slide_route.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/xtream_models.dart';
import '../../providers/content_provider.dart';
import '../../providers/continue_watching_provider.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/dpad_focus_highlight.dart';
import '../../widgets/new_badge.dart';
import '../../widgets/poster_card.dart';
import '../../widgets/state_placeholders.dart';
import '../series_details/series_details_screen.dart';
import '../vod_details/vod_details_screen.dart';

/// Janela pra um filme ainda ganhar o selo [NewBadge], contada a partir de
/// `VodStream.added` (data que o painel Xtream reporta como "adicionado ao
/// catálogo" -- não é a data de lançamento do filme).
const Duration _newBadgeWindow = Duration(days: 7);

bool _isRecentlyAdded(DateTime? added) => added != null && DateTime.now().difference(added) <= _newBadgeWindow;

/// [TESTE] Grid de pôsteres de UMA categoria de Filmes/Séries já
/// selecionada (ver CategoryListScreen) -- mesmo padrão visual de sempre
/// ([PosterCard] + [AppCardSizes.posterGridDelegate]), agora como tela
/// própria em vez de embutido no layout com menu lateral.
class ContentGridScreen extends StatefulWidget {
  final ContentType type;
  final String categoryId;
  final String categoryName;

  const ContentGridScreen({
    super.key,
    required this.type,
    required this.categoryId,
    required this.categoryName,
  });

  @override
  State<ContentGridScreen> createState() => _ContentGridScreenState();
}

class _ContentGridScreenState extends State<ContentGridScreen> {
  final TextEditingController _searchController = TextEditingController();
  late final FocusNode _searchFieldFocusNode = FocusNode(debugLabel: 'content_grid_search');
  bool _searching = false;
  String _query = '';
  bool _favoritesOnly = false;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFieldFocusNode.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFieldFocusNode.requestFocus();
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

  void _openVodDetails(BuildContext context, VodStream movie) {
    final continueWatching = context.read<ContinueWatchingProvider>();
    Navigator.of(context).push(fadeSlideRoute((_) => VodDetailsScreen(movie: movie))).then((_) {
      continueWatching.load();
    });
  }

  void _openSeriesDetails(BuildContext context, Series series) {
    final continueWatching = context.read<ContinueWatchingProvider>();
    Navigator.of(context).push(fadeSlideRoute((_) => SeriesDetailsScreen(series: series))).then((_) {
      continueWatching.load();
    });
  }

  String get _noItemsLabel => widget.type == ContentType.vod ? 'filme' : 'série';

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Scaffold(
        appBar: AppBar(
          title: _searching
              ? TextField(
                  controller: _searchController,
                  focusNode: _searchFieldFocusNode,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Buscar $_noItemsLabel...',
                    border: InputBorder.none,
                  ),
                  onChanged: (value) => setState(() => _query = value),
                )
              : Text(widget.categoryName),
          actions: [
            IconButton(
              icon: Icon(_searching ? Icons.close : Icons.search),
              tooltip: _searching ? 'Fechar busca' : 'Buscar',
              onPressed: () => _searching ? _closeSearch() : _openSearch(),
            ),
            IconButton(
              icon: Icon(_favoritesOnly ? Icons.favorite : Icons.favorite_border),
              tooltip: _favoritesOnly ? 'Mostrar tudo' : 'Só favoritos',
              onPressed: () => setState(() => _favoritesOnly = !_favoritesOnly),
            ),
          ],
        ),
        body: widget.type == ContentType.vod ? _buildVodGrid(context) : _buildSeriesGrid(context),
      ),
    );
  }

  Widget _buildVodGrid(BuildContext context) {
    return Consumer2<ContentProvider, FavoritesProvider>(
      builder: (context, provider, favorites, _) {
        final state = provider.vod;
        final settings = context.watch<SettingsProvider>();

        if (state.streamsStatus == LoadStatus.loading && state.streams.isEmpty) {
          return const PosterGridSkeleton();
        }
        if (state.streamsStatus == LoadStatus.error && state.streams.isEmpty) {
          return ErrorRetry(
            message: state.streamsError ?? 'Erro ao carregar os filmes.',
            onRetry: () => context.read<ContentProvider>().refresh(ContentType.vod),
          );
        }
        if (state.streams.isEmpty) {
          return const EmptyHint(icon: Icons.movie_outlined, message: 'Nenhum filme nesta categoria.');
        }

        final query = _query.trim().toLowerCase();
        var movies =
            query.isEmpty ? state.streams : state.streams.where((m) => m.name.toLowerCase().contains(query)).toList();
        if (_favoritesOnly) {
          movies = movies.where((m) => favorites.isFavorite(ContentType.vod, m.streamId.toString())).toList();
        }
        movies = movies.where((m) => !settings.isLocked(ContentType.vod, m.categoryId)).toList();

        if (movies.isEmpty) {
          return EmptyHint(
            icon: _favoritesOnly ? Icons.favorite_border : Icons.search_off,
            message: switch ((_favoritesOnly, query.isEmpty)) {
              (true, true) => 'Nenhum filme favoritado ainda.',
              (true, false) => 'Nenhum filme favoritado encontrado para "${_query.trim()}".',
              (false, _) => 'Nenhum filme encontrado para "${_query.trim()}".',
            },
          );
        }

        final featured = (!_favoritesOnly && query.isEmpty) ? movies.reduce((a, b) => b.rating > a.rating ? b : a) : null;

        return CustomScrollView(
          scrollCacheExtent: const ScrollCacheExtent.pixels(500),
          slivers: [
            if (featured != null)
              SliverToBoxAdapter(
                child: FeaturedBanner(
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
                      builder: (context, focusNode, hasFocus) => PosterCard(
                        focusNode: focusNode,
                        autofocus: index == 0,
                        title: movie.name,
                        imageUrl: movie.streamIcon,
                        fallbackIcon: Icons.movie,
                        rating: movie.rating,
                        topLeftBadge: _isRecentlyAdded(movie.added) ? const NewBadge() : null,
                        isFavorite: favorites.isFavorite(ContentType.vod, movieId),
                        onToggleFavorite: () => context.read<FavoritesProvider>().toggleFavorite(ContentType.vod, movieId),
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

  Widget _buildSeriesGrid(BuildContext context) {
    return Consumer2<ContentProvider, FavoritesProvider>(
      builder: (context, provider, favorites, _) {
        final state = provider.series;
        final settings = context.watch<SettingsProvider>();

        if (state.streamsStatus == LoadStatus.loading && state.streams.isEmpty) {
          return const PosterGridSkeleton();
        }
        if (state.streamsStatus == LoadStatus.error && state.streams.isEmpty) {
          return ErrorRetry(
            message: state.streamsError ?? 'Erro ao carregar as séries.',
            onRetry: () => context.read<ContentProvider>().refresh(ContentType.series),
          );
        }
        if (state.streams.isEmpty) {
          return const EmptyHint(icon: Icons.video_library_outlined, message: 'Nenhuma série nesta categoria.');
        }

        final query = _query.trim().toLowerCase();
        var shows =
            query.isEmpty ? state.streams : state.streams.where((s) => s.name.toLowerCase().contains(query)).toList();
        if (_favoritesOnly) {
          shows = shows.where((s) => favorites.isFavorite(ContentType.series, s.seriesId.toString())).toList();
        }
        shows = shows.where((s) => !settings.isLocked(ContentType.series, s.categoryId)).toList();

        if (shows.isEmpty) {
          return EmptyHint(
            icon: _favoritesOnly ? Icons.favorite_border : Icons.search_off,
            message: switch ((_favoritesOnly, query.isEmpty)) {
              (true, true) => 'Nenhuma série favoritada ainda.',
              (true, false) => 'Nenhuma série favoritada encontrada para "${_query.trim()}".',
              (false, _) => 'Nenhuma série encontrada para "${_query.trim()}".',
            },
          );
        }

        final featured = (!_favoritesOnly && query.isEmpty) ? shows.reduce((a, b) => b.rating > a.rating ? b : a) : null;

        return CustomScrollView(
          scrollCacheExtent: const ScrollCacheExtent.pixels(500),
          slivers: [
            if (featured != null)
              SliverToBoxAdapter(
                child: FeaturedBanner(
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
                      builder: (context, focusNode, hasFocus) => PosterCard(
                        focusNode: focusNode,
                        autofocus: index == 0,
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
