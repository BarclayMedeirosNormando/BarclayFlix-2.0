import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/watch_progress.dart';
import '../../providers/player_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/playback_health_monitor.dart';
import '../../widgets/dpad_focus_highlight.dart';

/// Tela de reprodução: recebe apenas [url] + [title] (+ metadados
/// opcionais de "Continuar Assistindo", ver abaixo). Não sabe de onde a URL
/// veio (Xtream, ou qualquer outra fonte) — baixo acoplamento total com o
/// resto do app.
///
/// Os controles são 100% customizados (ver [_ControlsOverlay]) em vez dos
/// controles padrão do media_kit_video: os controles padrão (`AdaptiveVideoControls`)
/// são pensados para toque/mouse e não têm foco/travessia adequados para
/// D-Pad de Android TV. Construir os nossos desde já — mesmo sem a lógica
/// completa de D-Pad, que é do próximo módulo — evita reescrever a tela
/// inteira depois.
class PlayerScreen extends StatelessWidget {
  final String url;
  final String title;

  /// Identifica o conteúdo pra fins de "Continuar Assistindo" — `null`
  /// (padrão) significa que esta reprodução não deve ter progresso
  /// rastreado (é o caso de Live TV, ver HomeScreen._playLiveChannel).
  final String? contentId;
  final String? imageUrl;
  final WatchProgressType? progressType;

  /// Retoma a reprodução a partir desta posição (vindo de um progresso
  /// salvo) — 0 (padrão) em qualquer outro fluxo, sempre começa do início.
  final double startAtSeconds;

  /// Cadeia de URLs alternativas para o [PlaybackHealthMonitor] percorrer em
  /// caso de falha de reprodução (tipicamente vinda de
  /// `StreamUrlBuilder.buildFallbackChain`) — padrão `[url]` (só a própria
  /// URL, sem troca de qualidade/rota) para compatibilidade com quem ainda
  /// não monta uma cadeia (VOD/série, ver HomeScreen._playMovie).
  final List<String> fallbackUrls;

  /// Só usado em testes, para injetar um [PlayerProvider] com um [Player]
  /// fake (evita instanciar o media_kit de verdade, que não roda em
  /// `flutter_test`). Em produção fica sempre `null`.
  final PlayerProvider? playerProvider;

  PlayerScreen({
    super.key,
    required this.url,
    required this.title,
    this.contentId,
    this.imageUrl,
    this.progressType,
    this.startAtSeconds = 0,
    this.playerProvider,
    List<String>? fallbackUrls,
  }) : fallbackUrls = fallbackUrls ?? [url];

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      // [TESTE] `forceSoftwareDecode` vem do toggle manual "Modo
      // compatibilidade de vídeo" (Configurações) -- ver
      // PlayerProvider._videoControllerConfigurationSoftware pro porquê.
      // Lido aqui (não dentro do PlayerProvider) porque o SettingsProvider
      // já é um Provider de app inteiro (ver main.dart) e o valor já está
      // carregado nesse ponto da navegação -- criar/injetar outro
      // StorageService dentro do PlayerProvider só pra isso duplicaria a
      // fonte da verdade.
      create: (context) =>
          playerProvider ??
          PlayerProvider(
            forceSoftwareDecode: context.read<SettingsProvider>().videoCompatibilityMode,
          ),
      child: _PlayerScreenBody(
        url: url,
        title: title,
        contentId: contentId,
        imageUrl: imageUrl,
        progressType: progressType,
        startAtSeconds: startAtSeconds,
        fallbackUrls: fallbackUrls,
      ),
    );
  }
}

bool get _isDesktopFullscreenCapable => !kIsWeb && Platform.isWindows;

class _PlayerScreenBody extends StatefulWidget {
  final String url;
  final String title;
  final String? contentId;
  final String? imageUrl;
  final WatchProgressType? progressType;
  final double startAtSeconds;
  final List<String> fallbackUrls;

  const _PlayerScreenBody({
    required this.url,
    required this.title,
    this.contentId,
    this.imageUrl,
    this.progressType,
    this.startAtSeconds = 0,
    required this.fallbackUrls,
  });

  @override
  State<_PlayerScreenBody> createState() => _PlayerScreenBodyState();
}

class _PlayerScreenBodyState extends State<_PlayerScreenBody> {
  static const _hideControlsDelay = Duration(seconds: 4);

  // Teclas de seta/ativação que, quando os controles estão escondidos,
  // devem apenas reexibi-los — sem mover o foco ou ativar o controle que
  // ficaria embaixo, no mesmo toque.
  // LogicalKeyboardKey sobrescreve == com igualdade não-primitiva, então
  // esse Set não pode ser `const` (o analyzer rejeita: const_set_element_not_primitive_equality).
  static final _revealKeys = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.gameButtonA,
  };

  Timer? _hideControlsTimer;
  bool _controlsVisible = true;
  bool _isFullscreen = false;

  final FocusNode _backFocusNode = FocusNode(debugLabel: 'player-back');
  final FocusNode _playPauseFocusNode = FocusNode(debugLabel: 'player-play-pause');
  final FocusNode _fullscreenFocusNode = FocusNode(debugLabel: 'player-fullscreen');
  final FocusNode _seekBackwardFocusNode = FocusNode(debugLabel: 'player-seek-backward');
  final FocusNode _seekForwardFocusNode = FocusNode(debugLabel: 'player-seek-forward');
  final FocusNode _retryFocusNode = FocusNode(debugLabel: 'player-retry');
  final FocusNode _inputFocusNode = FocusNode(debugLabel: 'player-input-surface');

  // [TESTE] Ver _handleProgressBarKeyEvent pro porquê deste FocusNode/estado
  // existirem: o Slider de progresso continua fora da travessia por D-Pad
  // (ExcludeFocus, ver _BottomBar), mas este outro nó — por FORA do Slider —
  // agora dá à barra uma parada normal na navegação, com um "modo de busca"
  // que OK liga/desliga.
  final FocusNode _progressBarFocusNode = FocusNode(debugLabel: 'player-progress-bar');
  bool _seekModeActive = false;

  // Texto momentâneo ("-10s"/"+10s") mostrado ao acionar o seek — só
  // feedback visual, sem estado de reprodução real por trás.
  String? _seekFeedbackText;
  Timer? _seekFeedbackTimer;

  // Observa o Player por baixo e tenta se recuperar sozinho de falhas
  // (retry com backoff, depois troca de URL na cadeia de fallbackUrls) —
  // ver PlaybackHealthMonitor. Sempre instanciado (mesmo com a cadeia
  // padrão de 1 entrada, ver PlayerScreen.fallbackUrls) para que VOD/série
  // já se beneficiem do retry automático, mesmo sem troca de URL.
  PlaybackHealthMonitor? _healthMonitor;

  // Texto de status do _healthMonitor ("Reconectando...", "Tentando
  // qualidade alternativa...", "Falha definitiva") exibido num overlay
  // discreto — `null` quando não há nada de anormal acontecendo.
  String? _healthStatus;

  // Espelha _healthMonitor.phase (atualizado sempre junto de _healthStatus,
  // ver onStatusChange abaixo) — usado (em vez do texto livre de
  // _healthStatus) para decidir se o _ErrorOverlay deve ficar suprimido
  // enquanto o monitor ainda está tentando se recuperar sozinho (ver
  // _ErrorOverlay.suppressed abaixo).
  HealthMonitorPhase _healthPhase = HealthMonitorPhase.idle;

  // Guardado à parte (em vez de `context.read<PlayerProvider>()` de novo em
  // `dispose()`) de propósito: por volta do desmonte da árvore, o Element
  // desta tela pode já estar desativado quando `dispose()` roda, e uma nova
  // busca de ancestral nesse momento é insegura ("Looking up a deactivated
  // widget's ancestor is unsafe" — achado rodando a suíte de testes).
  // Guardar a referência enquanto o contexto ainda está garantidamente
  // ativo (`initState`) evita essa busca tardia. Mesmo padrão já usado em
  // `_contentProvider` na HomeScreen.
  late final PlayerProvider _playerProvider = context.read<PlayerProvider>();

  @override
  void initState() {
    super.initState();

    if (!_isDesktopFullscreenCapable) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    _playerProvider.addListener(_onPlayerProviderChanged);
    _progressBarFocusNode.addListener(_onProgressBarFocusChanged);
    _healthMonitor = PlaybackHealthMonitor(
      player: _playerProvider.player,
      fallbackUrls: widget.fallbackUrls,
      onStatusChange: (status) {
        if (!mounted) return;
        setState(() {
          _healthStatus = status;
          _healthPhase = _healthMonitor!.phase;
        });
      },
      onUrlSwitch: (newUrl) {
        if (!mounted) return;
        _playerProvider.playUrl(
              newUrl,
              title: widget.title,
              contentId: widget.contentId,
              imageUrl: widget.imageUrl,
              progressType: widget.progressType,
            );
      },
    )..start();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<PlayerProvider>().playUrl(
            widget.url,
            title: widget.title,
            contentId: widget.contentId,
            imageUrl: widget.imageUrl,
            progressType: widget.progressType,
            startAtSeconds: widget.startAtSeconds,
          );

      // Os controles (Voltar, play/pause...) já existem desde o primeiro
      // frame (não dependem da rede) — salta o foco, uma única vez, do
      // wrapper invisível (`_inputFocusNode`, autofocus acima) pro
      // primeiro controle de verdade. Sem isso, a primeira seta do D-Pad
      // não move o foco pra lugar nenhum: esse wrapper fica FORA do
      // `FocusTraversalGroup` dos controles, e busca DIRECIONAL (seta)
      // não "entra" nele sozinha — só travessia por ORDEM (`nextFocus`,
      // equivalente ao Tab) consegue atravessar essa fronteira (achado
      // empírico rodando o teste que cobre esse cenário: ver "seta move o
      // foco pros controles, mesmo sem nenhum foco manual antes").
      _inputFocusNode.nextFocus();
    });

    _scheduleHideControls();
  }

  /// Some o overlay de status assim que a reprodução volta a fluir de
  /// verdade — o [PlaybackHealthMonitor] nunca emite um status de
  /// "recuperado" (só os de falha/retry, ver [_healthMonitor]), então é
  /// esta tela quem decide esconder o próprio aviso ao ver o
  /// [PlayerProvider] chegar em [PlayerLoadStatus.playing].
  void _onPlayerProviderChanged() {
    if (!mounted || _healthStatus == null) return;
    if (_playerProvider.status == PlayerLoadStatus.playing) {
      // Só limpa o espelho local de UI (_healthPhase) — não chama
      // _healthMonitor.reset() aqui: os contadores internos de retry/URL
      // atual devem continuar de onde pararam se uma falha nova acontecer
      // logo em seguida, só o AVISO na tela é que não faz mais sentido
      // depois que a reprodução volta a fluir.
      setState(() {
        _healthStatus = null;
        _healthPhase = HealthMonitorPhase.idle;
      });
    }
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _playerProvider.removeListener(_onPlayerProviderChanged);
    _progressBarFocusNode.removeListener(_onProgressBarFocusChanged);
    _healthMonitor?.dispose();
    _backFocusNode.dispose();
    _playPauseFocusNode.dispose();
    _fullscreenFocusNode.dispose();
    _seekBackwardFocusNode.dispose();
    _seekForwardFocusNode.dispose();
    _retryFocusNode.dispose();
    _inputFocusNode.dispose();
    _progressBarFocusNode.dispose();

    if (!_isDesktopFullscreenCapable) {
      // Libera a orientação de volta ao padrão do sistema ao sair do player.
      SystemChrome.setPreferredOrientations([]);
    }
    if (_isDesktopFullscreenCapable && _isFullscreen) {
      windowManager.setFullScreen(false);
    }

    super.dispose();
  }

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(_hideControlsDelay, () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
      // Ao esconder, o `ExcludeFocus` acima tira o controle que estava
      // focado (ex: o próprio botão de Voltar, ver o salto inicial de foco
      // em `initState`) da árvore de foco — sem pedir explicitamente o
      // foco de volta pro `_inputFocusNode` aqui, a evicção padrão do
      // Flutter sobe pro FocusScope da ROTA (não pra este nó, que é um
      // `Focus` comum, não um `FocusScope`), e a partir daí nenhuma seta
      // alcança mais `_handleSurfaceKeyEvent` pra reexibir os controles
      // (achado empírico rodando o teste "primeira seta/Enter só revela os
      // controles...").
      _inputFocusNode.requestFocus();
    });
  }

  void _showControls() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleHideControls();
  }

  /// Intercepta seta/OK enquanto os controles estão escondidos: a primeira
  /// tecla só os reexibe (consome o evento, não deixa navegar/ativar nada
  /// "invisível" no mesmo toque). Com os controles já visíveis, apenas
  /// reinicia o timer de auto-hide e deixa o evento seguir normalmente para
  /// a navegação/ativação padrão do Flutter (DirectionalFocusIntent /
  /// ActivateIntent).
  KeyEventResult _handleSurfaceKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!_revealKeys.contains(event.logicalKey)) return KeyEventResult.ignored;

    if (!_controlsVisible) {
      _showControls();
      return KeyEventResult.handled;
    }

    _scheduleHideControls();
    return KeyEventResult.ignored;
  }

  /// [TESTE] Sai do "modo de busca" (ver [_handleProgressBarKeyEvent]) toda
  /// vez que o foco sai da barra de progresso por qualquer motivo (seta pra
  /// cima/baixo, controles escondidos, troca de tela...) — sem isso, voltar
  /// pra barra depois herdaria o modo ainda ligado, sem nenhuma pista visual
  /// de como ele foi ativado.
  void _onProgressBarFocusChanged() {
    if (!_progressBarFocusNode.hasFocus && _seekModeActive) {
      setState(() => _seekModeActive = false);
    }
  }

  // [TESTE] `static final`, não `const` — mesmo motivo já documentado em
  // `_revealKeys` acima: LogicalKeyboardKey sobrescreve `==` com igualdade
  // não-primitiva, e o analyzer/compilador rejeita um Set const nesse caso
  // ("does not have a primitive equality"). Erro pego rodando `flutter test`
  // de verdade (quebrava a COMPILAÇÃO do arquivo inteiro, derrubando todo
  // o resto da suíte de testes do app).
  static final _seekModeToggleKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  /// [TESTE] Segundo ponto de entrada de teclado da tela (o primeiro é
  /// [_handleSurfaceKeyEvent]) — resolve o bug relatado de a barra de
  /// progresso ser 100% inacessível por D-Pad (só os botões -10s/+10s
  /// serviam pra buscar posição pelo controle remoto).
  ///
  /// O Slider em si continua fora da travessia (ver `ExcludeFocus` em
  /// `_BottomBar` e o teste "nunca recebe foco via navegação por seta" em
  /// player_screen_dpad_test.dart) — motivo de sempre: focado, ele captura
  /// as 4 setas pra ajustar o próprio valor, e Android TV não tem Tab pra
  /// escapar dali. Este handler fica num FocusNode DIFERENTE, por FORA do
  /// Slider excluído (ver [_progressBarFocusNode]), que funciona como mais
  /// uma parada normal da travessia.
  ///
  /// OK/Select LIGA e DESLIGA o "modo de busca" (mesma tecla nos dois
  /// sentidos): só com o modo ligado, esquerda/direita passam a chamar
  /// [_seekRelative] (mesmo -10s/+10s dos botões dedicados, com o mesmo
  /// feedback visual) em vez de mover o foco pra outro controle. Qualquer
  /// outra tecla (inclusive cima/baixo) não é interceptada — o que já tira
  /// do modo de busca assim que o foco realmente sai daqui (ver
  /// [_onProgressBarFocusChanged]).
  ///
  /// Por que OK (e não Voltar) desliga o modo: o botão físico "Voltar" do
  /// Android TV nunca chega aqui como [KeyEvent] (ver o comentário no
  /// `PopScope` do `build()` abaixo) — ele sempre vira um pop de rota de
  /// verdade, então não haveria como "capturar Voltar" neste handler; o
  /// `PopScope` trata esse caso separadamente (sai do modo de busca em vez
  /// de fechar o player). Escape (teclado, Windows) É um KeyEvent de
  /// verdade e chega aqui normalmente, por isso continua valendo como saída
  /// adicional.
  KeyEventResult _handleProgressBarKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (_seekModeToggleKeys.contains(key)) {
      setState(() => _seekModeActive = !_seekModeActive);
      return KeyEventResult.handled;
    }

    if (!_seekModeActive) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.escape) {
      setState(() => _seekModeActive = false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekRelative(const Duration(seconds: -10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekRelative(const Duration(seconds: 10));
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<void> _toggleFullscreen() async {
    if (!_isDesktopFullscreenCapable) return;
    await windowManager.ensureInitialized();
    final next = !_isFullscreen;
    await windowManager.setFullScreen(next);
    if (!mounted) return;
    setState(() => _isFullscreen = next);
    _showControls();
  }

  Future<void> _exitPlayer() async {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// Botão "Tentar novamente" do [_ErrorOverlay] — zera o ciclo de
  /// retry/fallback do [_healthMonitor] (senão a próxima falha herdaria o
  /// índice de URL/contagem de tentativas já gastos deste ciclo) antes de
  /// pedir ao [PlayerProvider] para reabrir a última URL.
  Future<void> _retry() async {
    _healthMonitor?.reset();
    if (_healthStatus != null || _healthPhase != HealthMonitorPhase.idle) {
      setState(() {
        _healthStatus = null;
        _healthPhase = HealthMonitorPhase.idle;
      });
    }
    await _playerProvider.retry();
  }

  /// Mesmo padrão do [_toggleFullscreen]: reexibe os controles/reinicia o
  /// timer de auto-hide explicitamente em vez de depender do
  /// `GestureDetector` externo também disparar em cima do toque no botão.
  void _seekRelative(Duration offset) {
    context.read<PlayerProvider>().seekRelative(offset);
    _showControls();
    _flashSeekFeedback(offset);
  }

  void _flashSeekFeedback(Duration offset) {
    _seekFeedbackTimer?.cancel();
    final sign = offset.isNegative ? '-' : '+';
    setState(() => _seekFeedbackText = '$sign${offset.abs().inSeconds}s');
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekFeedbackText = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        // Escape = "Voltar" no teclado físico (Windows). O D-Pad "Voltar" do
        // Android TV não passa por aqui — chega como pop de rota de verdade
        // (ver PopScope abaixo); os dois caminhos convergem no mesmo
        // Navigator.maybePop, que respeita a saída de tela cheia primeiro.
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
        // Teclas de mídia física (quando o SO/plataforma as entrega ao
        // Flutter — não é garantido em todo teclado/dispositivo, ver nota em
        // PlayerScreen).
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause):
            () => context.read<PlayerProvider>().togglePlayPause(),
        const SingleActivator(LogicalKeyboardKey.mediaPlay):
            () => context.read<PlayerProvider>().play(),
        const SingleActivator(LogicalKeyboardKey.mediaPause):
            () => context.read<PlayerProvider>().pause(),
      },
      child: PopScope(
        // Enquanto em tela cheia (Windows), o botão/tecla de voltar sai da
        // tela cheia em vez de fechar o player — igual ao comportamento
        // esperado de qualquer player desktop. [TESTE] Mesma ideia agora
        // vale para o "modo de busca" da barra de progresso (ver
        // _handleProgressBarKeyEvent): o botão físico "Voltar" do Android TV
        // NUNCA chega como KeyEvent (só como pop de rota de verdade, aqui),
        // então é só neste PopScope que dá pra evitar fechar o player por
        // engano no meio de uma busca.
        canPop: !_isFullscreen && !_seekModeActive,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (_isFullscreen) {
            _toggleFullscreen();
          } else if (_seekModeActive) {
            setState(() => _seekModeActive = false);
          }
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: MouseRegion(
            onHover: (_) => _showControls(),
            cursor: _controlsVisible ? SystemMouseCursors.basic : SystemMouseCursors.none,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showControls,
              child: Focus(
                focusNode: _inputFocusNode,
                autofocus: true,
                // Sem skipTraversal, este nó (do tamanho da tela inteira)
                // concorre geometricamente com os controles de verdade na
                // busca direcional do D-Pad — e podia "vencer" o botão de
                // play/pause por estar mais próximo em linha reta do que ele
                // (achado rodando o teste: ArrowDown a partir de Voltar
                // caía de volta aqui em vez de ir para o play/pause).
                // Ele só deve servir de ponto de partida inicial (autofocus)
                // e de fallback quando os controles estão escondidos.
                skipTraversal: true,
                onKeyEvent: _handleSurfaceKeyEvent,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const _VideoSurface(),
                    // Ver _FallbackTransitionScrim: suaviza a troca de
                    // stream que o _healthMonitor faz sozinho (retry na
                    // mesma URL ou troca de qualidade na cadeia de
                    // fallback) — sem isso, o corte de texture nativa do
                    // media_kit ao reabrir a URL aparecia como flash/tela
                    // preta abrupta por baixo do spinner de buffering.
                    _FallbackTransitionScrim(active: _healthPhase == HealthMonitorPhase.retrying),
                    const _BufferingIndicator(),
                    _ErrorOverlay(
                      retryFocusNode: _retryFocusNode,
                      onRetry: _retry,
                      // Enquanto o _healthMonitor ainda está tentando se
                      // recuperar sozinho (retry com backoff ou troca de
                      // URL), o _HealthStatusOverlay abaixo já comunica que
                      // algo está sendo feito automaticamente — mostrar o
                      // botão "Tentar novamente" ao mesmo tempo seria
                      // redundante/confuso. Só quando o monitor desiste de
                      // vez (.failed) é que faz sentido pedir uma ação
                      // manual do usuário.
                      suppressed: _healthPhase == HealthMonitorPhase.retrying,
                      // Ver _ErrorOverlay.healthPhase: falha detectada só
                      // pelo _healthMonitor (stall/progress-stall silencioso)
                      // nunca passa por PlayerProvider._status == error, então
                      // o overlay precisa saber da fase do monitor também.
                      healthPhase: _healthPhase,
                    ),
                    _HealthStatusOverlay(status: _healthStatus),
                    _SeekFeedbackOverlay(text: _seekFeedbackText),
                    AnimatedOpacity(
                      opacity: _controlsVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: !_controlsVisible,
                        // Enquanto escondidos, os controles saem totalmente
                        // da árvore de foco — sem isso, o D-Pad conseguiria
                        // "achar" um botão invisível via navegação
                        // direcional, o que é confuso e o item 2 da tarefa
                        // pede explicitamente para evitar.
                        child: ExcludeFocus(
                          excluding: !_controlsVisible,
                          child: _ControlsOverlay(
                            isFullscreenCapable: _isDesktopFullscreenCapable,
                            isFullscreen: _isFullscreen,
                            backFocusNode: _backFocusNode,
                            playPauseFocusNode: _playPauseFocusNode,
                            fullscreenFocusNode: _fullscreenFocusNode,
                            seekBackwardFocusNode: _seekBackwardFocusNode,
                            seekForwardFocusNode: _seekForwardFocusNode,
                            progressBarFocusNode: _progressBarFocusNode,
                            seekModeActive: _seekModeActive,
                            onProgressBarKeyEvent: _handleProgressBarKeyEvent,
                            onBack: _exitPlayer,
                            onToggleFullscreen: _toggleFullscreen,
                            onSeek: _seekRelative,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Superfície de vídeo pura. Usa `controls: null` para desligar os
/// controles padrão do media_kit_video — ver a nota na doc de [PlayerScreen].
class _VideoSurface extends StatelessWidget {
  const _VideoSurface();

  @override
  Widget build(BuildContext context) {
    final controller = context.read<PlayerProvider>().videoController;

    // Só é null em testes (ver PlayerProvider) — nunca em produção.
    if (controller == null) return const ColoredBox(color: Colors.black);

    // RepaintBoundary isola a superfície de vídeo do resto da árvore do
    // player (controles, overlays de status/erro, indicador de buffering)
    // — sem ele, qualquer repaint desses widgets (ex: AnimatedOpacity dos
    // controles, o Selector de posição atualizando a cada tick) força o
    // Flutter a considerar repintar a camada de vídeo também, mesmo o
    // frame do media_kit não tendo mudado.
    return RepaintBoundary(
      child: Video(
        controller: controller,
        controls: null,
        fill: Colors.black,
      ),
    );
  }
}

/// Scrim semi-transparente que cobre o [_VideoSurface] enquanto o
/// [PlaybackHealthMonitor] está tentando se recuperar sozinho (retry com
/// backoff na mesma URL ou troca de qualidade na cadeia de fallback, ver
/// [HealthMonitorPhase.retrying]).
///
/// O [Video] em si nunca é removido/recriado durante essa transição — só
/// `player.open()` é chamado de novo em cima do mesmo `Player`/
/// `VideoController` (ver [PlaybackHealthMonitor._handleFailure] e
/// [PlayerProvider.playUrl]) — mas a troca de textura nativa do media_kit
/// nesse meio-tempo ainda pode aparecer como um flash/frame em branco por
/// baixo do spinner de buffering. Este scrim cobre esse instante com um
/// crossfade curto em vez do corte abrupto, só removido quando o monitor
/// sai de [HealthMonitorPhase.retrying] (sucesso, falha definitiva ou
/// reset — nunca antes do novo stream já estar de fato tentando tocar).
///
/// `AnimatedContainer` (não `AnimatedOpacity`) de propósito: a barra de
/// controles já usa um `AnimatedOpacity` pra esconder/mostrar (ver
/// `_PlayerScreenBodyState.build`), e os testes de D-Pad existentes
/// localizam esse widget por tipo (`find.byType(AnimatedOpacity)`) — um
/// segundo `AnimatedOpacity` na árvore quebraria essa busca, mesmo motivo
/// documentado em [_SeekFeedbackOverlay].
class _FallbackTransitionScrim extends StatelessWidget {
  final bool active;

  const _FallbackTransitionScrim({required this.active});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        color: active ? Colors.black54 : Colors.transparent,
      ),
    );
  }
}

class _BufferingIndicator extends StatelessWidget {
  const _BufferingIndicator();

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, PlayerLoadStatus>(
      selector: (_, provider) => provider.status,
      builder: (context, status, _) {
        final visible = status == PlayerLoadStatus.loading || status == PlayerLoadStatus.buffering;
        if (!visible) return const SizedBox.shrink();

        return const Center(
          child: CircularProgressIndicator(color: AppTheme.primaryColor),
        );
      },
    );
  }
}

class _ErrorOverlay extends StatelessWidget {
  final VoidCallback onRetry;
  final FocusNode retryFocusNode;

  /// `true` enquanto o [PlaybackHealthMonitor] ainda está tentando se
  /// recuperar sozinho (ver [HealthMonitorPhase.retrying]) — o overlay fica
  /// escondido mesmo com [PlayerProvider.status] em erro (ou [healthPhase]
  /// em [HealthMonitorPhase.failed]), porque o [_HealthStatusOverlay] já
  /// comunica que algo está em andamento e pedir uma ação manual do usuário
  /// nesse momento seria redundante/confuso.
  final bool suppressed;

  /// Fase atual do [PlaybackHealthMonitor] — segunda fonte de "erro real",
  /// além de [PlayerProvider.status]. Necessária porque falhas detectadas
  /// só pelo monitor (stall de buffering ou watchdog de posição — rede
  /// caindo "em silêncio", sem o media_kit emitir `stream.error`) NUNCA
  /// levam [PlayerProvider._status] a [PlayerLoadStatus.error]: o retry por
  /// backoff do monitor reabre a URL direto no `Player`, sem passar por
  /// `PlayerProvider.playUrl`. Sem isso o overlay (e o botão "Tentar
  /// novamente") nunca aparecia nesse caminho, mesmo com o monitor já tendo
  /// desistido de vez — só saía do estado saindo da tela e reabrindo o
  /// canal.
  final HealthMonitorPhase healthPhase;

  const _ErrorOverlay({
    required this.onRetry,
    required this.retryFocusNode,
    required this.healthPhase,
    this.suppressed = false,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, ({PlayerLoadStatus status, String? message})>(
      selector: (_, provider) => (status: provider.status, message: provider.errorMessage),
      builder: (context, data, _) {
        if (suppressed) return const SizedBox.shrink();

        final isProviderError = data.status == PlayerLoadStatus.error;
        final isHealthMonitorFailed = healthPhase == HealthMonitorPhase.failed;
        if (!isProviderError && !isHealthMonitorFailed) return const SizedBox.shrink();

        // No caminho do monitor (stall silencioso), o PlayerProvider nunca
        // chegou a setar errorMessage — usa um texto genérico de conexão em
        // vez do genérico "não foi possível reproduzir" (esse último cobre
        // só o caso, teoricamente inesperado, de erro do provider sem
        // mensagem).
        final message = data.message ??
            (isHealthMonitorFailed
                ? 'Não foi possível reproduzir. Verifique sua conexão.'
                : 'Não foi possível reproduzir este conteúdo.');

        return Container(
          color: Colors.black87,
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: AppTheme.errorColor),
                const SizedBox(height: AppSpacing.m),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: AppSpacing.l),
                DpadFocusHighlight(
                  focusNode: retryFocusNode,
                  borderRadius: BorderRadius.circular(8),
                  builder: (context, focusNode, hasFocus) => ElevatedButton.icon(
                    focusNode: focusNode,
                    autofocus: true,
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Tentar novamente'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ControlsOverlay extends StatelessWidget {
  final bool isFullscreenCapable;
  final bool isFullscreen;
  final FocusNode backFocusNode;
  final FocusNode playPauseFocusNode;
  final FocusNode fullscreenFocusNode;
  final FocusNode seekBackwardFocusNode;
  final FocusNode seekForwardFocusNode;
  final FocusNode progressBarFocusNode;
  final bool seekModeActive;
  final KeyEventResult Function(FocusNode, KeyEvent) onProgressBarKeyEvent;
  final VoidCallback onBack;
  final VoidCallback onToggleFullscreen;
  final ValueChanged<Duration> onSeek;

  const _ControlsOverlay({
    required this.isFullscreenCapable,
    required this.isFullscreen,
    required this.backFocusNode,
    required this.playPauseFocusNode,
    required this.fullscreenFocusNode,
    required this.seekBackwardFocusNode,
    required this.seekForwardFocusNode,
    required this.progressBarFocusNode,
    required this.seekModeActive,
    required this.onProgressBarKeyEvent,
    required this.onBack,
    required this.onToggleFullscreen,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: DecoratedBox(
        // Gradiente só na base (~40% inferior da tela) — o vídeo fica
        // visível atrás do resto dos controles, em vez de a tela inteira
        // escurecer como antes. O título ganha sombra própria (ver
        // AppTheme.playerTitleStyle) pra continuar legível sem um scrim no
        // topo.
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black87],
            stops: [0.6, 1],
          ),
        ),
        child: Column(
          children: [
            _TopBar(
              backFocusNode: backFocusNode,
              fullscreenFocusNode: fullscreenFocusNode,
              isFullscreenCapable: isFullscreenCapable,
              isFullscreen: isFullscreen,
              onBack: onBack,
              onToggleFullscreen: onToggleFullscreen,
            ),
            const Spacer(),
            _CenterControls(
              playPauseFocusNode: playPauseFocusNode,
              seekBackwardFocusNode: seekBackwardFocusNode,
              seekForwardFocusNode: seekForwardFocusNode,
              onSeek: onSeek,
            ),
            const Spacer(),
            _BottomBar(
              progressBarFocusNode: progressBarFocusNode,
              seekModeActive: seekModeActive,
              onKeyEvent: onProgressBarKeyEvent,
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final FocusNode backFocusNode;
  final FocusNode fullscreenFocusNode;
  final bool isFullscreenCapable;
  final bool isFullscreen;
  final VoidCallback onBack;
  final VoidCallback onToggleFullscreen;

  const _TopBar({
    required this.backFocusNode,
    required this.fullscreenFocusNode,
    required this.isFullscreenCapable,
    required this.isFullscreen,
    required this.onBack,
    required this.onToggleFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s, vertical: AppSpacing.xs),
        child: Row(
          children: [
            DpadFocusHighlight(
              focusNode: backFocusNode,
              borderRadius: BorderRadius.circular(24),
              builder: (context, focusNode, hasFocus) => IconButton(
                focusNode: focusNode,
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                tooltip: 'Voltar',
                onPressed: onBack,
              ),
            ),
            Expanded(
              child: Selector<PlayerProvider, String?>(
                selector: (_, provider) => provider.title,
                builder: (context, title, _) {
                  return Text(
                    title ?? '',
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.playerTitleStyle,
                  );
                },
              ),
            ),
            if (isFullscreenCapable)
              DpadFocusHighlight(
                focusNode: fullscreenFocusNode,
                borderRadius: BorderRadius.circular(24),
                builder: (context, focusNode, hasFocus) => IconButton(
                  focusNode: focusNode,
                  icon: Icon(
                    isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    color: Colors.white,
                  ),
                  tooltip: isFullscreen ? 'Sair da tela cheia' : 'Tela cheia',
                  onPressed: onToggleFullscreen,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Cluster central de reprodução: play/pause sozinho em Live TV (sem
/// posição pra buscar), ou flanqueado por -10s/+10s em VOD/episódio —
/// layout comum de player: `[-10s] [play/pause] [+10s]`. Fica no mesmo
/// bloco central (não junto do botão Voltar na barra superior) porque
/// conceitualmente pertence aos controles de reprodução, não de navegação;
/// isso também deixa a busca direcional padrão do Flutter (baseada em
/// geometria) encontrar os botões de seek naturalmente com seta
/// esquerda/direita a partir do play/pause, sem precisar de nenhuma lógica
/// de foco customizada.
class _CenterControls extends StatelessWidget {
  final FocusNode playPauseFocusNode;
  final FocusNode seekBackwardFocusNode;
  final FocusNode seekForwardFocusNode;
  final ValueChanged<Duration> onSeek;

  const _CenterControls({
    required this.playPauseFocusNode,
    required this.seekBackwardFocusNode,
    required this.seekForwardFocusNode,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, bool>(
      selector: (_, provider) => provider.isLive,
      builder: (context, isLive, _) {
        if (isLive) {
          return _CenterPlayPauseButton(focusNode: playPauseFocusNode);
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SeekButton(
              focusNode: seekBackwardFocusNode,
              icon: Icons.replay_10,
              tooltip: 'Retroceder 10 segundos',
              onPressed: () => onSeek(const Duration(seconds: -10)),
            ),
            const SizedBox(width: AppSpacing.xl),
            _CenterPlayPauseButton(focusNode: playPauseFocusNode),
            const SizedBox(width: AppSpacing.xl),
            _SeekButton(
              focusNode: seekForwardFocusNode,
              icon: Icons.forward_10,
              tooltip: 'Avançar 10 segundos',
              onPressed: () => onSeek(const Duration(seconds: 10)),
            ),
          ],
        );
      },
    );
  }
}

class _SeekButton extends StatelessWidget {
  final FocusNode focusNode;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _SeekButton({
    required this.focusNode,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return DpadFocusHighlight(
      focusNode: focusNode,
      borderRadius: BorderRadius.circular(32),
      builder: (context, focusNode, hasFocus) => IconButton(
        focusNode: focusNode,
        iconSize: 40,
        icon: Icon(icon, color: Colors.white),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}

/// Texto momentâneo ("-10s"/"+10s") que aparece e some sozinho ao acionar
/// um seek — só confirmação visual, sem interação (`IgnorePointer`) e sem
/// entrar na árvore de foco.
///
/// `AnimatedSwitcher` (não `AnimatedOpacity`) de propósito: a barra de
/// controles já usa um `AnimatedOpacity` pra esconder/mostrar (ver
/// `_PlayerScreenBodyState.build`), e os testes de D-Pad existentes
/// localizam esse widget por tipo (`find.byType(AnimatedOpacity)`) — um
/// segundo `AnimatedOpacity` na árvore quebraria essa busca ao passar a
/// encontrar dois widgets em vez de um.
class _SeekFeedbackOverlay extends StatelessWidget {
  final String? text;

  const _SeekFeedbackOverlay({required this.text});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: text == null
              ? const SizedBox.shrink(key: ValueKey('seek-feedback-empty'))
              : Container(
                  key: const ValueKey('seek-feedback-visible'),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(160),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    text!,
                    style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Banner discreto no topo da tela com o status do [PlaybackHealthMonitor]
/// ("Reconectando...", "Tentando qualidade alternativa...", "Falha
/// definitiva") — `IgnorePointer` porque é só informativo, nunca deve
/// roubar toque/D-Pad dos controles reais por baixo.
class _HealthStatusOverlay extends StatelessWidget {
  final String? status;

  const _HealthStatusOverlay({required this.status});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 56),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: status == null
                  ? const SizedBox.shrink(key: ValueKey('health-status-empty'))
                  : Container(
                      key: const ValueKey('health-status-visible'),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(180),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        status!,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CenterPlayPauseButton extends StatelessWidget {
  final FocusNode focusNode;

  const _CenterPlayPauseButton({required this.focusNode});

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, ({PlayerLoadStatus status, bool playing})>(
      selector: (_, provider) => (status: provider.status, playing: provider.isPlaying),
      builder: (context, data, _) {
        if (data.status == PlayerLoadStatus.error) return const SizedBox.shrink();

        return DpadFocusHighlight(
          focusNode: focusNode,
          borderRadius: BorderRadius.circular(40),
          builder: (context, focusNode, hasFocus) => IconButton(
            focusNode: focusNode,
            iconSize: 64,
            icon: Icon(
              data.playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
              color: Colors.white,
            ),
            onPressed: () => context.read<PlayerProvider>().togglePlayPause(),
          ),
        );
      },
    );
  }
}

class _BottomBar extends StatelessWidget {
  final FocusNode progressBarFocusNode;
  final bool seekModeActive;
  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  const _BottomBar({
    required this.progressBarFocusNode,
    required this.seekModeActive,
    required this.onKeyEvent,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, ({Duration position, Duration duration, bool live})>(
      selector: (_, provider) => (
        position: provider.position,
        duration: provider.duration,
        live: provider.isLive,
      ),
      builder: (context, data, _) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.l, vertical: AppSpacing.s),
            child: data.live
                ? const Align(
                    alignment: Alignment.centerLeft,
                    child: _LiveBadge(),
                  )
                // [TESTE] Antes, esta linha inteira ficava fora da travessia
                // por D-Pad (o Slider era o único candidato a foco, e
                // ExcludeFocus o tirava da jogada por completo) — bug
                // relatado: nenhum jeito de alcançar a barra pelo controle
                // remoto, só pelos botões -10s/+10s. Agora
                // DpadFocusHighlight+Focus dão à barra uma parada normal na
                // travessia, com um "modo de busca" (ver
                // PlayerScreen._handleProgressBarKeyEvent) que reaproveita
                // o mesmo _seekRelative dos botões -10s/+10s — o Slider em
                // si continua excluído (ver ExcludeFocus abaixo), pelo
                // motivo de sempre.
                : DpadFocusHighlight(
                    focusNode: progressBarFocusNode,
                    borderRadius: BorderRadius.circular(8),
                    builder: (context, focusNode, hasFocus) => Focus(
                      focusNode: focusNode,
                      onKeyEvent: onKeyEvent,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Text(_formatDuration(data.position), style: const TextStyle(color: Colors.white, fontSize: 12)),
                              Expanded(
                                // Fora da navegação por D-Pad de propósito: o Slider
                                // do Flutter, quando focado, captura as 4 setas para
                                // ajustar o próprio valor (inclusive cima/baixo) —
                                // ou seja, uma vez focado, não haveria como sair dele
                                // só com o D-Pad (sem Tab, que Android TV não tem).
                                // Continua 100% arrastável por toque/mouse.
                                child: ExcludeFocus(
                                  child: Slider(
                                    value: data.position.inMilliseconds
                                        .clamp(0, data.duration.inMilliseconds)
                                        .toDouble(),
                                    max: data.duration.inMilliseconds > 0
                                        ? data.duration.inMilliseconds.toDouble()
                                        : 1,
                                    activeColor: AppTheme.primaryColor,
                                    onChanged: (value) {
                                      context
                                          .read<PlayerProvider>()
                                          .seek(Duration(milliseconds: value.round()));
                                    },
                                  ),
                                ),
                              ),
                              Text(_formatDuration(data.duration), style: const TextStyle(color: Colors.white, fontSize: 12)),
                            ],
                          ),
                          // Dica textual só quando a barra está focada — sem
                          // ela, nada na tela indicaria que OK faz alguma
                          // coisa aqui (diferente dos botões -10s/+10s, cujo
                          // ícone já é autoexplicativo).
                          if (hasFocus)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                seekModeActive
                                    ? 'Use ◀ ▶ para buscar · OK para sair'
                                    : 'OK para buscar com o controle',
                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.errorColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'AO VIVO',
        style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }
}
