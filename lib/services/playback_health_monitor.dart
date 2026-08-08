import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// Fase atual do [PlaybackHealthMonitor], para quem consome (ex:
/// `PlayerScreen`) decidir o que exibir sem comparar o texto livre de
/// [PlaybackHealthMonitor.onStatusChange] ("Reconectando...", "Tentando
/// qualidade alternativa..." — esses são só para exibição, nunca para
/// lógica de UI).
enum HealthMonitorPhase {
  /// Nenhuma falha em andamento (ou o ciclo acabou de ser zerado por
  /// [PlaybackHealthMonitor.reset]).
  idle,

  /// Retry com backoff ou troca de URL na cadeia de fallback ainda em
  /// curso — o monitor está tentando se recuperar sozinho, sem precisar de
  /// ação do usuário.
  retrying,

  /// Cadeia de fallback esgotada — o monitor desistiu; só uma ação manual
  /// do usuário (retry) sai deste estado.
  failed,
}

/// Observa um [Player] do media_kit já em reprodução e reage a falhas
/// (erro reportado pelo player ou buffering que nunca volta a `false`)
/// tentando se recuperar sozinho antes de desistir: primeiro com retry com
/// backoff na URL atual, depois trocando para a próxima URL de
/// [fallbackUrls] (tipicamente vinda de `StreamUrlBuilder.buildFallbackChain`),
/// e só reportando falha definitiva quando toda a cadeia se esgota.
///
/// Não decide nada sobre a UI — apenas notifica [onStatusChange] (texto pra
/// exibir num overlay) e [onUrlSwitch] (quando decide abrir uma URL
/// diferente; para retry na mesma URL, chama `player.open` diretamente, sem
/// passar por esse callback).
class PlaybackHealthMonitor {
  PlaybackHealthMonitor({
    required this.player,
    required this.fallbackUrls,
    required this.onStatusChange,
    required this.onUrlSwitch,
  }) : assert(fallbackUrls.isNotEmpty, 'fallbackUrls não pode ser vazio');

  final Player player;
  final List<String> fallbackUrls;

  /// Ex: "Reconectando... (tentativa 2)", "Tentando qualidade
  /// alternativa...", "Falha definitiva".
  final void Function(String status) onStatusChange;

  /// Chamado só quando o monitor decide trocar de URL na cadeia de
  /// fallback — quem consome (ex: PlayerScreen) é responsável por de fato
  /// abrir [newUrl] no player.
  final void Function(String newUrl) onUrlSwitch;

  int _currentUrlIndex = 0;
  int _retryCount = 0;

  static const int _maxRetriesPerUrl = 3;
  static const List<Duration> _backoffDelays = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  /// Buffering contínuo além deste tempo (sem voltar a `false`) é tratado
  /// como falha — cobre o caso em que o player nunca reporta um erro
  /// explícito, só fica preso "carregando" indefinidamente.
  static const Duration _stallTimeout = Duration(seconds: 15);

  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _bufferingSub;
  Timer? _stallTimer;
  Timer? _retryTimer;

  bool _disposed = false;
  bool _failedDefinitively = false;

  /// Evita contar a mesma falha duas vezes quando o erro explícito do
  /// player e o timeout de stall chegam quase juntos (ex: a conexão cai e
  /// tanto `stream.error` quanto o buffering travado indicam o mesmo
  /// problema) — enquanto um retry já está agendado, novas falhas são
  /// ignoradas até ele de fato executar.
  bool _retryScheduled = false;

  HealthMonitorPhase _phase = HealthMonitorPhase.idle;

  /// Fase atual do ciclo de retry/fallback — ver [HealthMonitorPhase].
  /// Sempre reflete o mesmo estado por trás do texto mais recente entregue
  /// a [onStatusChange], só que como um valor comparável (não string livre).
  HealthMonitorPhase get phase => _phase;

  void start() {
    _errorSub = player.stream.error.listen((_) => _handleFailure());
    _bufferingSub = player.stream.buffering.listen(_onBufferingChanged);
  }

  void _onBufferingChanged(bool buffering) {
    if (_disposed || _failedDefinitively) return;

    _stallTimer?.cancel();
    _stallTimer = buffering ? Timer(_stallTimeout, _handleFailure) : null;
  }

  void _handleFailure() {
    if (_disposed || _failedDefinitively || _retryScheduled) return;

    _stallTimer?.cancel();
    _stallTimer = null;

    if (_retryCount < _maxRetriesPerUrl) {
      // Indexa o delay com o valor ANTES de incrementar (0, 1, 2 -> 2s, 4s,
      // 8s) e só então incrementa para exibir "tentativa 1/2/3" — mantém os
      // 3 backoffDelays alinhados com _maxRetriesPerUrl sem estourar o
      // índice da lista na última tentativa.
      final delay = _backoffDelays[_retryCount];
      _retryCount++;
      _retryScheduled = true;
      _phase = HealthMonitorPhase.retrying;
      onStatusChange('Reconectando... (tentativa $_retryCount)');

      _retryTimer = Timer(delay, () {
        _retryScheduled = false;
        if (_disposed || _failedDefinitively) return;
        unawaited(player.open(Media(fallbackUrls[_currentUrlIndex])));
      });
      return;
    }

    if (_currentUrlIndex < fallbackUrls.length - 1) {
      _currentUrlIndex++;
      _retryCount = 0;
      _phase = HealthMonitorPhase.retrying;
      onStatusChange('Tentando qualidade alternativa...');
      onUrlSwitch(fallbackUrls[_currentUrlIndex]);
      return;
    }

    _failedDefinitively = true;
    _phase = HealthMonitorPhase.failed;
    onStatusChange('Falha definitiva');
  }

  /// Zera o ciclo de retry/fallback — chamado quando o usuário troca de
  /// canal manualmente, para a próxima falha (de outro conteúdo) começar do
  /// zero em vez de herdar o estado do canal anterior.
  void reset() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _currentUrlIndex = 0;
    _retryCount = 0;
    _retryScheduled = false;
    _failedDefinitively = false;
    _phase = HealthMonitorPhase.idle;
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _stallTimer?.cancel();
    unawaited(_errorSub?.cancel());
    unawaited(_bufferingSub?.cancel());
  }
}
