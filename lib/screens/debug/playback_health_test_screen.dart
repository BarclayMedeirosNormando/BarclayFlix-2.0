import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../services/playback_health_monitor.dart';
import '../../services/stream_url_builder.dart';

/// Bancada de teste MANUAL para observar o [PlaybackHealthMonitor] reagindo
/// em tempo real (overlay + log) contra streams de verdade, antes de
/// integrá-lo na `PlayerScreen` real — não substitui os testes unitários,
/// só valida visualmente o que eles já cobrem isoladamente.
///
/// NUNCA integrada ao fluxo real de navegação de canais/VOD/séries — só
/// alcançável pelo botão de bug (kDebugMode) da HomeScreen. Ver aviso de
/// remoção no fim do arquivo antes de mesclar para main.
///
/// Não hardcoda nenhum domínio/credencial de painel real: DNS/usuário/
/// senha/stream_id são digitados em tela a cada sessão de teste, do mesmo
/// jeito que viriam do Master Login em produção (SavedProfile) — nunca
/// ficam no código-fonte.
class PlaybackHealthTestScreen extends StatefulWidget {
  const PlaybackHealthTestScreen({super.key});

  @override
  State<PlaybackHealthTestScreen> createState() => _PlaybackHealthTestScreenState();
}

class _PlaybackHealthTestScreenState extends State<PlaybackHealthTestScreen> {
  final _dnsController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _streamIdController = TextEditingController();

  late final Player _player;
  late final VideoController _videoController;
  PlaybackHealthMonitor? _monitor;

  String? _activeScenario;
  String? _healthStatus;
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    // MediaKit.ensureInitialized() já rodou uma vez em main() — mesmo
    // Player/VideoController "de verdade" que a PlayerScreen real usa,
    // só que sem passar por PlayerProvider (aqui queremos acesso direto ao
    // Player pra plugar o PlaybackHealthMonitor manualmente).
    _player = Player();
    _videoController = VideoController(_player);
  }

  @override
  void dispose() {
    _monitor?.dispose();
    unawaited(_player.dispose());
    _dnsController.dispose();
    _userController.dispose();
    _passController.dispose();
    _streamIdController.dispose();
    super.dispose();
  }

  String get _timestamp {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  void _appendLog(String message) {
    final line = '[$_timestamp] $message';
    debugPrint('[PlaybackHealthTest] $line');
    if (!mounted) return;
    setState(() => _log.insert(0, line));
  }

  /// Encerra o cenário anterior (se houver) e começa um novo do zero —
  /// cada botão é um teste isolado, sem herdar estado (contadores de
  /// retry, índice de URL) do cenário anterior.
  Future<void> _startScenario(String label, List<String> fallbackUrls) async {
    _monitor?.dispose();

    setState(() {
      _activeScenario = label;
      _healthStatus = null;
      _log.clear();
    });

    _appendLog('Cenário "$label" iniciado');
    _appendLog('Abrindo URL inicial: ${fallbackUrls.first}');

    _monitor = PlaybackHealthMonitor(
      player: _player,
      fallbackUrls: fallbackUrls,
      onStatusChange: (status) {
        if (!mounted) return;
        setState(() => _healthStatus = status);
        _appendLog(status);
      },
      onUrlSwitch: (newUrl) {
        _appendLog('Trocando para URL alternativa: $newUrl');
        unawaited(_player.open(Media(newUrl)));
      },
    )..start();

    await _player.open(Media(fallbackUrls.first));
  }

  List<String>? _buildLiveFallbackChain({required bool forceInvalid}) {
    final dns = _dnsController.text.trim();
    final user = _userController.text.trim();
    final pass = _passController.text.trim();
    final streamId = _streamIdController.text.trim();
    if (dns.isEmpty || user.isEmpty || pass.isEmpty || streamId.isEmpty) return null;

    return StreamUrlBuilder.buildFallbackChain(
      dns: dns,
      username: user,
      password: pass,
      // Sufixo garante um stream_id que quase certamente não existe no
      // painel, sem depender de adivinhar um número "claramente inválido"
      // que por acaso coincida com um canal real.
      streamId: forceInvalid ? '${streamId}999invalido' : streamId,
      contentType: StreamContentType.live,
    );
  }

  void _onInvalidUrlPressed() {
    final chain = _buildLiveFallbackChain(forceInvalid: true);
    if (chain == null) return _showMissingFieldsSnackbar();
    _startScenario('URL inválida direto', chain);
  }

  void _onValidUrlPressed() {
    final chain = _buildLiveFallbackChain(forceInvalid: false);
    if (chain == null) return _showMissingFieldsSnackbar();
    _startScenario('URL válida (controle)', chain);
  }

  void _onStallPressed() {
    // 192.0.2.0/24 é o bloco reservado TEST-NET-1 (RFC 5737): nunca é
    // roteado na internet real, então a conexão fica tentando conectar
    // (nem sucesso nem "connection refused") até o socket dar timeout, em
    // vez de falhar rápido como uma URL só inválida faria. É a forma mais
    // previsível de simular "buffering que nunca resolve" sem depender de
    // um servidor lento de verdade.
    const stallUrl = 'http://192.0.2.1:8080/live/x/x/1.ts';
    _startScenario('Simular stall (host inalcançável)', const [stallUrl]);
  }

  void _showMissingFieldsSnackbar() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Preencha DNS, usuário, senha e stream_id antes.')),
    );
  }

  Color _statusColor() {
    final status = _healthStatus;
    if (status == null) return Colors.white54;
    if (status == 'Falha definitiva') return Colors.redAccent;
    if (status.startsWith('Reconectando')) return Colors.orangeAccent;
    if (status.startsWith('Tentando qualidade')) return Colors.yellowAccent;
    return Colors.greenAccent;
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) {
      // Defesa em profundidade: mesmo que algo navegue pra cá fora de
      // debug (não deveria — só o botão condicional da HomeScreen leva
      // aqui), não expõe formulário nem player nenhum.
      return const Scaffold(
        body: Center(child: Text('Tela de debug indisponível fora do modo debug.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('[DEBUG] PlaybackHealthMonitor')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _dnsController,
                  decoration: const InputDecoration(labelText: 'DNS (ex: http://painel.com:8080)'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _userController,
                        decoration: const InputDecoration(labelText: 'Usuário Xtream'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _passController,
                        decoration: const InputDecoration(labelText: 'Senha Xtream'),
                        obscureText: true,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _streamIdController,
                        decoration: const InputDecoration(labelText: 'stream_id (canal ao vivo)'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed: _onInvalidUrlPressed,
                      child: const Text('URL inválida direto'),
                    ),
                    ElevatedButton(
                      onPressed: _onValidUrlPressed,
                      child: const Text('URL válida (controle)'),
                    ),
                    ElevatedButton(
                      onPressed: _onStallPressed,
                      child: const Text('Simular stall'),
                    ),
                    OutlinedButton(
                      onPressed: _monitor == null ? null : () => _monitor!.reset(),
                      child: const Text('reset() no monitor'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Video(controller: _videoController, controls: null, fill: Colors.black),
                ),
                if (_activeScenario != null)
                  Positioned(
                    top: 12,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: _statusColor()),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _activeScenario!,
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                            Text(
                              _healthStatus ?? '(sem eventos ainda)',
                              style: TextStyle(
                                color: _statusColor(),
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            height: 180,
            width: double.infinity,
            color: Colors.black,
            padding: const EdgeInsets.all(8),
            child: ListView.builder(
              itemCount: _log.length,
              itemBuilder: (context, index) => Text(
                _log[index],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.greenAccent),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// AVISO: esta é uma tela de bancada de teste, não faz parte do produto.
// Antes do merge desta branch (teste/fallback-streaming) para main, remover
// lib/screens/debug/ inteira (e o botão condicional correspondente na
// HomeScreen) OU mover para uma pasta explicitamente excluída do build de
// release, se decidirmos manter esse tipo de ferramenta disponível entre
// desenvolvedores no futuro.
// ---------------------------------------------------------------------
