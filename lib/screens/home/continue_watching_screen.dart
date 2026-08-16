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
/// de VOD/Séries ([PosterCard] + [AppCardSizes.posterGridDelegate]). Cada
/// card tem um "X" pra remover só aquele item; a AppBar tem "Limpar tudo"
/// pra esvaziar a lista inteira de uma vez.
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

  /// Remoção de um item só -- direto, sem confirmação (mesmo padrão do
  /// coração de favoritar em outras telas: uma ação reversível o
  /// suficiente -- assistir de novo já recria a entrada -- não precisa de
  /// diálogo).
  void _removeOne(BuildContext context, WatchProgress progress) {
    context.read<ContinueWatchingProvider>().remove(progress.contentId);
  }

  /// "Limpar tudo" SEMPRE confirma antes -- ao contrário da remoção
  /// individual, apaga a lista inteira de uma vez só, mesmo padrão de
  /// confirmação já usado pra outras ações destrutivas do app (sair,
  /// remover PIN).
  Future<void> _clearAll(BuildContext context) async {
    final continueWatching = context.read<ContinueWatchingProvider>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Limpar "Continuar Assistindo"?'),
        content: const Text('Remove todo o progresso salvo. Você pode continuar assistindo qualquer um de novo do início quando quiser.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Limpar tudo')),
        ],
      ),
    );

    if (confirmed == true) {
      await continueWatching.clearAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Continuar Assistindo'),
          actions: [
            Consumer<ContinueWatchingProvider>(
              builder: (context, provider, _) => IconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: 'Limpar tudo',
                onPressed: provider.items.isEmpty ? null : () => _clearAll(context),
              ),
            ),
          ],
        ),
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
                    onRemove: () => _removeOne(context, progress),
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
