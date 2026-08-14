import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/fade_slide_route.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/watch_progress.dart';
import '../../data/models/xtream_models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/content_provider.dart' show LoadStatus;
import '../../providers/vod_details_provider.dart';
import '../../widgets/network_image_with_fallback.dart';
import '../../widgets/skeleton_loader.dart';
import '../player/player_screen.dart';

/// Mesmo breakpoint da HomeScreen/SeriesDetailsScreen ([_sidebarBreakpoint]/
/// [_wideBreakpoint] naqueles arquivos): abaixo disso o header empilha
/// verticalmente. Redeclarado aqui (não importado) porque é uma constante
/// privada de cada arquivo -- mesmo valor, arquivos diferentes.
const double _wideBreakpoint = 700;

/// Ficha de um filme (sinopse/elenco/gênero/duração) ANTES de tocar --
/// clicar num pôster de VOD chega aqui, não mais direto no Player (ver
/// HomeScreen._playMovie, removido em favor desta tela). Metadados extras
/// vêm de `get_vod_info` (ver [VodDetailsProvider]), ausentes da listagem
/// (`get_vod_streams`) que a HomeScreen já tinha -- mas o botão "Assistir"
/// NÃO depende dessa chamada: [VodStream] (recebido já carregado da
/// HomeScreen) já tem tudo que a URL de reprodução precisa
/// (streamId/containerExtension), então funciona mesmo se `get_vod_info`
/// ainda estiver carregando ou falhar.
class VodDetailsScreen extends StatefulWidget {
  final VodStream movie;

  const VodDetailsScreen({super.key, required this.movie});

  @override
  State<VodDetailsScreen> createState() => _VodDetailsScreenState();
}

class _VodDetailsScreenState extends State<VodDetailsScreen> {
  // Mesmo raciocínio do _rootFocusNode em HomeScreen/SeriesDetailsScreen:
  // garante foco de teclado real assim que a tela monta, pro Escape
  // funcionar sem precisar de uma seta antes.
  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'vod-details-screen-root');

  // Ao contrário da SeriesDetailsScreen (que só tem algo focável depois dos
  // episódios chegarem), o botão "Assistir" já existe no primeiro frame --
  // não precisa esperar `get_vod_info`/nenhum listener, só um salto único
  // de foco assim que a árvore existir de verdade.
  final FocusNode _playButtonFocusNode = FocusNode(debugLabel: 'vod_details_play_button');

  String get _vodId => widget.movie.streamId.toString();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadInfo();
      if (mounted) _rootFocusNode.nextFocus();
    });
  }

  @override
  void dispose() {
    _rootFocusNode.dispose();
    _playButtonFocusNode.dispose();
    super.dispose();
  }

  void _loadInfo() {
    final apiService = context.read<AuthProvider>().apiService;
    if (apiService == null) return;
    context.read<VodDetailsProvider>().loadVodInfo(apiService, _vodId);
  }

  void _retry() {
    final apiService = context.read<AuthProvider>().apiService;
    if (apiService == null) return;
    context.read<VodDetailsProvider>().retry(apiService, _vodId);
  }

  /// NÃO lê/recarrega [ContinueWatchingProvider] aqui de propósito -- ele só
  /// existe dentro da árvore local da HomeScreen (ver
  /// `MultiProvider` em HomeScreen.build), inacessível a partir desta tela
  /// (empurrada por cima via Navigator.push, numa rota IRMÃ da HomeScreen,
  /// não descendente dela -- tentar `context.read` aqui lança
  /// ProviderNotFoundException antes mesmo de navegar pro Player). O
  /// refresh da prateleira "Continuar Assistindo" já acontece quando esta
  /// tela inteira fecha e volta pra Home, ver `_openVodDetails` em
  /// home_screen.dart -- mesmo padrão já usado por
  /// SeriesDetailsScreen._playEpisode, que também não tenta isso aqui.
  void _play(BuildContext context) {
    final apiService = context.read<AuthProvider>().apiService;
    if (apiService == null) return;

    final url = apiService.buildVodStreamUrl(widget.movie.streamId.toString(), widget.movie.containerExtension);

    Navigator.of(context).push(
      fadeSlideRoute(
        (_) => PlayerScreen(
          url: url,
          title: widget.movie.name,
          contentId: widget.movie.streamId.toString(),
          imageUrl: widget.movie.streamIcon,
          progressType: WatchProgressType.vod,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.movie.name)),
        body: Focus(
          focusNode: _rootFocusNode,
          autofocus: true,
          skipTraversal: true,
          child: Consumer<VodDetailsProvider>(
            builder: (context, provider, _) {
              final isActive = provider.activeVodId == _vodId;
              final status = isActive ? provider.status : LoadStatus.loading;
              final info = isActive ? provider.info?.info : null;
              final error = isActive ? provider.errorMessage : null;

              return LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= _wideBreakpoint;

                  return SingleChildScrollView(
                    child: _MovieHeader(
                      movie: widget.movie,
                      details: info,
                      metadataStatus: status,
                      metadataError: error,
                      isWide: isWide,
                      playButtonFocusNode: _playButtonFocusNode,
                      onPlay: () => _play(context),
                      onRetryMetadata: _retry,
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

class _MovieHeader extends StatelessWidget {
  final VodStream movie;
  final VodDetails? details;
  final LoadStatus metadataStatus;
  final String? metadataError;
  final bool isWide;
  final FocusNode playButtonFocusNode;
  final VoidCallback onPlay;
  final VoidCallback onRetryMetadata;

  const _MovieHeader({
    required this.movie,
    required this.details,
    required this.metadataStatus,
    required this.metadataError,
    required this.isWide,
    required this.playButtonFocusNode,
    required this.onPlay,
    required this.onRetryMetadata,
  });

  @override
  Widget build(BuildContext context) {
    final rating = (details != null && details!.rating > 0) ? details!.rating : movie.rating;

    final poster = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: _PosterImage(url: movie.streamIcon),
      ),
    );

    final texts = _MovieHeaderTexts(
      name: movie.name,
      rating: rating,
      details: details,
      metadataStatus: metadataStatus,
      metadataError: metadataError,
      playButtonFocusNode: playButtonFocusNode,
      onPlay: onPlay,
      onRetryMetadata: onRetryMetadata,
    );

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.l),
      child: isWide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 180, child: poster),
                const SizedBox(width: 20),
                Expanded(child: texts),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: SizedBox(width: 160, child: poster)),
                const SizedBox(height: AppSpacing.l),
                texts,
              ],
            ),
    );
  }
}

class _MovieHeaderTexts extends StatelessWidget {
  final String name;
  final double rating;
  final VodDetails? details;
  final LoadStatus metadataStatus;
  final String? metadataError;
  final FocusNode playButtonFocusNode;
  final VoidCallback onPlay;
  final VoidCallback onRetryMetadata;

  const _MovieHeaderTexts({
    required this.name,
    required this.rating,
    required this.details,
    required this.metadataStatus,
    required this.metadataError,
    required this.playButtonFocusNode,
    required this.onPlay,
    required this.onRetryMetadata,
  });

  String _formatDuration(double seconds) {
    final duration = Duration(seconds: seconds.round());
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    return hours > 0 ? '${hours}h ${minutes}min' : '${minutes}min';
  }

  @override
  Widget build(BuildContext context) {
    final genre = details?.genre ?? '';
    final plot = details?.plot ?? '';
    final cast = details?.cast ?? '';
    final director = details?.director ?? '';
    final durationSecs = details?.durationSecs ?? 0;

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
            if (durationSecs > 0) _MetaChip(icon: Icons.schedule, text: _formatDuration(durationSecs)),
          ],
        ),
        const SizedBox(height: AppSpacing.l),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            focusNode: playButtonFocusNode,
            autofocus: true,
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Assistir'),
          ),
        ),
        const SizedBox(height: AppSpacing.l),
        if (metadataStatus == LoadStatus.loading && details == null) const _PlotSkeleton(),
        if (metadataStatus == LoadStatus.error && details == null)
          _MetadataErrorHint(message: metadataError, onRetry: onRetryMetadata),
        if (plot.isNotEmpty) Text(plot, style: TextStyle(color: Colors.grey.shade300, height: 1.4)),
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

class _PosterImage extends StatelessWidget {
  final String url;

  const _PosterImage({required this.url});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: AppTheme.surfaceColor,
      alignment: Alignment.center,
      child: Icon(Icons.movie, size: 40, color: Colors.grey.shade500),
    );

    return NetworkImageWithFallback(url: url, fallback: fallback, cacheWidth: 480);
  }
}

/// Placeholder só da sinopse, enquanto `get_vod_info` ainda não respondeu --
/// pôster/título/nota/botão "Assistir" acima já aparecem de verdade desde o
/// primeiro frame (vêm do [VodStream] recebido da HomeScreen, não deste
/// carregamento).
class _PlotSkeleton extends StatelessWidget {
  const _PlotSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkeletonBox(height: 14),
        SizedBox(height: 6),
        SkeletonBox(height: 14),
        SizedBox(height: 6),
        SkeletonBox(height: 14, width: 180),
      ],
    );
  }
}

/// Erro ao carregar SÓ a sinopse/elenco -- nunca bloqueia "Assistir" (que já
/// funciona com o que a HomeScreen já tinha), por isso é um hint discreto
/// inline, não uma tela cheia de erro como em SeriesDetailsScreen (lá, sem
/// `get_series_info` não há episódio nenhum pra tocar).
class _MetadataErrorHint extends StatelessWidget {
  final String? message;
  final VoidCallback onRetry;

  const _MetadataErrorHint({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.info_outline, size: 16, color: Colors.grey.shade500),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            message ?? 'Não foi possível carregar a sinopse.',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('Tentar novamente')),
      ],
    );
  }
}
