import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/device_login_result.dart';
import '../../providers/auth_provider.dart';
import '../../providers/profiles_provider.dart';
import '../../widgets/dpad_focus_highlight.dart';
import '../home/home_screen.dart';

/// Tela cheia (NUNCA um dialog/AlertDialog — ver histórico: um modal
/// sobreposto à tela de ativação era visualmente confuso e pior pra foco de
/// D-Pad em TV) de escolha de servidor. Mesmo estilo visual da
/// ActivationScreen (ícone de TV, mesma paleta) pra manter a identidade do
/// fluxo de autenticação.
///
/// Alcançada de duas formas:
/// - Primeira ativação (ActivationScreen, logo após o dispositivo ser
///   cadastrado pelo suporte com mais de um servidor vinculado).
/// - "Trocar de servidor" (HomeScreen, com a lista de servidores
///   REBUSCADA pela ativação deste mesmo dispositivo — ver
///   `existingProfileId`).
class ServerSelectionScreen extends StatefulWidget {
  final List<ServerOption> servers;

  /// Quando informado, o servidor escolhido ATUALIZA esse [SavedProfile] já
  /// existente (mesmo id) em vez de criar um novo — é o que diferencia
  /// "Trocar de servidor" (sempre informado) da primeira ativação (sempre
  /// `null`).
  final String? existingProfileId;

  /// Nome do cliente (vindo do Master Login/ativação de dispositivo, ver
  /// [DeviceAuthResult]) — personaliza o título ("Bem-vindo, {nomeCliente}")
  /// e é repassado a [ProfilesProvider.chooseServer] para persistir no
  /// [SavedProfile] resultante. Nunca usado na lógica de escolha do
  /// servidor em si. Quando `null`/vazio, o título cai no fallback do
  /// perfil salvo mais recente (ver [build]), e só se este também não
  /// tiver um nome persistido é que vira o título genérico "Escolha um
  /// servidor".
  final String? nomeCliente;

  const ServerSelectionScreen({
    super.key,
    required this.servers,
    this.existingProfileId,
    this.nomeCliente,
  });

  @override
  State<ServerSelectionScreen> createState() => _ServerSelectionScreenState();
}

class _ServerSelectionScreenState extends State<ServerSelectionScreen> {
  // dns do servidor sendo validado no momento (mostra loading só naquele
  // card específico) — `null` quando nenhuma escolha está em voo.
  String? _selectingDns;
  String? _errorMessage;

  // Versão instalada do app (package_info_plus, mesmo mecanismo usado pelo
  // check_version do Master Login para comparar com a versão mais recente).
  // Lida em segundo plano — a tela nunca espera por ela: começa `null` e o
  // título "Bem-vindo" ganha o sufixo " - v{versao}" assim que resolver.
  String? _appVersion;

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _appVersion = info.version);
    } catch (_) {
      // Sem versão disponível: título cai para o formato sem sufixo.
    }
  }

  Future<void> _choose(ServerOption server) async {
    setState(() {
      _selectingDns = server.dns;
      _errorMessage = null;
    });

    final profilesProvider = context.read<ProfilesProvider>();
    final success = await profilesProvider.chooseServer(
      server: server,
      existingProfileId: widget.existingProfileId,
      nomeCliente: widget.nomeCliente,
    );

    if (!mounted) return;

    if (success) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
      return;
    }

    // Erro real do backend (dispositivo bloqueado, credencial expirada
    // nesse meio tempo etc) — nunca trava a tela, só mostra a mensagem e
    // deixa escolher de novo (o mesmo servidor ou outro).
    setState(() {
      _selectingDns = null;
      _errorMessage = context.read<AuthProvider>().errorMessage ?? 'Não foi possível validar este servidor.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final isChoosing = _selectingDns != null;
    final freshNomeCliente = widget.nomeCliente?.trim();
    final persistedNomeCliente = context.watch<ProfilesProvider>().savedProfile?.nomeCliente?.trim();
    final nomeCliente = (freshNomeCliente != null && freshNomeCliente.isNotEmpty)
        ? freshNomeCliente
        : persistedNomeCliente;
    final titulo = (nomeCliente != null && nomeCliente.isNotEmpty)
        ? 'Bem-vindo, $nomeCliente${_appVersion != null ? ' - v$_appVersion' : ''}'
        : 'Escolha um servidor';

    return Scaffold(
      appBar: AppBar(title: const Text('Escolha um servidor')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.live_tv_rounded, size: 64, color: AppTheme.primaryColor),
              const SizedBox(height: 12),
              Text(
                titulo,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Sua conta tem acesso a mais de um servidor IPTV.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade400),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.errorColor),
                ),
              ],
              const SizedBox(height: 24),
              Expanded(
                child: FocusTraversalGroup(
                  child: GridView.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 220,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 1.3,
                    ),
                    itemCount: widget.servers.length,
                    itemBuilder: (context, index) {
                      final server = widget.servers[index];
                      final label = server.nome.trim().isNotEmpty ? server.nome.trim() : server.dns;
                      final isSelectingThis = _selectingDns == server.dns;

                      return DpadFocusHighlight(
                        key: ValueKey('server_option_${server.dns}'),
                        borderRadius: BorderRadius.circular(16),
                        builder: (context, focusNode, hasFocus) => InkWell(
                          autofocus: index == 0,
                          focusNode: focusNode,
                          onTap: isChoosing ? null : () => _choose(server),
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            decoration: BoxDecoration(
                              color: AppTheme.surfaceColor,
                              borderRadius: BorderRadius.circular(16),
                              // [TESTE] Anel sutil sempre visível (não só no
                              // foco, que já tem seu próprio glow via
                              // DpadFocusHighlight) -- dá mais presença ao
                              // card parado, mais perto da referência
                              // visual (ícones em destaque, não só texto
                              // sobre um retângulo liso).
                              border: Border.all(color: AppTheme.primaryColor.withAlpha(60)),
                            ),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.all(16),
                            child: isSelectingThis
                                ? const CircularProgressIndicator()
                                : Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // Ícone circular com anel de destaque
                                      // (estilo Duplecast: cada servidor
                                      // salvo vira um "selo" redondo, não só
                                      // um ícone solto) -- maior que antes
                                      // (36 -> 34 dentro de um círculo de
                                      // 64) pra ganhar presença sem estourar
                                      // o card na largura máxima do grid
                                      // (220, ver gridDelegate abaixo).
                                      Container(
                                        width: 64,
                                        height: 64,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: AppTheme.primaryColor.withAlpha(40),
                                          border: Border.all(color: AppTheme.primaryColor, width: 2),
                                        ),
                                        alignment: Alignment.center,
                                        child: const Icon(
                                          Icons.dns_rounded,
                                          size: 32,
                                          color: AppTheme.primaryColor,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        label,
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppTheme.cardTitleStyle,
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
