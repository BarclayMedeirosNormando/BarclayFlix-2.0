import 'dart:async';

import 'package:flutter/foundation.dart';
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

  /// Posição parada além deste tempo (com o player supostamente tocando) é
  /// tratada como falha — mais curto que [_stallTimeout] de propósito: cobre
  /// o caso de falha "silenciosa" de rede (o socket não fecha, então o
  /// media_kit nunca emite nem `stream.error` nem `stream.buffering ==
  /// true`, só para de avançar a posição), então aqui não há NENHUM outro
  /// sinal esperando — quanto antes detectar, melhor.
  static const Duration _progressStallTimeout = Duration(seconds: 10);

  /// `player.stream.position` emite um tick a cada avanço real de posição
  /// (frequência interna do media_kit, tipicamente bem sub-segundo) — bem
  /// mais frequente do que o watchdog precisa para cumprir seu papel (o
  /// prazo de detecção é [_progressStallTimeout], 10s). Processar TODO tick
  /// (cancelar+rearmar [_progressStallTimer], mais os debugPrint de
  /// diagnóstico) é overhead constante durante toda a reprodução saudável,
  /// não só quando algo dá errado. Só o primeiro tick de cada janela de
  /// [_positionCheckThrottle] chega a rearmar o timer/logar — os demais
  /// dentro da mesma janela são ignorados antes de qualquer trabalho (ver
  /// [_positionCheckCooldown]/[_onPositionChanged]). Isso NÃO muda quando um
  /// stall é considerado detectado (ainda [_progressStallTimeout] sem
  /// processar tick nenhum), só adia em até [_positionCheckThrottle] o
  /// instante em que o timer é rearmado a partir de um tick real — folga
  /// desprezível perto dos 10s de prazo.
  static const Duration _positionCheckThrottle = Duration(milliseconds: 1750);

  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<Duration>? _positionSub;
  Timer? _stallTimer;
  Timer? _progressStallTimer;
  Timer? _retryTimer;

  /// Última posição recebida de `player.stream.position` — `null` até o
  /// primeiro tick, para não tratar esse primeiro tick como "posição
  /// parada" por falta de uma posição anterior pra comparar.
  Duration? _lastKnownPosition;

  /// Janela de "cooldown" do throttle de [_onPositionChanged] — não-nulo
  /// enquanto um tick recente já foi processado há menos de
  /// [_positionCheckThrottle]; zerado por si mesmo quando dispara. Um
  /// `Timer` (em vez de comparar `DateTime.now()`) de propósito: precisa
  /// respeitar o relógio virtual do `fake_async` usado pela suíte de testes
  /// deste arquivo (que avança tempo via `Timer`, não via wall-clock real).
  Timer? _positionCheckCooldown;

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

  /// `true` só quando o USUÁRIO pausou explicitamente pela UI (ver
  /// [onUserPause]/[onUserPlay]) — DIFERENTE de `player.state.playing ==
  /// false`, que o media_kit também reporta quando o player fica "faminto"
  /// por dados (ex: rede caiu) sem nenhuma pausa do usuário. Usar
  /// `player.state.playing` como proxy de "pausado" no watchdog de posição
  /// (ver [_onPositionChanged]) SUPRIMIA a detecção justamente no cenário
  /// que ele deveria pegar — confirmado em teste real (log mostrando
  /// `player.state.playing == false` sozinho durante queda de Wi-Fi, sem o
  /// usuário ter tocado em nada).
  bool _userPaused = false;

  /// Chamado pela UI (ex: `PlayerScreen`) sempre que o USUÁRIO pausa
  /// explicitamente a reprodução (botão play/pause) — nunca em resposta a
  /// retry automático. Ver [_userPaused].
  void onUserPause() => _userPaused = true;

  /// Contraparte de [onUserPause] — chamado quando o usuário retoma a
  /// reprodução manualmente.
  void onUserPlay() => _userPaused = false;

  void start() {
    // DIAGNÓSTICO TEMPORÁRIO (ver instrumentação pedida para investigar o
    // caso de Wi-Fi caindo em Windows sem overlay nenhum aparecer) —
    // remover depois que a causa raiz for confirmada e corrigida.
    debugPrint('[HealthMonitor] start() chamado, fallbackUrls: $fallbackUrls');
    _errorSub = player.stream.error.listen((error) {
      debugPrint('[HealthMonitor] error recebido: $error');
      _handleFailure();
    });
    _bufferingSub = player.stream.buffering.listen(_onBufferingChanged);
    _positionSub = player.stream.position.listen(_onPositionChanged);
  }

  /// Terceiro mecanismo de detecção, independente de buffering/erro — cobre
  /// a falha "silenciosa" de rede que nenhum dos outros dois percebe (ver
  /// [_progressStallTimeout]).
  ///
  /// IMPORTANTE: `player.stream.position` é `.distinct()` por construção do
  /// próprio media_kit (`positionController.stream.distinct(...)` em
  /// `PlatformPlayer`, confirmado lendo o pacote) — dois valores
  /// consecutivos IGUAIS nunca chegam como dois ticks separados aqui, o
  /// segundo é descartado antes de sair do stream. Ou seja, TODO tick que
  /// este método recebe já É, por definição, progresso real (avanço normal
  /// ou salto de seek pra qualquer direção); comparar com o valor anterior
  /// pra "detectar avanço" seria sempre verdadeiro e não serviria pra nada.
  ///
  /// Por isso a estratégia é: cada tick observado CANCELA e REARMA
  /// [_progressStallTimer], adiando o prazo — nunca é o tick em si que
  /// indica falha. O timer só chega ao fim (e só aí conta como stall) se
  /// NENHUM tick novo chegar dentro de [_progressStallTimeout], que é a
  /// única forma real de "posição parada" possível dado o `.distinct()`
  /// acima: o stream simplesmente fica em silêncio. Só arma quando o
  /// usuário não pausou explicitamente (ver [_userPaused] — NÃO usa
  /// `player.state.playing` aqui: o media_kit também reporta `playing ==
  /// false` quando o player fica sem dados de rede, o que suprimiria a
  /// detecção justamente no cenário que este watchdog existe pra pegar).
  void _onPositionChanged(Duration position) {
    if (_disposed || _failedDefinitively) return;

    // Throttle (item 3 de performance): descarta ticks demais frequentes
    // antes de qualquer trabalho (log, comparar/atualizar
    // [_lastKnownPosition], cancelar/rearmar timer) — ver
    // [_positionCheckThrottle]. Mantém a mesma ordem de antes (log compara
    // com o [_lastKnownPosition] ANTERIOR antes de sobrescrevê-lo) pelos
    // ticks que passam do throttle.
    if (_positionCheckCooldown != null) return;
    _positionCheckCooldown = Timer(_positionCheckThrottle, () => _positionCheckCooldown = null);

    debugPrint('[HealthMonitor] position tick: $position (última: $_lastKnownPosition)');
    _lastKnownPosition = position;
    _cancelProgressStallTimer('novo tick de posição');

    if (_userPaused) {
      debugPrint('[HealthMonitor] _onPositionChanged: _userPaused=true, timer NÃO armado');
      return;
    }

    debugPrint('[HealthMonitor] _progressStallTimer ARMADO (${_progressStallTimeout.inSeconds}s) a partir do tick $position');
    _progressStallTimer = Timer(_progressStallTimeout, () {
      // DIAGNÓSTICO TEMPORÁRIO (investigação de "silêncio total" no
      // watchdog de posição durante queda de Wi-Fi) — try/catch pra
      // garantir que uma exceção aqui dentro apareça no console em vez de
      // ser engolida silenciosamente (Timer não propaga exceções pra
      // lugar nenhum por padrão). Remover junto com os demais debugPrint
      // depois que a causa raiz for confirmada e corrigida.
      try {
        debugPrint('[HealthMonitor] progress stall timer DISPAROU - chamando _handleFailure()');
        // Confere de novo no momento do disparo (não só na hora de armar):
        // o usuário pode ter pausado DEPOIS deste tick, sem gerar um novo
        // tick que cancelasse este timer (pausa real costuma simplesmente
        // parar de emitir posição, não emitir um último tick).
        if (_disposed || _failedDefinitively || _userPaused) {
          debugPrint(
            '[HealthMonitor] progress stall timer disparou mas foi IGNORADO pelo guard '
            '(disposed=$_disposed, failedDefinitively=$_failedDefinitively, '
            'userPaused=$_userPaused)',
          );
          return;
        }
        debugPrint(
          '[HealthMonitor] progress stall detectado - nenhum tick de posição em ${_progressStallTimeout.inSeconds}s',
        );
        _handleFailure();
      } catch (e, stack) {
        debugPrint('[HealthMonitor] EXCEÇÃO dentro do callback do progress stall timer: $e\n$stack');
      }
    });
  }

  /// Cancela [_progressStallTimer], se houver um em andamento, logando de
  /// onde partiu a chamada — DIAGNÓSTICO TEMPORÁRIO (investigação de
  /// "silêncio total" no watchdog de posição) para confirmar se algum
  /// lugar inesperado está cancelando este timer. Remover junto com os
  /// demais debugPrint depois que a causa raiz for confirmada e corrigida.
  void _cancelProgressStallTimer(String origin) {
    if (_progressStallTimer == null) return;
    debugPrint('[HealthMonitor] _progressStallTimer CANCELADO (origem: $origin)');
    _progressStallTimer!.cancel();
    _progressStallTimer = null;
  }

  void _onBufferingChanged(bool buffering) {
    debugPrint('[HealthMonitor] buffering mudou para: $buffering');
    if (_disposed || _failedDefinitively) return;

    final hadPendingStallTimer = _stallTimer != null;
    _stallTimer?.cancel();

    if (buffering) {
      debugPrint('[HealthMonitor] stall timer iniciado (15s)');
      _stallTimer = Timer(_stallTimeout, () {
        debugPrint('[HealthMonitor] stall timer disparou - buffering ainda true');
        _handleFailure();
      });
    } else {
      if (hadPendingStallTimer) {
        debugPrint('[HealthMonitor] stall timer cancelado - buffering voltou a false');
      }
      _stallTimer = null;
    }
  }

  void _handleFailure() {
    debugPrint('[HealthMonitor] _handleFailure chamado, retryCount=$_retryCount, urlIndex=$_currentUrlIndex');
    if (_disposed || _failedDefinitively || _retryScheduled) return;

    _stallTimer?.cancel();
    _stallTimer = null;
    _cancelProgressStallTimer('_handleFailure (falha real sendo processada)');

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
        final url = fallbackUrls[_currentUrlIndex];
        // DIAGNÓSTICO TEMPORÁRIO (investigação de travamento da janela ao
        // cair o Wi-Fi durante reprodução) — `whenComplete` só observa o
        // fim da Future (sucesso ou erro), sem alterar o `unawaited`
        // fire-and-forget original nem engolir uma exceção que antes
        // vazaria. Remover junto com os demais debugPrint depois que a
        // causa raiz for confirmada e corrigida.
        debugPrint('[HealthMonitor] ${DateTime.now()} player.open() START (retry) url=$url');
        unawaited(
          player.open(Media(url)).whenComplete(() {
            debugPrint('[HealthMonitor] ${DateTime.now()} player.open() END (retry) url=$url');
          }),
        );
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
    _cancelProgressStallTimer('reset()');
    _positionCheckCooldown?.cancel();
    _positionCheckCooldown = null;
    _lastKnownPosition = null;
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
    _cancelProgressStallTimer('dispose()');
    _positionCheckCooldown?.cancel();
    unawaited(_errorSub?.cancel());
    unawaited(_bufferingSub?.cancel());
    unawaited(_positionSub?.cancel());
  }
}
