import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptv_app/screens/player/player_screen.dart';

import '../../test_helpers/fake_player.dart';

const _testUrl = 'http://servidor-teste.com:8080/live/u/p/1.m3u8';
const _testTitle = 'Canal Teste';

/// Mesmo padrão usado nos testes de D-Pad da HomeScreen (e no próprio SDK
/// do Flutter, em focus_traversal_test.dart): [Focus.of] busca o FocusNode
/// do ANCESTRAL mais próximo a partir do contexto informado, então os
/// finders sempre apontam pra algo DENTRO do widget interativo real
/// (o Icon do IconButton, o próprio Slider), nunca pro DpadFocusHighlight
/// que o envolve por fora.
bool isFocused(WidgetTester tester, Finder finder) {
  return Focus.of(tester.element(finder)).hasFocus;
}

void focusItem(WidgetTester tester, Finder finder) {
  Focus.of(tester.element(finder)).requestFocus();
}

/// Confirma que ALGUM nó de foco já está ativo assim que a tela abre, SEM
/// nenhuma chamada manual de `requestFocus()` (nem `focusItem` acima) —
/// essa é a condição real que faz o Escape/D-Pad funcionarem desde o
/// primeiro frame (ver `_inputFocusNode`/`autofocus: true` em
/// player_screen.dart). Localiza o `Focus` raiz da tela pelo `debugLabel`
/// do seu `FocusNode` (não por `autofocus`/`skipTraversal`: o próprio
/// `Navigator` do Flutter já cria um `Focus` interno com essa MESMA
/// combinação de propriedades para cada rota — achado rodando este teste,
/// que por isso não pode distinguir "nosso" nó do nó interno do framework
/// só por elas).
bool _rootHasAutofocus(WidgetTester tester) {
  final finder = find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'player-input-surface');
  final focusNode = tester.widget<Focus>(finder).focusNode;
  return focusNode != null && focusNode.hasFocus;
}

/// Sobe a PlayerScreen direto como home da rota, com um [PlayerProvider]
/// apoiado num player fake (ver test_helpers/fake_player.dart).
///
/// Pump com durações explícitas em vez de `pumpAndSettle`: assim que o
/// PlayerProvider "abre" a URL (mesmo no fake), o status vira `buffering` e
/// a tela mostra um `CircularProgressIndicator` indeterminado, cuja
/// animação nunca converge — `pumpAndSettle` travaria esperando pra sempre
/// (comportamento confirmado rodando o teste dessa forma primeiro).
Future<FakePlayerSetup> pumpPlayerScreen(WidgetTester tester, {String title = _testTitle}) async {
  final setup = buildFakePlayerProvider();

  await tester.pumpWidget(
    MaterialApp(
      home: PlayerScreen(url: _testUrl, title: title, playerProvider: setup.provider),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));

  return setup;
}

void main() {
  group('Autofoco inicial (sem foco manual)', () {
    testWidgets('a tela já tem um nó de foco ativo assim que abre, sem nenhum requestFocus() manual', (tester) async {
      await pumpPlayerScreen(tester);

      // Nenhum focusItem()/requestFocus() antes desta linha — é exatamente
      // essa ausência que reproduziria o bug relatado em dispositivo
      // físico (D-Pad sem efeito nenhum): sem autofoco, nada na árvore
      // teria foco de teclado pra receber a primeira seta ou o Escape.
      expect(_rootHasAutofocus(tester), isTrue);
    });

    testWidgets('o botão Voltar já fica focado sozinho, e a seta move pro próximo controle — tudo sem foco manual', (tester) async {
      await pumpPlayerScreen(tester);

      // O salto automático do wrapper invisível pro primeiro controle já
      // aconteceu sozinho (ver `_inputFocusNode.nextFocus()` em
      // player_screen.dart) — sem ele, nenhuma seta moveria o foco pra
      // lugar nenhum a partir daqui (achado empírico: busca DIRECIONAL,
      // ao contrário de `nextFocus`/Tab, não atravessa a fronteira de um
      // nó `skipTraversal` sozinha).
      expect(isFocused(tester, find.byIcon(Icons.arrow_back)), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      expect(isFocused(tester, find.byIcon(Icons.play_circle_fill)), isTrue);
    });
  });

  group('Controles visíveis', () {
    testWidgets('seta move o foco entre os controles; Enter ativa o controle focado', (tester) async {
      final setup = await pumpPlayerScreen(tester);

      focusItem(tester, find.byIcon(Icons.arrow_back));
      await tester.pump();
      expect(isFocused(tester, find.byIcon(Icons.arrow_back)), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      expect(
        isFocused(tester, find.byIcon(Icons.play_circle_fill)),
        isTrue,
        reason: 'esperava o foco no botão de play/pause central após ArrowDown a partir de Voltar',
      );
      expect(isFocused(tester, find.byIcon(Icons.arrow_back)), isFalse);

      expect(setup.fake.playOrPauseCallCount, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      // A MESMA ação do onPressed do botão — nenhuma lógica de ativação
      // duplicada em cima do FocusNode, é o Flutter mapeando Enter para
      // ActivateIntent no InkWell por trás do IconButton.
      expect(setup.fake.playOrPauseCallCount, 1);
    });
  });

  group('Controles auto-hidden', () {
    testWidgets(
      'primeira seta/Enter só revela os controles, sem ativar nada nem mover foco; a próxima tecla já navega',
      (tester) async {
        final setup = await pumpPlayerScreen(tester);

        // Deixa o timer real de auto-hide (4s) dis-parar.
        await tester.pump(const Duration(seconds: 5));

        final opacityFinder = find.byType(AnimatedOpacity);
        expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, 0.0);

        final primaryFocusBefore = FocusManager.instance.primaryFocus;

        final handled = await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();

        expect(handled, isTrue, reason: 'o evento deve ser consumido (handled) só para reexibir os controles');
        expect(setup.fake.playOrPauseCallCount, 0, reason: 'a tecla que só revela não pode ativar nenhum controle');
        expect(
          FocusManager.instance.primaryFocus,
          same(primaryFocusBefore),
          reason: 'o foco não deve se mover na tecla que só reexibe os controles',
        );

        // Controles voltaram a ficar visíveis (AnimatedOpacity 200ms).
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, 1.0);

        // A partir daqui os controles já estão focáveis de novo — a
        // PRÓXIMA tecla navega/ativa normalmente.
        focusItem(tester, find.byIcon(Icons.play_circle_fill));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(setup.fake.playOrPauseCallCount, 1);
      },
    );
  });

  group('Slider de progresso (VOD)', () {
    testWidgets('nunca recebe foco via navegação por seta (ExcludeFocus)', (tester) async {
      final setup = await pumpPlayerScreen(tester);

      // Sem duração conhecida, isLive fica true e o Slider nem é
      // construído (mostra o badge "AO VIVO" no lugar) — simula um VOD
      // empurrando uma duração pelo stream do player fake.
      setup.fake.emitDuration(const Duration(minutes: 90));
      await tester.pump();

      expect(find.text('AO VIVO'), findsNothing);
      expect(find.byType(Slider), findsOneWidget);

      final sliderFocusNode = Focus.of(tester.element(find.byType(Slider)));

      // Teste direto: pede foco pro Slider explicitamente. Se o
      // ExcludeFocus estiver funcionando, o pedido é recusado e o foco não
      // vai para lá de jeito nenhum — nem por navegação, nem por pedido
      // direto.
      sliderFocusNode.requestFocus();
      await tester.pump();

      expect(
        sliderFocusNode.hasFocus,
        isFalse,
        reason: 'ExcludeFocus deveria impedir até um pedido explícito de foco no Slider',
      );
      expect(FocusManager.instance.primaryFocus, isNot(same(sliderFocusNode)));
    });
  });

  group('Seek (-10s/+10s) em VOD', () {
    /// Deixa a PlayerScreen num estado de VOD "tocando de verdade"
    /// (duração conhecida + posição + `playing`) — pré-condição tanto para
    /// os botões aparecerem (`isLive == false`) quanto para
    /// `seekRelative` de fato agir (ver guardas em [PlayerProvider]).
    Future<FakePlayerSetup> pumpVodPlayerScreen(WidgetTester tester) async {
      final setup = await pumpPlayerScreen(tester);
      setup.fake.emitDuration(const Duration(minutes: 10));
      setup.fake.emitPosition(const Duration(minutes: 2));
      setup.fake.emitPlaying(true);
      await tester.pump();
      return setup;
    }

    testWidgets('botões de seek aparecem em VOD', (tester) async {
      await pumpVodPlayerScreen(tester);

      expect(find.byIcon(Icons.replay_10), findsOneWidget);
      expect(find.byIcon(Icons.forward_10), findsOneWidget);
    });

    // Duas instâncias frescas de pump (não uma reaproveitando a mesma
    // navegação) de propósito: `ReadingOrderTraversalPolicy` mantém
    // histórico interno de travessia por grupo, associado ao FocusNode de
    // origem — encadear ArrowRight e ArrowLeft na mesma tela, com um
    // `requestFocus()` manual entre os dois pulando a Action de travessia,
    // deixa esse histórico inconsistente e o segundo pulo (ArrowLeft) não
    // se comporta como o espelho do primeiro (achado rodando o teste).
    testWidgets('seta direita a partir do play/pause foca o botão +10s', (tester) async {
      await pumpVodPlayerScreen(tester);

      // FakePlatformPlayer.state.playing nunca vira `true` sozinho (só o
      // stream `playing` é emitido via emitPlaying, não o `state` — ver
      // PlayerProvider.isPlaying, que lê `player.state.playing` direto);
      // o ícone central continua sendo o de "play", nunca o de "pause".
      focusItem(tester, find.byIcon(Icons.play_circle_fill));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        isFocused(tester, find.byIcon(Icons.forward_10)),
        isTrue,
        reason: 'esperava o foco no botão +10s à direita do play/pause',
      );
    });

    testWidgets('seta esquerda a partir do play/pause foca o botão -10s', (tester) async {
      await pumpVodPlayerScreen(tester);

      focusItem(tester, find.byIcon(Icons.play_circle_fill));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(
        isFocused(tester, find.byIcon(Icons.replay_10)),
        isTrue,
        reason: 'esperava o foco no botão -10s à esquerda do play/pause',
      );
    });

    testWidgets('OK no botão +10s aciona seekRelative com o offset correto', (tester) async {
      final setup = await pumpVodPlayerScreen(tester);

      focusItem(tester, find.byIcon(Icons.forward_10));
      await tester.pump();

      expect(setup.fake.seekCallCount, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(setup.fake.seekCallCount, 1);
      expect(setup.fake.lastSeekPosition, const Duration(minutes: 2, seconds: 10));
    });

    testWidgets('OK no botão -10s aciona seekRelative com o offset correto', (tester) async {
      final setup = await pumpVodPlayerScreen(tester);

      focusItem(tester, find.byIcon(Icons.replay_10));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(setup.fake.seekCallCount, 1);
      expect(setup.fake.lastSeekPosition, const Duration(minutes: 1, seconds: 50));
    });

    testWidgets('seek mantém os controles visíveis e reinicia o timer de auto-hide', (tester) async {
      final setup = await pumpVodPlayerScreen(tester);

      // Deixa passar quase o suficiente pro auto-hide disparar, sem chegar lá.
      await tester.pump(const Duration(seconds: 3));

      focusItem(tester, find.byIcon(Icons.forward_10));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      // Se o timer não tivesse reiniciado, o total acumulado (3s + 3s)
      // já teria passado dos 4s de auto-hide.
      await tester.pump(const Duration(seconds: 3));

      final opacityFinder = find.byType(AnimatedOpacity);
      expect(
        tester.widget<AnimatedOpacity>(opacityFinder).opacity,
        1.0,
        reason: 'seek deveria ter reiniciado o timer de auto-hide dos controles',
      );

      expect(setup.fake.seekCallCount, 1);
    });

    testWidgets('botões de seek não aparecem nem são focáveis em Live TV', (tester) async {
      // pumpPlayerScreen usa _testUrl (Live TV) e nenhum emitDuration é
      // chamado — duração permanece desconhecida, isLive == true.
      await pumpPlayerScreen(tester);

      expect(find.byIcon(Icons.replay_10), findsNothing);
      expect(find.byIcon(Icons.forward_10), findsNothing);
    });
  });

  group('Voltar/Escape', () {
    testWidgets('Escape sai do Player e volta pra tela anterior', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PlayerScreen(
                        url: _testUrl,
                        title: _testTitle,
                        playerProvider: buildFakePlayerProvider().provider,
                      ),
                    ),
                  ),
                  child: const Text('Abrir Player'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir Player'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(PlayerScreen), findsOneWidget);

      // PlayerScreen já teria foco real assim que monta (o Focus da
      // superfície de input tem autofocus:true), então diferente da
      // HomeScreen, Escape já deveria funcionar sem precisar focar nada
      // manualmente antes — é exatamente essa diferença que estamos
      // confirmando aqui.
      final handled = await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(handled, isTrue);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.text('Abrir Player'), findsOneWidget);
    });
  });
}
