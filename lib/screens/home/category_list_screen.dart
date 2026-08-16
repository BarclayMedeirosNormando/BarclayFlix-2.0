import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/category_icons.dart';
import '../../data/models/xtream_models.dart';
import '../../providers/content_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/dpad_focus_highlight.dart';
import '../../widgets/skeleton_loader.dart';
import '../../widgets/state_placeholders.dart';
import '../settings/settings_screen.dart' show showEnterPinDialog;
import 'content_grid_screen.dart';
import 'live_channels_screen.dart';

/// [TESTE] Lista de categorias de UM [ContentType] (TV Ao Vivo/Filmes/
/// Séries) — tela cheia, lista simples (estilo Duplecast: "Todos" no topo,
/// depois as categorias reais), substitui a antiga sidebar/chips de
/// categoria que ficava embutida dentro do layout com menu lateral (ver
/// home_screen.dart antigo). Selecionar uma categoria abre a tela de
/// conteúdo certa: [LiveChannelsScreen] (lista) pra Live TV, ou
/// [ContentGridScreen] (grid de pôsteres) pra Filmes/Séries.
class CategoryListScreen extends StatefulWidget {
  final ContentType type;

  const CategoryListScreen({super.key, required this.type});

  @override
  State<CategoryListScreen> createState() => _CategoryListScreenState();
}

class _CategoryListScreenState extends State<CategoryListScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ContentProvider>().loadCategories(widget.type);
    });
  }

  String get _title => switch (widget.type) {
        ContentType.live => 'TV Ao Vivo',
        ContentType.vod => 'Filmes',
        ContentType.series => 'Séries',
      };

  /// Seleciona [categoryId] normalmente, A NÃO SER que esteja travada por
  /// PIN (ver SettingsProvider.isLocked) -- nesse caso pede o PIN antes,
  /// desbloqueia pra ESTA sessão (SettingsProvider.unlockForSession, nunca
  /// persistido) só depois de confirmado. PIN errado ou diálogo cancelado:
  /// não abre nada, categoria continua travada.
  Future<void> _openCategory(BuildContext context, Category category) async {
    final settings = context.read<SettingsProvider>();

    if (settings.isLocked(widget.type, category.id)) {
      final pin = await showEnterPinDialog(context, title: 'Digite o PIN pra ver esta categoria');
      if (pin == null || !context.mounted) return;

      final valid = await settings.verifyPin(pin);
      if (!context.mounted) return;
      if (!valid) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN incorreto.')));
        return;
      }
      settings.unlockForSession(widget.type, category.id);
    }

    if (!context.mounted) return;
    context.read<ContentProvider>().selectCategory(widget.type, category.id);

    if (widget.type == ContentType.live) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => LiveChannelsScreen(categoryId: category.id, categoryName: category.name),
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ContentGridScreen(type: widget.type, categoryId: category.id, categoryName: category.name),
        ),
      );
    }
  }

  /// Alterna o cadeado de [category] -- TRAVAR não pede PIN (sempre
  /// permitido, "fechar a porta" nunca precisa da chave). DESTRAVAR pede o
  /// PIN antes de tirar a proteção, senão o cadeado seria decorativo.
  Future<void> _toggleLock(BuildContext context, Category category) async {
    final settings = context.read<SettingsProvider>();

    if (!settings.isProtectedCategory(widget.type, category.id)) {
      settings.toggleProtectedCategory(widget.type, category.id);
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

    settings.toggleProtectedCategory(widget.type, category.id);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_title)),
        // Sem wrapper Focus(autofocus, skipTraversal) por fora -- esse
        // padrão prende o foco nele mesmo pra sempre (achado root-caused em
        // settings_screen.dart: busca DIRECIONAL não sai sozinha de um nó
        // skipTraversal). O autofoco real vai direto no primeiro ListTile
        // (ver `autofocus: index == 0` abaixo).
        body: Consumer2<ContentProvider, SettingsProvider>(
          builder: (context, provider, settings, _) {
              final status = provider.categoriesStatusFor(widget.type);
              final error = provider.categoriesErrorFor(widget.type);
              final categories = provider.categoriesFor(widget.type);

              if (status == LoadStatus.loading && categories.isEmpty) {
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.s),
                  itemCount: 8,
                  itemBuilder: (context, index) => const SkeletonListRow(),
                );
              }

              if (status == LoadStatus.error && categories.isEmpty) {
                return ErrorRetry(
                  message: error ?? 'Erro ao carregar categorias.',
                  onRetry: () => context.read<ContentProvider>().refresh(widget.type),
                );
              }

              if (categories.isEmpty) {
                return const EmptyHint(
                  icon: Icons.folder_off_outlined,
                  message: 'Nenhuma categoria encontrada.',
                );
              }

              return FocusTraversalGroup(
                child: ListView.builder(
                  itemCount: categories.length,
                  itemBuilder: (context, index) {
                    final category = categories[index];
                    final lockable = category.id != ContentProvider.allCategoriesId;
                    final protectedCategory = lockable && settings.isProtectedCategory(widget.type, category.id);

                    return DpadFocusHighlight(
                      key: ValueKey('category_${widget.type.name}_${category.id}'),
                      scaleOnFocus: false,
                      borderRadius: BorderRadius.circular(4),
                      builder: (context, focusNode, hasFocus) => Material(
                        type: MaterialType.transparency,
                        child: ListTile(
                          focusNode: focusNode,
                          autofocus: index == 0,
                          leading: Icon(categoryIcon(category.name), color: Colors.grey.shade400),
                          title: Text(category.name, overflow: TextOverflow.ellipsis),
                          trailing: (lockable && settings.hasPin)
                              ? GestureDetector(
                                  onTap: () => _toggleLock(context, category),
                                  child: Icon(
                                    protectedCategory ? Icons.lock : Icons.lock_open,
                                    size: 18,
                                    color: protectedCategory ? AppTheme.primaryColor : Colors.grey.shade500,
                                  ),
                                )
                              : null,
                          onTap: () => _openCategory(context, category),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
        ),
      ),
    );
  }
}



