import 'package:media_kit/media_kit.dart';

import 'package:iptv_app/providers/player_provider.dart';

/// [PlatformPlayer] fake para testes de widget: evita que [Player] tente
/// carregar o libmpv nativo via FFI (`DynamicLibrary.open` dentro de
/// `NativePlayer`), o que quebra imediatamente em `flutter_test` (sem
/// engine/binários nativos disponíveis).
///
/// Também conta quantas vezes cada método foi chamado — usado pelos testes
/// de D-Pad como spy, pra confirmar que Enter/Select disparou a mesma ação
/// que o `onPressed`/`onTap` já ligado ao widget real (sem precisar simular
/// mudança de estado de reprodução de verdade, que o fake não faz).
///
/// Só sobrescreve os métodos realmente exercitados pelos testes de D-Pad —
/// os demais (setVolume, setRate, add, remove...) herdam o
/// `throw UnimplementedError` padrão do `PlatformPlayer`, o que é aceitável
/// porque nenhum teste de navegação os aciona.
class FakePlatformPlayer extends PlatformPlayer {
  FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  int openCallCount = 0;
  int playCallCount = 0;
  int pauseCallCount = 0;
  int playOrPauseCallCount = 0;
  int seekCallCount = 0;

  /// Última posição (absoluta) passada para [seek] — usado pelos testes de
  /// seekRelative para conferir o clamping (não passar de zero/duração)
  /// além de só contar chamadas.
  Duration? lastSeekPosition;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    openCallCount++;
  }

  @override
  Future<void> play() async {
    playCallCount++;
  }

  @override
  Future<void> pause() async {
    pauseCallCount++;
  }

  @override
  Future<void> playOrPause() async {
    playOrPauseCallCount++;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration duration) async {
    seekCallCount++;
    lastSeekPosition = duration;
  }

  /// Simula o player reportando uma duração/posição/estado de reprodução
  /// conhecidos — os testes não podem tocar nos `*Controller` diretamente
  /// porque são `@protected` em [PlatformPlayer] (só acessível de dentro de
  /// membros de instância de subclasses, daí estes métodos aqui).
  void emitDuration(Duration duration) => durationController.add(duration);

  void emitPosition(Duration position) => positionController.add(position);

  void emitPlaying(bool playing) => playingController.add(playing);

  // VideoController/NativeVideoController.create() depende de `handle` para
  // anexar a saída de vídeo nativa ao player — descoberto rodando o teste
  // (sem isso, o Completer interno do VideoController falha com
  // "[PlatformPlayer.handle] is not implemented" como um erro assíncrono não
  // tratado, derrubando o teste mesmo sem nenhuma asserção relacionada a
  // vídeo). Na prática só importa quando um [VideoController] de verdade é
  // construído sobre este fake — ver nota em [PlayerProvider].
  @override
  Future<int> get handle async => 0;
}

/// [PlayerProvider] com [Player] apoiado em [FakePlatformPlayer] — nenhuma
/// chamada nativa acontece — junto com o [FakePlatformPlayer] usado por
/// baixo, para os testes inspecionarem as chamadas (spy).
typedef FakePlayerSetup = ({PlayerProvider provider, FakePlatformPlayer fake});

FakePlayerSetup buildFakePlayerProvider() {
  final fake = FakePlatformPlayer();
  final player = Player(platformPlayer: fake);
  final provider = PlayerProvider(player: player);
  return (provider: provider, fake: fake);
}
