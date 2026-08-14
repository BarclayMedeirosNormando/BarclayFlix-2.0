import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// Cabeçalho de seleção de categoria + busca local inline — genérico o
/// bastante para qualquer aba de conteúdo com um filtro de categorias
/// (Live TV, VOD, Séries, ver HomeScreen._SearchableTabView): não depende
/// de `ContentType`/`ContentProvider`, só recebe os widgets de categoria já
/// prontos (normalmente um `_CategoriesChips`/`_CategoriesSidebar`).
///
/// Abrir/fechar a busca é controlado de FORA (botão de lupa na AppBar da
/// HomeScreen, ver `_HomeScreenBodyState`) — este widget só reflete
/// [searching]; não tem toggle próprio. O campo em si continua expandindo
/// INLINE, ali mesmo — nunca uma tela nova nem um overlay/modal (ver
/// histórico de UI do ServerSelectionScreen: motivo já documentado lá para
/// não repetir aqui). Layout estreito ([isWide] false): o campo cobre a
/// própria linha de categorias enquanto ativo. Layout largo ([isWide] true):
/// o campo aparece como uma barra abaixo da coluna de categorias — a lista
/// de categorias acima continua visível e usável (a busca já filtra em cima
/// do resultado da categoria selecionada, então não precisa escondê-la).
///
/// [wideCategoriesWidget] é sempre DECLARADO ANTES da linha de busca na
/// árvore (ver doc de `HomeScreen._SearchableTabView`) — importa pro
/// autofoco inicial da tela (`HomeScreen._handOffInitialFocusIfReady`) achar
/// a primeira categoria.
class CategoryFilterHeader extends StatelessWidget {
  final bool isWide;
  final bool searching;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final String searchHintText;
  final ValueChanged<String> onQueryChanged;

  /// Widget de categorias mostrado no layout ESTREITO (chips), na mesma
  /// linha do campo de busca quando ele não está ativo.
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
    required this.onQueryChanged,
    required this.narrowCategoriesWidget,
    required this.wideCategoriesWidget,
  });

  @override
  Widget build(BuildContext context) {
    final row = SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
        child: searching
            ? CategoryFilterSearchField(
                controller: searchController,
                focusNode: searchFocusNode,
                hintText: searchHintText,
                onChanged: onQueryChanged,
              )
            : narrowCategoriesWidget,
      ),
    );

    if (!isWide) return row;

    // Layout largo sem busca ativa: só a sidebar, sem reservar espaço pra
    // linha de busca (que só existe de fato enquanto `searching`) -- ao
    // contrário do layout estreito acima, aqui não há mais nenhum controle
    // (a lupa virou global, na AppBar) pra ocupar essa faixa quando ociosa.
    if (!searching) return wideCategoriesWidget;

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
