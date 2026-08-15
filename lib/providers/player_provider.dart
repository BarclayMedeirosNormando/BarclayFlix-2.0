import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/models/watch_progress.dart';
import '../data/services/storage_service.dart';

enum PlayerLoadStatus { idle, loading, buffering, playing, error }

/// Encapsula um [Player] + [VideoController] do media_kit e expõe o estado
/// de reprodução para a UI via [ChangeNotifier].
///
/// A mesma instância de [Player] é reaproveitada durante toda a vida do
/// provider — trocar de conteúdo (ex: outro canal) chama [playUrl] de novo,
/// que apenas reabre a URL no player existente (`player.open`), em vez de
/// recriar o [Player]/[VideoController].
///
/// Nenhum widget deve tocar em `media_kit` diretamente — sempre por aqui.
class PlayerProvider extends ChangeNotifier {
  final Player player;

  /// `null` só acontece em testes que injetam [player] sem injetar um
  /// [VideoController] — construir um [VideoController] de verdade tenta
  /// carregar a textura de vídeo nativa (DLL do libmpv no Windows) mesmo
  /// quando o [Player] por trás dele é fake, o que não existe em
  /// `flutter_test`. [_VideoSurface] trata esse caso mostrando uma
  /// superfície preta no lugar do [Video] real. Em produção nunca é null.
  final VideoController? videoController;

  /// Cache de demuxer (buffer de rede) do libmpv — bem acima do padrão do
  /// media_kit (32 MB) porque streams de IPTV variam de bitrate pela
  /// internet: um buffer pequeno faz qualquer soneca da rede virar
  /// travamento visível na hora, um buffer maior absorve essa variação
  /// silenciosamente. Mapeia direto para as propriedades `demuxer-max-bytes`
  /// E `demuxer-max-back-bytes` do mpv (confirmado lendo
  /// media_kit-1.2.6/lib/src/player/native/player/real.dart — as duas usam
  /// o MESMO valor de [PlayerConfiguration.bufferSize]).
  ///
  /// NÃO elimina travamento causado por internet lenta do lado do usuário
  /// ou do servidor IPTV — isso está fora do controle do app. Só dá mais
  /// margem antes que uma queda de bitrate vire um travamento perceptível.
  static const _demuxerCacheBytes = 64 * 1024 * 1024; // 64 MB
  static const _playerConfiguration = PlayerConfiguration(bufferSize: _demuxerCacheBytes);

  /// `hwdec: 'auto-safe'` mapeia direto pra propriedade `--hwdec` do mpv
  /// (confirmado em media_kit_video-2.0.1/lib/src/video_controller/
  /// platform_video_controller.dart) — decodifica H264/H265(HEVC) por
  /// HARDWARE (GPU) quando disponível e confirmado compatível com o
  /// renderizador atual, com fallback automático pra software só quando
  /// necessário (mais conservador que `auto`, que tenta hwdec mesmo em
  /// combinações decoder/output não confirmadas). É a causa mais comum de
  /// travamento em H265/4K com decodificação puramente por CPU.
  /// `enableHardwareAcceleration: true` já é o padrão do pacote — mantido
  /// explícito aqui só como documentação da intenção, não uma mudança de
  /// comportamento.
  static const _videoControllerConfiguration = VideoControllerConfiguration(
    hwdec: 'auto-safe',
    enableHardwareAcceleration: true,
  );

  /// Meta de pré-carregamento por TEMPO (segundos), complementando o
  /// [_demuxerCacheBytes] acima (que é só um teto de MEMÓRIA) — mapeia pra
  /// `demuxer-readahead-secs` do mpv. Sem isso, o player só busca ficar
  /// dentro do limite de bytes, sem garantir uma folga mínima de segundos
  /// já baixados à frente da reprodução; com isso, tenta ativamente manter
  /// essa folga, o que suaviza especificamente picos curtos de latência
  /// (não confundir com queda de bitrate sustentada, que nenhum buffer
  /// resolve). 15s é conservador o bastante pra não atrasar visivelmente o
  /// início da reprodução.
  static const _demuxerReadaheadSecs = '15';

  /// Quanto tempo o mpv espera por atividade de rede antes de desistir da
  /// conexão atual (`network-timeout`, em segundos) — painéis Xtream variam
  /// bastante em latência/lentidão momentânea; um valor baixo demais
  /// derruba a conexão à toa nesses picos, achando que caiu quando só
  /// demorou. Mantido na MESMA ordem de grandeza dos timeouts do
  /// [PlaybackHealthMonitor] (retry/stall, ver aquele arquivo) de propósito
  /// — as duas camadas não podem divergir muito, senão uma delas vira
  /// trabalho redundante ou a causa de uma espera desnecessariamente longa.
  static const _networkTimeoutSecs = '15';

  /// [TESTE] Timeout de segurança em volta de `player.open()`. Relatado em
  /// TV TCL: o clique em "Assistir" não abre o filme — hipótese é que a
  /// negociação de decodificação por HARDWARE trava dentro do próprio
  /// libmpv em certos chips de TV (comum em SoCs Amlogic/MediaTek com
  /// conteúdo H265/HEVC), sem lançar exceção nem emitir nenhum evento em
  /// `Player.stream` — a UI fica presa no spinner pra sempre, sem o
  /// [PlaybackHealthMonitor] nunca ter um evento pra reagir. Maior que
  /// [_networkTimeoutSecs] de propósito: se o problema for só rede lenta, o
  /// timeout de rede do próprio mpv deve disparar primeiro e chegar como
  /// erro normal via `stream.error`, sem passar por aqui.
  static const _openTimeout = Duration(seconds: 20);

  /// [player]/[videoController] existem para injeção em testes — construir
  /// um [Player]/[VideoController] de verdade carrega a lib nativa do
  /// libmpv via FFI, o que não roda em `flutter_test` (sem engine/binários
  /// nativos). Em produção nunca são passados, então a configuração de
  /// hwdec/buffer acima SEMPRE se aplica a qualquer player real — nunca ao
  /// [FakePlatformPlayer] usado pelos testes.
  factory PlayerProvider({Player? player, VideoController? videoController}) {
    final effectivePlayer = player ?? Player(configuration: _playerConfiguration);
    if (player == null) {
      // Sem await de propósito (factory não é async) -- `setProperty` já
      // espera a inicialização nativa internamente (ver
      // media_kit-1.2.6/lib/src/player/native/player/real.dart), então não
      // há necessidade de bloquear a criação do provider por isso.
      unawaited(_applyNetworkTuning(effectivePlayer));
    }
    final effectiveController = videoController ??
        (player == null
            ? VideoController(effectivePlayer, configuration: _videoControllerConfiguration)
            : null);
    return PlayerProvider._(effectivePlayer, effectiveController);
  }

  /// `cache`/`demuxer-readahead-secs`/`network-timeout` não têm equivalente
  /// em [PlayerConfiguration] (só expõe bufferSize/logLevel/etc) — só dá
  /// pra setar via [NativePlayer.setProperty], que fala direto com o
  /// libmpv. Silenciosamente vira no-op em builds web (sem [NativePlayer]),
  /// irrelevante aqui já que este app não roda em navegador.
  static Future<void> _applyNetworkTuning(Player player) async {
    final native = player.platform;
    if (native is! NativePlayer) return;
    await native.setProperty('cache', 'yes');
    await native.setProperty('demuxer-readahead-secs', _demuxerReadaheadSecs);
    await native.setProperty('network-timeout', _networkTimeoutSecs);
  }

  PlayerProvider._(this.player, this.videoController) {
    _errorSubscription = player.stream.error.listen(_onPlayerError);
    _bufferingSubscription = player.stream.buffering.listen(_onBufferingChanged);
    _playingSubscription = player.stream.playing.listen(_onPlayingChanged);
    _positionSubscription = player.stream.position.listen(_onPositionChanged);
    _durationSubscription = player.stream.duration.listen(_onDurationChanged);
  }

  late final StreamSubscription<String> _errorSubscription;
  late final StreamSubscription<bool> _bufferingSubscription;
  late final StreamSubscription<bool> _playingSubscription;
  late final StreamSubscription<Duration> _positionSubscription;
  late final StreamSubscription<Duration> _durationSubscription;

  bool _disposed = false;

  /// [TESTE] Uma tentativa por [PlayerProvider] (cada reprodução tem sua
  /// própria instância, ver PlayerScreen) — evita loop infinito se até o
  /// software decoding travar por outro motivo.
  bool _hwdecFallbackApplied = false;

  final StorageService _storageService = StorageService();

  PlayerLoadStatus _status = PlayerLoadStatus.idle;
  String? _errorMessage;
  String? _title;
  String? _currentUrl;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // Metadados de "Continuar Assistindo" do conteúdo atual — `null` sempre
  // que a mídia aberta não deve ter progresso rastreado (Live TV: HomeScreen
  // nunca passa `contentId` pra ela, ver _playLiveChannel).
  String? _contentId;
  String? _imageUrl;
  WatchProgressType? _progressType;
  DateTime? _lastProgressSaveAt;

  static const _progressSaveInterval = Duration(seconds: 10);

  /// Acima desta fração da duração total, o conteúdo é considerado
  /// "concluído" — salvar progresso a 95%+ só ofereceria "continuar" a
  /// poucos segundos do fim, o que não serve pra nada.
  static const _completedFraction = 0.95;

  PlayerLoadStatus get status => _status;
  String? get errorMessage => _errorMessage;
  String? get title => _title;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get isPlaying => player.state.playing;

  /// Streams contínuos (Live TV) não reportam duração — usado pela UI para
  /// decidir se mostra a barra de progresso ou um indicativo de "ao vivo".
  bool get isLive => _duration <= Duration.zero;

  /// Abre [url] no player já existente e atualiza o título exibido.
  /// Nunca deixa uma exceção do media_kit vazar — falhas de conexão, URL
  /// inválida etc. viram [status] = [PlayerLoadStatus.error] com
  /// [errorMessage] amigável.
  ///
  /// [contentId]/[imageUrl]/[progressType] identificam o conteúdo pra fins
  /// de "Continuar Assistindo" — omitidos (ou `contentId` nulo), o
  /// progresso simplesmente não é rastreado pra esta reprodução (é o caso
  /// de Live TV, que nunca tem posição/duração reais).
  /// [startAtSeconds] retoma a partir de uma posição salva (vindo da seção
  /// "Continuar Assistindo"); em qualquer outro fluxo de reprodução
  /// (tocar um VOD/canal/episódio do zero) fica no padrão 0.
  Future<void> playUrl(
    String url, {
    required String title,
    String? contentId,
    String? imageUrl,
    WatchProgressType? progressType,
    double startAtSeconds = 0,
  }) async {
    _contentId = contentId;
    _imageUrl = imageUrl;
    _progressType = progressType;
    _lastProgressSaveAt = null;
    _currentUrl = url;
    _title = title;
    _status = PlayerLoadStatus.loading;
    _errorMessage = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _safeNotify();

    try {
      await _openWithHwdecFallback(url);
    } catch (_) {
      // Se o usuário já saiu da tela (provider disposto) ou já pediu outra
      // mídia enquanto esta abria, ignora o resultado tardio.
      if (_disposed || _currentUrl != url) return;
      _status = PlayerLoadStatus.error;
      _errorMessage = 'Não foi possível reproduzir este conteúdo. Verifique '
          'sua conexão ou tente novamente.';
      _safeNotify();
      return;
    }

    if (_disposed || _currentUrl != url) return;

    if (startAtSeconds > 0) {
      try {
        await player.seek(Duration(seconds: startAtSeconds.round()));
      } catch (_) {
        // Retomar de uma posição salva é um bônus — se o seek falhar, o
        // conteúdo ainda toca normalmente do início em vez de virar erro.
      }
    }

    // `open()` resolvido não significa que já há quadros na tela — os
    // streams de buffering/playing assumem o estado visual a partir daqui.
    _status = PlayerLoadStatus.buffering;
    _safeNotify();
  }

  /// [TESTE] Abre [url] com [_openTimeout] de segurança. Se estourar (ver
  /// motivo em [_openTimeout]) e ainda não tiver sido tentado nesta
  /// instância, desliga a decodificação por hardware (`hwdec=no`, força
  /// software puro) e tenta abrir de novo, uma única vez, antes de deixar a
  /// exceção subir pro catch em [playUrl]. Qualquer exceção que não seja
  /// timeout (URL inválida, servidor recusou, etc.) sobe direto, sem passar
  /// por aqui — só timeout indica travamento no `open()` em si.
  Future<void> _openWithHwdecFallback(String url) async {
    try {
      await player.open(Media(url)).timeout(_openTimeout);
    } on TimeoutException {
      final native = player.platform;
      if (_hwdecFallbackApplied || native is! NativePlayer) rethrow;
      _hwdecFallbackApplied = true;
      await native.setProperty('hwdec', 'no');
      await player.open(Media(url)).timeout(_openTimeout);
    }
  }

  /// Reabre a última URL tocada (usado pelo botão "Tentar novamente") —
  /// preserva os metadados de progresso já associados a esta reprodução
  /// (ver [playUrl]), sem retomar de uma posição salva (a tentativa
  /// anterior provavelmente nem chegou a reproduzir nada).
  Future<void> retry() async {
    final url = _currentUrl;
    final title = _title;
    if (url == null || title == null) return;
    await playUrl(
      url,
      title: title,
      contentId: _contentId,
      imageUrl: _imageUrl,
      progressType: _progressType,
    );
  }

  Future<void> togglePlayPause() => player.playOrPause();

  /// Usados pelas teclas de mídia física (play/pause dedicados), que devem
  /// forçar o estado em vez de alternar — ver [PlayerScreen].
  Future<void> play() => player.play();

  Future<void> pause() => player.pause();

  Future<void> seek(Duration position) => player.seek(position);

  /// Avança/retrocede a partir da posição atual em [offset] (negativo
  /// retrocede), sem passar de zero nem da duração total — usado pelos
  /// botões de -10s/+10s da PlayerScreen, já que o `Player.seek` do
  /// media_kit é absoluto (recebe a posição alvo, não um delta).
  ///
  /// Não faz nada (sem lançar exceção) fora do estado estável de reprodução
  /// [PlayerLoadStatus.playing] — cobre Live TV/duração ainda desconhecida
  /// ([isLive]), carregamento, buffering e erro, nenhum dos quais tem uma
  /// posição válida pra buscar.
  Future<void> seekRelative(Duration offset) async {
    if (isLive) return;
    if (_status != PlayerLoadStatus.playing) return;

    final target = _position + offset;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _duration ? _duration : target);

    await seek(clamped);
  }

  Future<void> stop() async {
    _currentUrl = null;
    _status = PlayerLoadStatus.idle;
    _errorMessage = null;
    _safeNotify();
    await player.stop();
  }

  void _onPlayerError(String message) {
    _status = PlayerLoadStatus.error;
    _errorMessage = 'Não foi possível reproduzir este conteúdo. Verifique '
        'sua conexão ou tente novamente.';
    _safeNotify();
  }

  void _onBufferingChanged(bool buffering) {
    if (_status == PlayerLoadStatus.error) return;
    _status = buffering ? PlayerLoadStatus.buffering : PlayerLoadStatus.playing;
    _safeNotify();
  }

  void _onPlayingChanged(bool playing) {
    if (_status == PlayerLoadStatus.error) return;
    if (playing && !player.state.buffering) {
      _status = PlayerLoadStatus.playing;
    }
    // Captura a posição exata no instante em que o usuário pausa (ou o
    // player pausa sozinho, ex: perdeu foco) — não espera o próximo tick
    // throttled de _onPositionChanged, que pode ficar até 10s desatualizado.
    if (!playing) _forceSaveProgress();
    _safeNotify();
  }

  void _onPositionChanged(Duration position) {
    _position = position;
    _maybeSaveProgress();
    _safeNotify();
  }

  void _onDurationChanged(Duration duration) {
    _duration = duration;
    _safeNotify();
  }

  /// Salva o progresso no máximo uma vez a cada [_progressSaveInterval] —
  /// chamado a cada tick de posição (várias vezes por segundo), então sem
  /// o throttle seria uma escrita em disco por frame.
  void _maybeSaveProgress() {
    if (_contentId == null) return;

    final now = DateTime.now();
    if (_lastProgressSaveAt != null && now.difference(_lastProgressSaveAt!) < _progressSaveInterval) {
      return;
    }

    _lastProgressSaveAt = now;
    unawaited(_persistProgress());
  }

  /// Ignora o throttle — usado nos momentos em que perder a posição exata
  /// importa mais que economizar uma escrita (pausar, sair da tela).
  void _forceSaveProgress() {
    if (_contentId == null) return;
    _lastProgressSaveAt = DateTime.now();
    unawaited(_persistProgress());
  }

  /// Nunca chamado diretamente — sempre via [_maybeSaveProgress] ou
  /// [_forceSaveProgress], que decidem throttle/timestamp num único lugar.
  Future<void> _persistProgress() async {
    final contentId = _contentId;
    final type = _progressType;
    final url = _currentUrl;
    final title = _title;
    if (contentId == null || type == null || url == null || title == null) return;

    // Duração desconhecida cobre tanto Live TV (nunca tem duração real,
    // ver [isLive]) quanto o instante inicial de um VOD/episódio antes do
    // media_kit reportar a duração — em nenhum dos dois casos há uma
    // fração válida pra salvar.
    if (_duration <= Duration.zero) return;

    final fraction = _position.inMilliseconds / _duration.inMilliseconds;
    if (fraction >= _completedFraction) {
      await _storageService.removeProgress(contentId);
      return;
    }

    await _storageService.saveProgress(WatchProgress(
      contentId: contentId,
      title: title,
      imageUrl: _imageUrl ?? '',
      positionSeconds: _position.inSeconds,
      durationSeconds: _duration.inSeconds,
      type: type,
      playbackUrl: url,
      lastWatchedAt: DateTime.now(),
    ));
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _forceSaveProgress();
    _errorSubscription.cancel();
    _bufferingSubscription.cancel();
    _playingSubscription.cancel();
    _positionSubscription.cancel();
    _durationSubscription.cancel();
    // ChangeNotifier.dispose() é síncrono; a liberação nativa do player
    // (libmpv) continua em segundo plano sem bloquear a navegação.
    unawaited(player.dispose());
    super.dispose();
  }
}
