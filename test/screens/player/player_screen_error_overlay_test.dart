import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:iptv_app/providers/player_provider.dart';
import 'package:iptv_app/screens/player/player_screen.dart';

import '../../test_helpers/fake_player.dart';

const _testUrl = 'http://servidor-teste.com:8080/live/u/p/1.ts';
const _testTitle = 'Canal Teste';

/// [FakePlatformPlayer] só expõe `emitDuration`/`emitPosition`/`emitPlaying`
/// (usados pelos demais testes de widget) — aqui reaproveitamos o mesmo seam
/// usado em playback_health_monitor_test.dart (mesma classe base, mesmos
/// `*Controller` `@protected`) só acrescentando `emitBuffering`, sem tocar
/// no arquivo compartilhado.
class _FaultyFakePlatformPlayer extends FakePlatformPlayer {
  void emitBuffering(bool buffering) => bufferingController.add(buffering);
}

typedef _FaultySetup = ({PlayerProvider provider, _FaultyFakePlatformPlayer fake});

_FaultySetup _buildFaultyProvider() {
  final fake = _FaultyFakePlatformPlayer();
  final player = Player(platformPlayer: fake);
  final provider = PlayerProvider(player: player);
  return (provider: provider, fake: fake);
}

/// Backoff usado internamente pelo PlaybackHealthMonitor entre uma falha e
/// o retry seguinte na MESMA url — espelha
/// PlaybackHealthMonitor._backoffDelays.
const _backoffDelays = [
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
];

/// Simula um ciclo de "buffering trava por 15s" (o timeout de stall do
/// PlaybackHealthMonitor) seguido do backoff do retry que vem depois —
/// NUNCA emite `stream.error`, só buffering, pra reproduzir exatamente o
/// caminho "falha silenciosa" diagnosticado (rede caindo sem o media_kit
/// nunca reportar um erro explícito).
Future<void> _stallAndWaitRetry(WidgetTester tester, _FaultyFakePlatformPlayer fake, Duration backoff) async {
  fake.emitBuffering(true);
  await tester.pump(const Duration(seconds: 15)); // dispara o stall timer -> _handleFailure
  await tester.pump(backoff); // deixa o retryTimer reabrir a mesma url
  fake.emitBuffering(false);
  await tester.pump();
}

void main() {
  group('_ErrorOverlay via HealthMonitor.failed (stall silencioso, sem PlayerProvider.status == error)', () {
    testWidgets(
      'buffering travado repetidamente (sem nenhum stream.error) leva o monitor a failed; '
      'overlay aparece com mensagem genérica e o botão "Tentar novamente" funciona',
      (tester) async {
        final setup = _buildFaultyProvider();

        // fallbackUrls padrão (= [_testUrl], cadeia de 1 url só) — esgota
        // mais rápido: 3 retries na mesma url e a 4ª falha já é definitiva,
        // sem precisar simular troca de url.
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(url: _testUrl, title: _testTitle, playerProvider: setup.provider),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('Tentar novamente'), findsNothing);

        // Esgota os 3 retries da única url da cadeia.
        for (var i = 0; i < 3; i++) {
          await _stallAndWaitRetry(tester, setup.fake, _backoffDelays[i]);
          expect(find.text('Tentar novamente'), findsNothing, reason: 'ainda em retrying, overlay deve ficar suprimido');
        }

        // 4ª falha: não há mais pra onde trocar -> falha definitiva.
        setup.fake.emitBuffering(true);
        await tester.pump(const Duration(seconds: 15));
        await tester.pump();

        // Confirma a premissa do diagnóstico: em NENHUM momento
        // PlayerProvider.status virou error (só o PlaybackHealthMonitor,
        // via stall de buffering, detectou a falha).
        expect(setup.provider.status, isNot(PlayerLoadStatus.error));
        expect(setup.provider.errorMessage, isNull);

        // Mesmo assim, o overlay aparece — decidido por healthPhase ==
        // HealthMonitorPhase.failed, não mais só por PlayerProvider.status.
        expect(find.text('Tentar novamente'), findsOneWidget);
        expect(find.text('Não foi possível reproduzir. Verifique sua conexão.'), findsOneWidget);

        final openCallCountBeforeRetry = setup.fake.openCallCount;

        await tester.tap(find.text('Tentar novamente'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // _retry() chamou _healthMonitor.reset() + PlayerProvider.retry(),
        // que reabre a mesma url -> overlay some de novo (voltou a
        // buffering/loading) e o retry realmente reabriu o player.
        expect(setup.fake.openCallCount, greaterThan(openCallCountBeforeRetry));
        expect(find.text('Tentar novamente'), findsNothing);
      },
    );
  });
}
