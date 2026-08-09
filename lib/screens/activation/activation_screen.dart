import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/device_login_result.dart';
import '../../data/services/device_id_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/profiles_provider.dart';
import '../home/home_screen.dart';
import '../server_selection/server_selection_screen.dart';

/// Intervalo entre verificações automáticas em segundo plano de "este
/// dispositivo já foi ativado?" — curto o bastante pra parecer instantâneo
/// pra quem acabou de mandar o código pro suporte, longo o bastante pra não
/// martelar o Apps Script (rate limit) enquanto a tela fica aberta minutos
/// esperando.
const _checkInterval = Duration(seconds: 6);

/// Única porta de entrada do app quando este dispositivo ainda não está
/// vinculado a um cliente (ver SplashScreen: cai aqui quando não há perfil
/// salvo, ou quando a revalidação de um perfil salvo falha). Mostra o
/// código deste dispositivo (derivado do deviceId, ver DeviceIdService) e
/// fica verificando sozinha, em segundo plano, se o suporte já cadastrou
/// este aparelho — nenhum input do usuário é necessário.
class ActivationScreen extends StatefulWidget {
  /// Mensagem/código já prontos pra exibir assim que a tela abre, sem
  /// esperar o primeiro tick do timer — usados pela SplashScreen quando a
  /// revalidação de um perfil salvo já falhou com um código BLOQUEANTE
  /// (`"inativo"`/`"expirado"`, ver [_isBlockingCode]): nesse caso a tela
  /// abre já mostrando o erro real, sem timer nenhum (repetir a consulta
  /// não resolveria sozinho). Para qualquer outro motivo de falha
  /// (`"nao_registrado"`, erro de rede, ou nenhum perfil salvo) o timer
  /// começa normalmente.
  final String? initialErrorMessage;
  final String? initialErrorCode;

  const ActivationScreen({super.key, this.initialErrorMessage, this.initialErrorCode});

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _deviceIdService = DeviceIdService();
  Timer? _timer;

  String? _displayCode;
  bool _checking = false;

  /// Erro real do backend (`"inativo"`/`"expirado"`) — precisa de ação
  /// humana (contatar o suporte), nunca se resolve tentando de novo, então
  /// para o timer assim que aparece (ver [_isBlockingCode]).
  late String? _blockingErrorMessage =
      _isBlockingCode(widget.initialErrorCode) ? widget.initialErrorMessage : null;

  @override
  void initState() {
    super.initState();
    _loadDeviceIdAndStart();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool _isBlockingCode(String? code) => code == 'inativo' || code == 'expirado';

  Future<void> _loadDeviceIdAndStart() async {
    final id = await _deviceIdService.getDeviceId();
    if (!mounted) return;

    setState(() {
      _displayCode = _formatDeviceCode(id);
    });

    // Quando a SplashScreen já chegou com um erro bloqueante, a checagem
    // periódica nem começa -- ver doc de [initialErrorMessage].
    if (_blockingErrorMessage == null) {
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_checkInterval, (_) => _check());
  }

  Future<void> _check() async {
    if (!mounted) return;
    setState(() => _checking = true);

    final profilesProvider = context.read<ProfilesProvider>();
    final result = await profilesProvider.checkDeviceActivation();

    if (!mounted) return;

    if (result != null) {
      _timer?.cancel();
      _timer = null;
      await _onActivated(result);
      return;
    }

    final authProvider = context.read<AuthProvider>();
    if (_isBlockingCode(authProvider.errorCode)) {
      _timer?.cancel();
      _timer = null;
      setState(() {
        _checking = false;
        _blockingErrorMessage =
            authProvider.errorMessage ?? 'Dispositivo inativo. Contate o suporte.';
      });
      return;
    }

    // "nao_registrado" (aguardando cadastro) ou erro genérico (rede etc):
    // estado normal de espera -- continua tentando em silêncio, sem alarmar.
    setState(() => _checking = false);
  }

  Future<void> _onActivated(DeviceAuthResult result) async {
    final profilesProvider = context.read<ProfilesProvider>();

    if (result.servidores.length == 1) {
      final success = await profilesProvider.chooseServer(
        server: result.servidores.single,
        nomeCliente: result.nomeCliente,
      );
      if (!mounted) return;

      if (success) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
          (route) => false,
        );
        return;
      }

      // Ativação do dispositivo OK, mas a validação Xtream falhou nesse
      // meio tempo (servidor fora do ar etc) -- nunca trava aqui: avisa e
      // volta a tentar sozinha.
      final message =
          context.read<AuthProvider>().errorMessage ?? 'Não foi possível conectar ao servidor.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      setState(() => _checking = false);
      _startTimer();
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ServerSelectionScreen(
          servers: result.servidores,
          nomeCliente: result.nomeCliente,
        ),
      ),
    );
  }

  void _copyCode() {
    final code = _displayCode;
    if (code == null) return;

    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Código copiado!'), duration: Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.live_tv_rounded, size: 72, color: AppTheme.primaryColor),
                const SizedBox(height: 16),
                const Text(
                  'Ative seu dispositivo',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Envie este código para ativar seu acesso',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade400),
                ),
                const SizedBox(height: 32),
                if (_displayCode == null)
                  const CircularProgressIndicator()
                else
                  _DeviceCodeCard(code: _displayCode!, onCopy: _copyCode),
                const SizedBox(height: 24),
                _StatusIndicator(checking: _checking, blockingErrorMessage: _blockingErrorMessage),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Formata o deviceId (um UUID v4 completo) num código curto, fácil de ler
/// à distância (ex: alguém lendo da TV pra digitar no WhatsApp do celular)
/// e de comunicar por voz/mensagem pro suporte: os 8 primeiros caracteres
/// hexadecimais do UUID, maiúsculos, em dois grupos de 4 separados por
/// hífen (ex: "A3F9-21CD").
///
/// É só uma REPRESENTAÇÃO CURTA pra humano -- toda requisição de ativação
/// (ver DeviceAuthService.check) sempre usa o [deviceId] completo, nunca
/// este código. O suporte precisa conseguir localizar o dispositivo a
/// partir só deste prefixo curto (o cadastro do lado do backend é quem
/// resolve isso, fora do escopo deste app).
String _formatDeviceCode(String deviceId) {
  final compact = deviceId.replaceAll('-', '').toUpperCase();
  final short = compact.length >= 8 ? compact.substring(0, 8) : compact.padRight(8, '0');
  return '${short.substring(0, 4)}-${short.substring(4, 8)}';
}

/// Cartão de destaque com o código do dispositivo: fonte grande e
/// monoespaçada (legível à distância, sem ambiguidade entre caracteres
/// parecidos) + botão de copiar para a área de transferência.
class _DeviceCodeCard extends StatelessWidget {
  final String code;
  final VoidCallback onCopy;

  const _DeviceCodeCard({required this.code, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          decoration: BoxDecoration(
            color: AppTheme.surfaceColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.primaryColor, width: 2),
          ),
          child: Text(
            code,
            style: const TextStyle(
              fontSize: 48,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              letterSpacing: 4,
            ),
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          autofocus: true,
          onPressed: onCopy,
          icon: const Icon(Icons.copy),
          label: const Text('Copiar código'),
        ),
      ],
    );
  }
}

/// Indicador discreto do estado da checagem automática -- nunca um spinner
/// bloqueante nem um erro alarmante para o estado normal de espera
/// ("nao_registrado"/aguardando cadastro): só aparece MAIS destacado (cor
/// de erro) quando há de fato algo que precisa de ação humana.
class _StatusIndicator extends StatelessWidget {
  final bool checking;
  final String? blockingErrorMessage;

  const _StatusIndicator({required this.checking, required this.blockingErrorMessage});

  @override
  Widget build(BuildContext context) {
    if (blockingErrorMessage != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.errorColor.withAlpha(30),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppTheme.errorColor, size: 32),
            const SizedBox(height: 8),
            Text(
              blockingErrorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.errorColor, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (checking) ...[
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
        ],
        Text(
          checking ? 'Verificando...' : 'Aguardando ativação...',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
        ),
      ],
    );
  }
}
