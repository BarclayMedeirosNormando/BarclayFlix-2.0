import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import 'dpad_focus_highlight.dart';

/// Cabeçalho de seleção de categoria + busca local inline — genérico o
/// bastante para qualquer aba de conteúdo com um filtro de categorias
/// (Live TV, VOD, Séries, ver HomeScreen._SearchableTabView): não depende
/// de `ContentType`/`ContentProvider`, só recebe os widgets de categoria já
/// prontos (normalmente um `_CategoriesChips`/`_CategoriesSidebar`).
///
/// Ativar a lupa expande um campo de texto INLINE, ali mesmo — nunca uma
/// tela nova nem um overlay/modal (ver histórico de UI do
/// ServerSelectionScreen: motivo já documentado lá para não repetir aqui).
/// Layout estreito ([isWide] false): o campo cobre a própria linha de
/// categorias enquanto ativo. Layout largo ([isWide] true): o campo aparece
/// como uma barra abaixo da coluna de categorias, cobrindo só a faixa onde
/// ficaria a lupa — a lista de categorias acima continua visível e usável
/// (a busca já filtra em cima do resultado da categoria selecionada, então
/// não precisa escondê-la).
///
/// [wideCategoriesWidget] é sempre DECLARADO ANTES da lupa na árvore (ver
/// doc de `HomeScreen._SearchableTabView`) — importa pro autofoco inicial
/// da tela (`HomeScreen._handOffInitialFocusIfReady`) achar a primeira
/// categoria, não a lupa.
class CategoryFilterHeader extends StatelessWidget {
  final bool isWide;
  final bool searching;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final String searchHintText;
  final VoidCallback onOpenSearch;
  final VoidCallback onCloseSearch;
  final ValueChanged<String> onQueryChanged;

  /// Widget de categorias mostrado no layout ESTREITO (chips), na mesma
  /// linha da lupa quando ela não está ativa.
  final Widget narrowCategoriesWidget;

  /// Widget de categorias mostrado no layout LARGO (sidebar), acima da
  /// linha de busca.
  final Widget wideCategoriesWidget;

  const CategoryFilterHeader({
    super.key,
    required this.isWide,
    required this.searching,
    required this.searchController,
    required this.searchFocusNode,
    required this.searchHintText,
    required this.onOpenSearch,
    required this.onCloseSearch,
    required this.onQueryChanged,
    required this.narrowCategoriesWidget,
    required this.wideCategoriesWidget,
  });

  @override
  Widget build(BuildContext context) {
    final toggle = searching
        ? DpadFocusHighlight(
            key: const ValueKey('category_filter_search_close'),
            scaleOnFocus: false,
            builder: (context, focusNode, hasFocus) => IconButton(
              focusNode: focusNode,
              icon: const Icon(Icons.close),
              tooltip: 'Fechar busca',
              onPressed: onCloseSearch,
            ),
          )
        : DpadFocusHighlight(
            key: const ValueKey('category_filter_search_open'),
            scaleOnFocus: false,
            builder: (context, focusNode, hasFocus) => IconButton(
              focusNode: focusNode,
              icon: const Icon(Icons.search),
              tooltip: 'Buscar',
              onPressed: onOpenSearch,
            ),
          );

    final row = SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
        child: Row(
          children: [
            Expanded(
              child: searching
                  ? CategoryFilterSearchField(
                      controller: searchController,
                      focusNode: searchFocusNode,
                      hintText: searchHintText,
                      onChanged: onQueryChanged,
                    )
                  : (isWide ? const SizedBox.shrink() : narrowCategoriesWidget),
            ),
            toggle,
          ],
        ),
      ),
    );

    if (!isWide) return row;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: wideCategoriesWidget),
        const Divider(height: 1),
        row,
      ],
    );
  }
}

/// Campo de busca inline (aparece só com [CategoryFilterHeader.searching]
/// ativo) — filtra a lista de itens já carregada localmente, sem nenhuma
/// chamada de rede nova. `onChanged` direto (sem debounce): filtrar uma
/// lista já em memória é barato, não precisa da folga usada normalmente
/// pra evitar chamadas de rede repetidas a cada tecla.
class CategoryFilterSearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final ValueChanged<String> onChanged;

  const CategoryFilterSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: true,
      onChanged: onChanged,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        hintText: hintText,
        prefixIcon: const Icon(Icons.search, size: 18),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }
}
