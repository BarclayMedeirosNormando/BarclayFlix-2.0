import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../providers/content_provider.dart';
import 'dpad_focus_highlight.dart';

/// [TESTE] Seção de conteúdo navegável pelo [SectionSidebar] — substitui o
/// `TabController`/`TabBar` antigo. `continueWatching` não corresponde a
/// nenhum [ContentType] (não tem categorias, ver HomeScreen._ContinueWatchingTab),
/// por isso [contentType] é `null` só para ela — mesma guarda que
/// `_currentContentTabKey`/`_ensureCategoriesLoaded` já faziam com o índice
/// da TabBar antiga.
enum HomeSection {
  liveTv(ContentType.live, 'TV Ao Vivo', Icons.live_tv),
  vod(ContentType.vod, 'Filmes', Icons.movie),
  series(ContentType.series, 'Séries', Icons.video_library),
  continueWatching(null, 'Continuar Assistindo', Icons.history);

  const HomeSection(this.contentType, this.label, this.icon);

  final ContentType? contentType;
  final String label;
  final IconData icon;
}

/// [TESTE] Largura fixa do menu lateral no layout largo (≥ `_sidebarBreakpoint`
/// de home_screen.dart) — constante local, mesmo padrão já usado por
/// `_sidebarBreakpoint`/`AppCardSizes` (número compartilhado só entre quem
/// precisa dele, não um token de tema).
const double sectionSidebarWidth = 220;

/// [TESTE] Menu lateral fixo (estilo Duplecast) com as seções de conteúdo do
/// app + um grupo inferior de ações utilitárias. Substitui o `TabBar` que
/// ficava no topo da AppBar — a HomeScreen decide QUAL painel mostrar
/// (`IndexedStack`) a partir de [onSelectSection], este widget só sabe
/// exibir a lista e reportar cliques.
///
/// Distingue dois estados por item, propositalmente diferentes:
/// - FOCO (transitório, `DpadFocusHighlight`): o D-Pad está em cima do item
///   agora, mas o usuário ainda não confirmou (Enter/Select).
/// - ATIVO (persistente, `ListTile.selected` + `AppTheme.sidebarActiveBackground`):
///   é a seção sendo exibida agora, independente de onde o foco está — o
///   usuário pode mover o D-Pad pra dentro do conteúdo e o item ativo
///   continua marcado no menu.
///
/// Mesmo padrão visual que `_CategoriesSidebar` (home_screen.dart) já usa
/// pra categoria selecionada — `Material(type: transparency)` envolvendo o
/// `ListTile` é necessário pelo mesmo motivo de lá: o `DecoratedBox` do
/// `DpadFocusHighlight` fica entre o `ListTile` e o `Material` mais próximo
/// da árvore, escondendo `selectedTileColor`/ink splashes sem esse
/// intermediário.
class SectionSidebar extends StatelessWidget {
  final HomeSection selected;
  final ValueChanged<HomeSection> onSelectSection;
  final VoidCallback onOpenSettings;
  final VoidCallback onSwitchServer;
  final VoidCallback onExit;

  /// Move o spinner que antes ficava no botão "Trocar servidor" da AppBar
  /// (ver HomeScreen._switchingServer) pra dentro do item correspondente
  /// deste menu — precisa viajar junto com o callback, não só o `onPressed`.
  final bool switchingServer;

  /// [TESTE] Nó de escopo próprio (não um `FocusScope` anônimo) — o pai
  /// (HomeScreen) precisa de uma referência externa pra saber se o foco
  /// está "dentro do menu" (`hasFocus`) e pra devolver o foco pra cá vindo
  /// do conteúdo (ver `_enterMenu`/`_BoundaryDirectionalFocusAction` em
  /// home_screen.dart). Um `FocusScope` (ao contrário de um mero
  /// `FocusTraversalGroup`) genuinamente ISOLA a busca direcional (seta) —
  /// necessário porque, sem isso, a busca padrão do Flutter varre a tela
  /// inteira e pode preferir um item deste menu (mais alinhado
  /// verticalmente) a uma categoria mais próxima horizontalmente dentro do
  /// conteúdo, um "pulo" incorreto confirmado empiricamente rodando os
  /// testes deste redesenho.
  final FocusScopeNode focusScopeNode;

  /// Um [FocusNode] por [HomeSection] (indexado por `.index`), pra
  /// `_enterMenu()` conseguir focar exatamente a seção ATIVA ao voltar do
  /// conteúdo — os 3 itens do grupo inferior (Configurações/Trocar
  /// servidor/Sair) não precisam disso, gerenciam o próprio FocusNode
  /// internamente via [DpadFocusHighlight].
  final List<FocusNode> sectionFocusNodes;

  const SectionSidebar({
    super.key,
    required this.selected,
    required this.onSelectSection,
    required this.onOpenSettings,
    required this.onSwitchServer,
    required this.onExit,
    required this.focusScopeNode,
    required this.sectionFocusNodes,
    this.switchingServer = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: sectionSidebarWidth,
      child: FocusScope(
        node: focusScopeNode,
        child: FocusTraversalGroup(
          key: const ValueKey('section_sidebar'),
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.s),
              for (final section in HomeSection.values)
                _SidebarItem(
                  icon: section.icon,
                  label: section.label,
                  active: section == selected,
                  focusNode: sectionFocusNodes[section.index],
                  // O app sempre abre em Live TV (mesmo índice inicial que
                  // o TabController tinha) — autofoco direto no item
                  // concreto do menu, presente desde o 1º frame, substitui
                  // o hack antigo de `_rootFocusNode` + `nextFocus()`
                  // esperando as categorias chegarem da rede (não há mais
                  // nada pra esperar: este item não depende de rede).
                  autofocus: section == HomeSection.liveTv,
                  onTap: () => onSelectSection(section),
                ),
              const Spacer(),
              const Divider(height: 1),
              const SizedBox(height: AppSpacing.s),
              _SidebarItem(
                icon: Icons.settings_outlined,
                label: 'Configurações',
                active: false,
                onTap: onOpenSettings,
              ),
              _SidebarItem(
                icon: Icons.swap_horiz,
                label: 'Trocar servidor',
                active: false,
                loading: switchingServer,
                onTap: switchingServer ? null : onSwitchServer,
              ),
              _SidebarItem(
                icon: Icons.logout,
                label: 'Sair',
                active: false,
                onTap: onExit,
              ),
              const SizedBox(height: AppSpacing.s),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool autofocus;
  final bool loading;
  final VoidCallback? onTap;

  /// Só informado pelos 4 itens de conteúdo (ver `SectionSidebar.sectionFocusNodes`)
  /// — os 3 itens do grupo inferior deixam `DpadFocusHighlight` criar/gerenciar
  /// o próprio nó internamente, igual antes.
  final FocusNode? focusNode;

  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.active,
    this.autofocus = false,
    this.loading = false,
    this.focusNode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return DpadFocusHighlight(
      key: ValueKey('sidebar_item_$label'),
      focusNode: focusNode,
      scaleOnFocus: false,
      borderRadius: BorderRadius.circular(4),
      builder: (context, focusNode, hasFocus) => Material(
        type: MaterialType.transparency,
        child: ListTile(
          focusNode: focusNode,
          autofocus: autofocus,
          selected: active,
          selectedTileColor: AppTheme.sidebarActiveBackground,
          leading: loading
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                )
              : Icon(icon, color: active ? AppTheme.primaryColor : Colors.grey.shade400),
          title: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: active ? AppTheme.primaryColor : Colors.white),
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}
