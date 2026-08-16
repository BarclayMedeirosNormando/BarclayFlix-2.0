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
///
/// Duas formas de remover, pensadas pra cobrir toque E D-Pad:
/// - "X" em cada card (só toque/mouse -- sem FocusNode próprio, o D-Pad
///   nunca alcança ele sozinho).
/// - Modo "Selecionar" (botão na AppBar): com ele ativo, a MESMA navegação
///   de sempre entre os cards continua funcionando -- só o que o Enter/OK
///   faz muda (marca/desmarca em vez de tocar o vídeo), então não precisa
///   de nenhuma parada de foco extra por card pra ser 100% navegável por
///   D-Pad.
class ContinueWatchingScreen extends StatefulWidget {
  const ContinueWatchingScreen({super.key});

  @override
  State<ContinueWatchingScreen> createState() => _ContinueWatchingScreenState();
}

class _ContinueWatchingScreenState extends State<ContinueWatchingScreen> {
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  final FocusNode _selectToggleFocusNode = FocusNode(debugLabel: 'continue_watching_select_toggle');
  final FocusNode _actionButtonFocusNode = FocusNode(debugLabel: 'continue_watching_action_button');

  @override
  void dispose() {
    _selectToggleFocusNode.dispose();
    _actionButtonFocusNode.dispose();
    super.dispose();
  }

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
  /// coração de favoritar em outras telas: uma ação leve e reversível --
  /// assistir de novo já recria a entrada -- não precisa de diálogo).
  void _removeOne(BuildContext context, WatchProgress progress) {
    context.read<ContinueWatchingProvider>().remove(progress.contentId);
  }

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      _selectedIds.clear();
    });
  }

  void _toggleSelected(String contentId) {
    setState(() {
      if (!_selectedIds.remove(contentId)) _selectedIds.add(contentId);
    });
  }

  /// "Limpar tudo" (nada selecionado ainda) OU "Remover selecionados" (modo
  /// Selecionar com algo marcado) -- os dois SEMPRE confirmam antes, mesmo
  /// padrão já usado por outras ações destrutivas do app (sair, remover
  /// PIN).
  Future<void> _confirmAndRemove(BuildContext context, {required List<String> contentIds, required String message}) async {
    final continueWatching = context.read<ContinueWatchingProvider>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remover progresso salvo?'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Remover')),
        ],
      ),
    );

    if (confirmed != true) return;

    if (contentIds.length == 1) {
      await continueWatching.remove(contentIds.single);
    } else {
      for (final id in contentIds) {
        await continueWatching.remove(id);
      }
    }

    if (mounted) setState(() { _selecting = false; _selectedIds.clear(); });
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        // Sai do modo Selecionar primeiro (se estiver ativo); só volta pra
        // tela anterior de verdade na segunda vez -- evita sair sem querer
        // no meio de uma seleção.
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_selecting) {
            _toggleSelecting();
          } else {
            Navigator.maybePop(context);
          }
        },
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_selecting ? '${_selectedIds.length} selecionado(s)' : 'Continuar Assistindo'),
          actions: [
            Consumer<ContinueWatchingProvider>(
              builder: (context, provider, _) {
                if (provider.items.isEmpty && !_selecting) return const SizedBox.shrink();

                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_selecting)
                      DpadFocusHighlight(
                        focusNode: _actionButtonFocusNode,
                        borderRadius: BorderRadius.circular(24),
                        builder: (context, focusNode, hasFocus) => IconButton(
                          focusNode: focusNode,
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Remover selecionados',
                          onPressed: _selectedIds.isEmpty
                              ? null
                              : () => _confirmAndRemove(
                                    context,
                                    contentIds: _selectedIds.toList(),
                                    message: 'Remove o progresso salvo de ${_selectedIds.length} item(ns).',
                                  ),
                        ),
                      )
                    else
                      DpadFocusHighlight(
                        focusNode: _actionButtonFocusNode,
                        borderRadius: BorderRadius.circular(24),
                        builder: (context, focusNode, hasFocus) => IconButton(
                          focusNode: focusNode,
                          icon: const Icon(Icons.delete_sweep_outlined),
                          tooltip: 'Limpar tudo',
                          onPressed: provider.items.isEmpty
                              ? null
                              : () => _confirmAndRemove(
                                    context,
                                    contentIds: provider.items.map((p) => p.contentId).toList(),
                                    message: 'Remove todo o progresso salvo (${provider.items.length} item(ns)). Você pode continuar assistindo qualquer um de novo do início quando quiser.',
                                  ),
                        ),
                      ),
                    DpadFocusHighlight(
                      focusNode: _selectToggleFocusNode,
                      borderRadius: BorderRadius.circular(24),
                      builder: (context, focusNode, hasFocus) => IconButton(
                        focusNode: focusNode,
                        icon: Icon(_selecting ? Icons.close : Icons.checklist),
                        tooltip: _selecting ? 'Cancelar seleção' : 'Selecionar pra remover',
                        onPressed: provider.items.isEmpty && !_selecting ? null : _toggleSelecting,
                      ),
                    ),
                  ],
                );
              },
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
                final selected = _selectedIds.contains(progress.contentId);

                return DpadFocusHighlight(
                  key: ValueKey('continue_watching_${progress.contentId}'),
                  builder: (context, focusNode, hasFocus) => Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: selected ? Border.all(color: AppTheme.primaryColor, width: 3) : null,
                    ),
                    child: PosterCard(
                      focusNode: focusNode,
                      autofocus: index == 0,
                      title: progress.title,
                      imageUrl: progress.imageUrl,
                      fallbackIcon: progress.type == WatchProgressType.episode ? Icons.video_library : Icons.movie,
                      rating: 0,
                      progressFraction: progress.fraction,
                      topLeftBadge: selected
                          ? const CircleAvatar(
                              radius: 10,
                              backgroundColor: AppTheme.primaryColor,
                              child: Icon(Icons.check, size: 14, color: Colors.white),
                            )
                          : null,
                      onTap: _selecting
                          ? () => _toggleSelected(progress.contentId)
                          : () => _play(context, progress),
                      onRemove: _selecting ? null : () => _removeOne(context, progress),
                    ),
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
