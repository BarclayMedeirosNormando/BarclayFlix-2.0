import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/fade_slide_route.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/watch_progress.dart';
import '../../providers/continue_watching_provider.dart';
import '../../widgets/dpad_focus_highlight.dart';
import '../../widgets/poster_card.dart';
import '../../widgets/state_placeholders.dart';
import '../player/player_screen.dart';

/// [TESTE] Tela "Continuar Assistindo" -- grid liso do progresso salvo
/// (sem categorias, ver [ContinueWatchingProvider]), mesmo padrão visual
/// de VOD/Séries ([PosterCard] + [AppCardSizes.posterGridDelegate]).
class ContinueWatchingScreen extends StatelessWidget {
  const ContinueWatchingScreen({super.key});

  void _play(BuildContext context, WatchProgress progress) {
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

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Continuar Assistindo')),
        body: Consumer<ContinueWatchingProvider>(
          builder: (context, provider, _) {
            final items = provider.items;

            if (items.isEmpty) {
              return const EmptyHint(
                icon: Icons.history,
                message: 'Nada assistido ainda. O que você continuar aqui '
                    'aparece automaticamente.',
              );
            }

            return GridView.builder(
              padding: const EdgeInsets.all(AppSpacing.m),
              gridDelegate: AppCardSizes.posterGridDelegate,
              itemCount: items.length,
              itemBuilder: (context, index) {
                final progress = items[index];

                return DpadFocusHighlight(
                  key: ValueKey('continue_watching_${progress.contentId}'),
                  builder: (context, focusNode, hasFocus) => PosterCard(
                    focusNode: focusNode,
                    title: progress.title,
                    imageUrl: progress.imageUrl,
                    fallbackIcon: progress.type == WatchProgressType.episode ? Icons.video_library : Icons.movie,
                    rating: 0,
                    progressFraction: progress.fraction,
                    onTap: () => _play(context, progress),
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
