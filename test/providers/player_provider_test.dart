import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iptv_app/data/models/watch_progress.dart';
import 'package:iptv_app/data/services/storage_service.dart';
import 'package:iptv_app/providers/player_provider.dart';

import '../test_helpers/fake_player.dart';

const _testUrl = 'http://servidor-teste.com:8080/movie/u/p/1.mp4';
const _testTitle = 'Filme Teste';

/// Deixa o [PlayerProvider] em estado de reprodução normal de um VOD
/// (duração conhecida, [PlayerLoadStatus.playing]) — pré-condição de
/// [PlayerProvider.seekRelative] para não fazer nada (ver guardas do
/// método).
Future<FakePlayerSetup> _playingVod({
  required Duration duration,
  required Duration position,
}) async {
  final setup = buildFakePlayerProvider();
  await setup.provider.playUrl(_testUrl, title: _testTitle);
  setup.fake.emitDuration(duration);
  setup.fake.emitPosition(position);
  setup.fake.emitPlaying(true);
  // Os *Controller do media_kit não são `sync: true` — `add()` só entrega
  // aos listeners (aqui, os handlers do PlayerProvider) num microtask
  // posterior, então sem isso os três `emit*` acima ainda não teriam sido
  // processados quando este helper retorna.
  await pumpEventQueue();
  return setup;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('seekRelative', () {
    test('avança a posição pelo offset informado', () async {
      final setup = await _playingVod(
        duration: const Duration(minutes: 10),
        position: const Duration(minutes: 2),
      );

      await setup.provider.seekRelative(const Duration(seconds: 10));

      expect(setup.fake.seekCallCount, 1);
      expect(setup.fake.lastSeekPosition, const Duration(minutes: 2, seconds: 10));
    });

    test('retrocede a posição pelo offset informado', () async {
      final setup = await _playingVod(
        duration: const Duration(minutes: 10),
        position: const Duration(minutes: 2),
      );

      await setup.provider.seekRelative(const Duration(seconds: -10));

      expect(setup.fake.seekCallCount, 1);
      expect(setup.fake.lastSeekPosition, const Duration(minutes: 1, seconds: 50));
    });

    test('não retrocede além de zero (clamping no início)', () async {
      final setup = await _playingVod(
        duration: const Duration(minutes: 10),
        position: const Duration(seconds: 5),
      );

      await setup.provider.seekRelative(const Duration(seconds: -10));

      expect(setup.fake.seekCallCount, 1);
      expect(setup.fake.lastSeekPosition, Duration.zero);
    });

    test('não avança além da duração total (clamping no fim)', () async {
      final setup = await _playingVod(
        duration: const Duration(minutes: 10),
        position: const Duration(minutes: 9, seconds: 55),
      );

      await setup.provider.seekRelative(const Duration(seconds: 10));

      expect(setup.fake.seekCallCount, 1);
      expect(setup.fake.lastSeekPosition, const Duration(minutes: 10));
    });

    test('não faz nada em Live TV (duração desconhecida)', () async {
      final setup = buildFakePlayerProvider();
      await setup.provider.playUrl(_testUrl, title: _testTitle);
      setup.fake.emitPlaying(true);
      // Sem emitDuration: duração permanece Duration.zero -> isLive == true.

      await setup.provider.seekRelative(const Duration(seconds: 10));

      expect(setup.fake.seekCallCount, 0);
    });

    test('não faz nada enquanto ainda buffering (duração já conhecida)', () async {
      final setup = buildFakePlayerProvider();
      await setup.provider.playUrl(_testUrl, title: _testTitle);
      setup.fake.emitDuration(const Duration(minutes: 10));
      // playUrl() já deixa o status em `buffering` após o open() resolver;
      // sem emitPlaying(true), nunca chega a `playing`.

      await setup.provider.seekRelative(const Duration(seconds: 10));

      expect(setup.fake.seekCallCount, 0);
    });

    test('não lança exceção quando chamado antes de qualquer playUrl (idle)', () async {
      final setup = buildFakePlayerProvider();

      await setup.provider.seekRelative(const Duration(seconds: 10));

      expect(setup.fake.seekCallCount, 0);
    });
  });

  group('Progresso de reprodução ("Continuar Assistindo")', () {
    setUp(() {
      // Backend em memória do shared_preferences, zerado a cada teste —
      // StorageService() (usado internamente pelo PlayerProvider) lê/escreve
      // nele por baixo, sem precisar de nenhuma injeção adicional.
      SharedPreferences.setMockInitialValues({});
    });

    Future<FakePlayerSetup> playingVodWithProgress({
      required Duration duration,
      required Duration position,
      String contentId = 'movie-1',
    }) async {
      final setup = buildFakePlayerProvider();
      await setup.provider.playUrl(
        _testUrl,
        title: _testTitle,
        contentId: contentId,
        imageUrl: 'http://servidor-teste.com:8080/poster.jpg',
        progressType: WatchProgressType.vod,
      );
      setup.fake.emitDuration(duration);
      setup.fake.emitPosition(position);
      setup.fake.emitPlaying(true);
      await pumpEventQueue();
      return setup;
    }

    test('salva o progresso quando a posição avança com duração conhecida', () async {
      await playingVodWithProgress(
        duration: const Duration(minutes: 10),
        position: const Duration(minutes: 2),
      );

      final saved = await StorageService().getAllProgress();
      expect(saved, hasLength(1));
      expect(saved.single.contentId, 'movie-1');
      expect(saved.single.title, _testTitle);
      expect(saved.single.positionSeconds, const Duration(minutes: 2).inSeconds);
      expect(saved.single.durationSeconds, const Duration(minutes: 10).inSeconds);
      expect(saved.single.type, WatchProgressType.vod);
      expect(saved.single.playbackUrl, _testUrl);
    });

    test('não salva progresso sem contentId (ex: Live TV)', () async {
      final setup = buildFakePlayerProvider();
      await setup.provider.playUrl(_testUrl, title: _testTitle);
      setup.fake.emitDuration(const Duration(minutes: 10));
      setup.fake.emitPosition(const Duration(minutes: 2));
      setup.fake.emitPlaying(true);
      await pumpEventQueue();

      expect(await StorageService().getAllProgress(), isEmpty);
    });

    test('não salva progresso enquanto a duração ainda é desconhecida (Live TV real)', () async {
      final setup = buildFakePlayerProvider();
      await setup.provider.playUrl(
        _testUrl,
        title: _testTitle,
        contentId: 'movie-1',
        progressType: WatchProgressType.vod,
      );
      setup.fake.emitPosition(const Duration(seconds: 30));
      // Sem emitDuration: duração fica em Duration.zero -> isLive == true.
      await pumpEventQueue();

      expect(await StorageService().getAllProgress(), isEmpty);
    });

    test('ticks de posição em sequência rápida só salvam uma vez (throttle de 10s)', () async {
      final setup = await playingVodWithProgress(
        duration: const Duration(minutes: 10),
        position: const Duration(minutes: 1),
      );

      setup.fake.emitPosition(const Duration(minutes: 1, seconds: 1));
      setup.fake.emitPosition(const Duration(minutes: 1, seconds: 2));
      await pumpEventQueue();

      final saved = await StorageService().getAllProgress();
      expect(saved, hasLength(1));
      // Ainda reflete a primeira posição salva — as seguintes caíram dentro
      // da janela de throttle de 10s (tempo real decorrido no teste é da
      // ordem de milissegundos).
      expect(saved.single.positionSeconds, const Duration(minutes: 1).inSeconds);
    });

    test('pausar força o salvamento imediato, ignorando o throttle', () async {
      final setup = await playingVodWithProgress(
        duration: const Duration(minutes: 10),
        position: const Duration(minutes: 1),
      );

      setup.fake.emitPosition(const Duration(minutes: 1, seconds: 5));
      setup.fake.emitPlaying(false);
      await pumpEventQueue();

      final saved = await StorageService().getAllProgress();
      expect(saved.single.positionSeconds, const Duration(minutes: 1, seconds: 5).inSeconds);
    });

    test('atingir 95%+ da duração remove o progresso em vez de salvar', () async {
      final setup = await playingVodWithProgress(
        duration: const Duration(minutes: 10),
        position: const Duration(minutes: 2),
      );
      expect(await StorageService().getAllProgress(), hasLength(1));

      setup.fake.emitPosition(const Duration(minutes: 9, seconds: 40)); // 96,6%
      setup.fake.emitPlaying(false); // força salvar/remover, ignora o throttle
      await pumpEventQueue();

      expect(await StorageService().getAllProgress(), isEmpty);
    });

    test('dispose() salva a posição mais recente, mesmo dentro da janela de throttle', () async {
      final setup = await playingVodWithProgress(
        duration: const Duration(minutes: 10),
        position: const Duration(minutes: 3),
      );

      // Dentro da janela de throttle: sozinho não geraria uma nova escrita
      // (ver teste de throttle acima) — dispose() precisa ignorar isso.
      setup.fake.emitPosition(const Duration(minutes: 3, seconds: 30));
      // Deixa o evento de posição (assíncrono, via StreamController) ser
      // processado ANTES do dispose — senão a assinatura é cancelada com o
      // evento ainda na fila, e o provider nunca chega a ver a posição nova
      // (o que este teste não quer verificar: aqui o alvo é o throttle, não
      // essa outra corrida).
      await pumpEventQueue();
      setup.provider.dispose();
      await pumpEventQueue();

      final saved = await StorageService().getAllProgress();
      expect(saved.single.positionSeconds, const Duration(minutes: 3, seconds: 30).inSeconds);
    });

    test('startAtSeconds faz seek pra posição salva logo após abrir a mídia', () async {
      final setup = buildFakePlayerProvider();
      await setup.provider.playUrl(
        _testUrl,
        title: _testTitle,
        contentId: 'movie-1',
        progressType: WatchProgressType.vod,
        startAtSeconds: 125,
      );

      expect(setup.fake.seekCallCount, 1);
      expect(setup.fake.lastSeekPosition, const Duration(seconds: 125));
    });

    test('sem startAtSeconds (padrão 0) não faz seek ao abrir', () async {
      final setup = buildFakePlayerProvider();
      await setup.provider.playUrl(_testUrl, title: _testTitle);

      expect(setup.fake.seekCallCount, 0);
    });
  });
}
