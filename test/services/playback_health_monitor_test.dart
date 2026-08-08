import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:iptv_app/services/playback_health_monitor.dart';

import '../test_helpers/fake_player.dart';

/// [FakePlatformPlayer] só expõe `emitDuration`/`emitPosition`/`emitPlaying`
/// (usados pelos testes de [PlayerProvider]) — aqui reaproveitamos o mesmo
/// seam (mesma classe base, mesmos `*Controller` `@protected` herdados de
/// `PlatformPlayer`) só acrescentando os dois eventos que
/// [PlaybackHealthMonitor] escuta, sem tocar no arquivo compartilhado.
class _FaultyFakePlatformPlayer extends FakePlatformPlayer {
  void emitError(String message) => errorController.add(message);

  void emitBuffering(bool buffering) => bufferingController.add(buffering);
}

typedef _MonitorSetup = ({
  PlaybackHealthMonitor monitor,
  _FaultyFakePlatformPlayer fake,
  List<String> statuses,
  List<String> urlSwitches,
});

_MonitorSetup _buildMonitor(List<String> fallbackUrls) {
  final fake = _FaultyFakePlatformPlayer();
  final player = Player(platformPlayer: fake);
  final statuses = <String>[];
  final urlSwitches = <String>[];

  final monitor = PlaybackHealthMonitor(
    player: player,
    fallbackUrls: fallbackUrls,
    onStatusChange: statuses.add,
    onUrlSwitch: urlSwitches.add,
  );
  monitor.start();

  return (monitor: monitor, fake: fake, statuses: statuses, urlSwitches: urlSwitches);
}

const _fallbackUrls = [
  'http://painel.com/live/u/p/1.ts',
  'http://painel.com/live/u/p/1.m3u8',
  'http://painel.com/get.php?output=ts',
  'http://painel.com/get.php?output=m3u8',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('retry com backoff na mesma URL', () {
    test('erro imediato dispara retry com delays progressivos (2s, 4s, 8s)', () {
      fakeAsync((async) {
        final setup = _buildMonitor(_fallbackUrls);

        setup.fake.emitError('falha de conexão');
        async.flushMicrotasks();

        expect(setup.statuses, ['Reconectando... (tentativa 1)']);
        expect(setup.fake.openCallCount, 0); // ainda não decorreu o backoff

        async.elapse(const Duration(seconds: 2));
        expect(setup.fake.openCallCount, 1); // reabriu a MESMA url

        setup.fake.emitError('falha de novo');
        async.flushMicrotasks();
        expect(setup.statuses.last, 'Reconectando... (tentativa 2)');

        async.elapse(const Duration(seconds: 4));
        expect(setup.fake.openCallCount, 2);

        setup.fake.emitError('e de novo');
        async.flushMicrotasks();
        expect(setup.statuses.last, 'Reconectando... (tentativa 3)');

        async.elapse(const Duration(seconds: 8));
        expect(setup.fake.openCallCount, 3);

        // As 3 tentativas de retry se esgotaram sem nunca trocar de URL.
        expect(setup.urlSwitches, isEmpty);
      });
    });

    test('não conta a mesma falha duas vezes quando erro e stall chegam juntos', () {
      fakeAsync((async) {
        final setup = _buildMonitor(_fallbackUrls);

        setup.fake.emitBuffering(true);
        async.elapse(const Duration(seconds: 15)); // dispara o stall timer
        async.flushMicrotasks();

        setup.fake.emitError('erro chegando logo depois do stall');
        async.flushMicrotasks();

        // Só 1 tentativa contabilizada (o erro chegou enquanto um retry já
        // estava agendado a partir do stall, então foi ignorado).
        expect(setup.statuses, ['Reconectando... (tentativa 1)']);
      });
    });
  });

  group('troca de URL após esgotar retries', () {
    test('4ª falha na mesma URL troca para a próxima da cadeia de fallback', () {
      fakeAsync((async) {
        final setup = _buildMonitor(_fallbackUrls);

        _exhaustCurrentUrl(async, setup);
        expect(setup.urlSwitches, isEmpty);

        setup.fake.emitError('4ª falha na mesma url');
        async.flushMicrotasks();

        expect(setup.urlSwitches, [_fallbackUrls[1]]);
        expect(setup.statuses.last, 'Tentando qualidade alternativa...');
      });
    });

    test('percorre toda a cadeia antes de reportar falha definitiva, sem loop infinito', () {
      fakeAsync((async) {
        final setup = _buildMonitor(_fallbackUrls);

        // Para cada uma das 3 primeiras URLs: esgota os 3 retries e a falha
        // seguinte troca de URL — a troca reseta o retryCount, então o
        // próximo ciclo de retries desta nova URL volta a começar do delay
        // de 2s (não pode ser tratado como continuação do loop anterior).
        for (var urlIndex = 0; urlIndex < _fallbackUrls.length - 1; urlIndex++) {
          _exhaustCurrentUrl(async, setup);
          setup.fake.emitError('falha que aciona a troca de URL');
          async.flushMicrotasks();
        }

        // Última URL da cadeia: esgota os 3 retries e a falha seguinte não
        // tem mais pra onde trocar -> falha definitiva.
        _exhaustCurrentUrl(async, setup);
        setup.fake.emitError('falha definitiva');
        async.flushMicrotasks();

        expect(setup.urlSwitches, [_fallbackUrls[1], _fallbackUrls[2], _fallbackUrls[3]]);
        expect(setup.statuses.last, 'Falha definitiva');

        // Depois da falha definitiva, nenhuma nova tentativa/troca deve
        // acontecer (sem loop infinito) mesmo se o player continuar
        // reportando erro.
        final statusesBefore = List<String>.from(setup.statuses);
        final switchesBefore = List<String>.from(setup.urlSwitches);
        setup.fake.emitError('mais uma falha após desistir');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));

        expect(setup.statuses, statusesBefore);
        expect(setup.urlSwitches, switchesBefore);
      });
    });
  });

  group('stall de buffering (sem erro explícito)', () {
    test('buffering contínuo por 15s é tratado como falha', () {
      fakeAsync((async) {
        final setup = _buildMonitor(_fallbackUrls);

        setup.fake.emitBuffering(true);
        async.flushMicrotasks();
        expect(setup.statuses, isEmpty); // ainda dentro da janela de 15s

        async.elapse(const Duration(seconds: 15));

        expect(setup.statuses, ['Reconectando... (tentativa 1)']);
      });
    });

    test('buffering que volta a false antes de 15s não dispara falha', () {
      fakeAsync((async) {
        final setup = _buildMonitor(_fallbackUrls);

        setup.fake.emitBuffering(true);
        async.elapse(const Duration(seconds: 10));
        setup.fake.emitBuffering(false);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 10)); // passaria de 15s se não tivesse cancelado

        expect(setup.statuses, isEmpty);
      });
    });
  });

  group('reset()', () {
    test('zera o ciclo — próxima falha volta a contar da tentativa 1 na primeira URL', () {
      fakeAsync((async) {
        final setup = _buildMonitor(_fallbackUrls);

        // Avança até a 2ª URL da cadeia.
        _exhaustCurrentUrl(async, setup);
        setup.fake.emitError('4ª falha');
        async.flushMicrotasks();
        expect(setup.urlSwitches, [_fallbackUrls[1]]);

        setup.monitor.reset();

        setup.fake.emitError('falha após reset');
        async.flushMicrotasks();

        expect(setup.statuses.last, 'Reconectando... (tentativa 1)');
      });
    });

    test('cancela um retry pendente antes do backoff terminar', () {
      fakeAsync((async) {
        final setup = _buildMonitor(_fallbackUrls);

        setup.fake.emitError('falha');
        async.flushMicrotasks();

        setup.monitor.reset();
        async.elapse(const Duration(seconds: 2));

        // O retry agendado antes do reset não deve reabrir a url.
        expect(setup.fake.openCallCount, 0);
      });
    });
  });

  group('dispose()', () {
    test('cancela subscriptions e timers — eventos após dispose são ignorados', () {
      fakeAsync((async) {
        final setup = _buildMonitor(_fallbackUrls);

        setup.fake.emitBuffering(true);
        async.flushMicrotasks();

        setup.monitor.dispose();

        // Sem isso o stall timer dispararia handleFailure() mesmo depois do
        // dispose, se a subscription/timer não tivessem sido cancelados.
        async.elapse(const Duration(seconds: 15));

        expect(setup.statuses, isEmpty);
      });
    });
  });
}

/// Delay de backoff correspondente à tentativa de índice [i] (0-based),
/// espelhando `PlaybackHealthMonitor._backoffDelays`.
Duration _backoffFor(int i) => [
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
    ][i];

/// Esgota as 3 tentativas de retry na URL atualmente ativa do monitor (sem
/// disparar a 4ª falha, que decide entre trocar de URL ou desistir de vez —
/// ver [PlaybackHealthMonitor._handleFailure]). Cada falha simulada aqui
/// sempre encontra o monitor com `retryCount` reiniciado em 0 (é sempre o
/// início do ciclo de retries de uma URL), então o índice do loop bate
/// exatamente com o índice usado internamente em `_backoffDelays`.
void _exhaustCurrentUrl(FakeAsync async, _MonitorSetup setup) {
  for (var i = 0; i < 3; i++) {
    setup.fake.emitError('falha');
    async.flushMicrotasks();
    async.elapse(_backoffFor(i));
  }
}
