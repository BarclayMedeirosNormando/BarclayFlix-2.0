import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/fade_slide_route.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_provider.dart';
import '../../providers/content_provider.dart' show ContentType;
import '../../providers/profiles_provider.dart';
import '../../widgets/dpad_focus_highlight.dart';
import '../activation/activation_screen.dart';
import '../server_selection/server_selection_screen.dart';
import '../settings/settings_screen.dart';
import 'category_list_screen.dart';
import 'continue_watching_screen.dart';

/// [TESTE] Tela principal pós-login -- hub com 5 cards grandes (TV Ao Vivo,
/// Filmes, Séries, Continuar Assistindo, Configurações), estilo Duplecast
/// (mesmo padrão visual do card de servidor em ServerSelectionScreen).
/// Substitui o antigo menu lateral fixo + IndexedStack (ver
/// [[project_sidebar_nav_redesign]]) -- cada card agora navega pra sua
/// PRÓPRIA tela cheia (CategoryListScreen/ContinueWatchingScreen/
/// SettingsScreen) via `Navigator.push`, em vez de tudo viver dentro de uma
/// única tela com múltiplos FocusScopes coordenados à mão.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // ContentProvider (raiz do app, ver main.dart) já observa AuthProvider
    // sozinho e atualiza o apiService usado sozinho -- este `read` aqui é
    // só pra decidir SE mostra o hub ou o aviso de sessão expirada.
    final apiService = context.read<AuthProvider>().apiService;

    if (apiService == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Sessão expirada. Ative o dispositivo novamente.'),
                const SizedBox(height: AppSpacing.l),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const ActivationScreen()),
                    (route) => false,
                  ),
                  child: const Text('Ir para a ativação'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return const _HubBody();
  }
}

enum _HubTile {
  liveTv('TV Ao Vivo', Icons.live_tv_rounded),
  vod('Filmes', Icons.movie_rounded),
  series('Séries', Icons.video_library_rounded),
  continueWatching('Continuar Assistindo', Icons.history_rounded),
  settings('Configurações', Icons.settings_rounded);

  const _HubTile(this.label, this.icon);

  final String label;
  final IconData icon;
}

class _HubBody extends StatefulWidget {
  const _HubBody();

  @override
  State<_HubBody> createState() => _HubBodyState();
}

class _HubBodyState extends State<_HubBody> {
  bool _switchingServer = false;

  void _openTile(_HubTile tile) {
    switch (tile) {
      case _HubTile.liveTv:
        Navigator.of(context).push(fadeSlideRoute((_) => const CategoryListScreen(type: ContentType.live)));
      case _HubTile.vod:
        Navigator.of(context).push(fadeSlideRoute((_) => const CategoryListScreen(type: ContentType.vod)));
      case _HubTile.series:
        Navigator.of(context).push(fadeSlideRoute((_) => const CategoryListScreen(type: ContentType.series)));
      case _HubTile.continueWatching:
        Navigator.of(context).push(fadeSlideRoute((_) => const ContinueWatchingScreen()));
      case _HubTile.settings:
        Navigator.of(context).push(fadeSlideRoute((_) => const SettingsScreen()));
    }
  }

  /// Rebusca a lista de servidores vinculados a este MESMO dispositivo já
  /// ativado e leva pra ServerSelectionScreen -- nunca apaga nada do
  /// StorageService, nunca desvincula o dispositivo. Só depois de escolher
  /// um servidor lá é que o perfil salvo é atualizado (ver
  /// ServerSelectionScreen/ProfilesProvider.chooseServer).
  Future<void> _switchServer(BuildContext context) async {
    final profilesProvider = context.read<ProfilesProvider>();
    final profile = profilesProvider.savedProfile;
    if (profile == null) return;

    setState(() => _switchingServer = true);

    final result = await profilesProvider.checkDeviceActivation();

    if (!context.mounted) return;
    setState(() => _switchingServer = false);

    if (result == null) {
      // Erro real do backend (ex: dispositivo inativo, expirado nesse meio
      // tempo) -- nunca trava a tela: só avisa e deixa o usuário continuar
      // usando a sessão atual normalmente.
      final message = context.read<AuthProvider>().errorMessage ?? 'Não foi possível buscar os servidores.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServerSelectionScreen(
          servers: result.servidores,
          existingProfileId: profile.id,
          nomeCliente: result.nomeCliente,
        ),
      ),
    );
  }

  /// Hub é a única rota na pilha (splash/login chegam aqui via
  /// `pushReplacement`), então sem essa interceptação o botão/tecla Voltar
  /// já derrubaria o app direto — aqui vira uma saída deliberada, com
  /// confirmação, igual o padrão esperado em apps de Android TV.
  Future<void> _confirmExit(BuildContext context) async {
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sair do app?'),
        content: const Text('Tem certeza que deseja sair do BarclayFlix 2.0?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sair'),
          ),
        ],
      ),
    );

    if (shouldExit == true) {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // `watch` (não `read`): o título precisa re-renderizar sozinho quando
    // _switchServer (acima) troca o perfil salvo por um servidor diferente,
    // sem precisar de nenhum setState manual aqui.
    final connectedServerName = context.watch<ProfilesProvider>().savedProfile?.nomeExibicao;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => _confirmExit(context),
      },
      child: PopScope(
        // Intercepta o Back do sistema (D-Pad "Voltar" no Android TV, botão
        // físico/gesto no Android) para confirmar antes de fechar o app, em
        // vez de derrubar a tela sem aviso.
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _confirmExit(context);
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(connectedServerName ?? 'BarclayFlix 2.0'),
            actions: [
              IconButton(
                icon: _switchingServer
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : const Icon(Icons.swap_horiz),
                tooltip: 'Trocar servidor',
                onPressed: _switchingServer ? null : () => _switchServer(context),
              ),
              IconButton(
                icon: const Icon(Icons.logout),
                tooltip: 'Sair',
                onPressed: () => _confirmExit(context),
              ),
            ],
          ),
          body: FocusTraversalGroup(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.l),
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  mainAxisSpacing: AppSpacing.l,
                  crossAxisSpacing: AppSpacing.l,
                  childAspectRatio: 1.3,
                ),
                itemCount: _HubTile.values.length,
                itemBuilder: (context, index) {
                  final tile = _HubTile.values[index];

                  return DpadFocusHighlight(
                    key: ValueKey('hub_tile_${tile.name}'),
                    borderRadius: BorderRadius.circular(16),
                    builder: (context, focusNode, hasFocus) => InkWell(
                      autofocus: index == 0,
                      focusNode: focusNode,
                      onTap: () => _openTile(tile),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceColor,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppTheme.primaryColor.withAlpha(60)),
                        ),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.all(16),
                        // FittedBox(scaleDown), não um tamanho fixo -- mesmo
                        // raciocínio do card de servidor (ServerSelectionScreen):
                        // a altura real da célula varia com a largura da
                        // janela (childAspectRatio fixo acima), então numa
                        // janela estreita o ícone+texto precisa encolher em
                        // vez de estourar.
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppTheme.primaryColor.withAlpha(40),
                                  border: Border.all(color: AppTheme.primaryColor, width: 2),
                                ),
                                alignment: Alignment.center,
                                child: Icon(tile.icon, size: 32, color: AppTheme.primaryColor),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                tile.label,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: AppTheme.cardTitleStyle,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
