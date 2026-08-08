import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// Destaque visual forte para itens navegáveis por D-Pad/teclado — borda
/// colorida + brilho + leve aumento de escala, pensado para ser percebido a
/// distância (Android TV), não um detalhe sutil de 1-2px.
///
/// [builder] recebe o [FocusNode] real que deve ser plugado no parâmetro
/// `focusNode` do widget interativo (ListTile, IconButton, InkWell,
/// ChoiceChip, ElevatedButton...). Isso é importante: os widgets Material já
/// respondem a Enter/Espaço/Select (D-Pad OK) quando têm o foco de teclado
/// de verdade — o Flutter mapeia essas teclas para `ActivateIntent`, que o
/// `InkWell` (usado por baixo de todos os widgets citados acima) já trata
/// internamente chamando o `onTap`/`onPressed` existente. Ou seja: não há
/// lógica de ativação para duplicar aqui, só o destaque visual.
///
/// Se nenhum [focusNode] for passado, este widget cria e gerencia um
/// internamente (igual o [Focus] nativo faz) — útil para itens de lista/grid
/// construídos dinamicamente, onde não há um FocusNode fixo declarado em
/// algum State pai.
class DpadFocusHighlight extends StatefulWidget {
  final FocusNode? focusNode;
  final Widget Function(BuildContext context, FocusNode focusNode, bool hasFocus) builder;
  final BorderRadius borderRadius;
  final bool scaleOnFocus;

  const DpadFocusHighlight({
    super.key,
    this.focusNode,
    required this.builder,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.scaleOnFocus = true,
  });

  @override
  State<DpadFocusHighlight> createState() => _DpadFocusHighlightState();
}

class _DpadFocusHighlightState extends State<DpadFocusHighlight> {
  FocusNode? _ownedFocusNode;
  bool _hasFocus = false;

  FocusNode get _focusNode => widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant DpadFocusHighlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      final previous = oldWidget.focusNode ?? _ownedFocusNode;
      previous?.removeListener(_onFocusChange);
      // Se passamos a receber um focusNode externo, o nó que criávamos
      // internamente não é mais necessário.
      if (widget.focusNode != null) {
        _ownedFocusNode?.dispose();
        _ownedFocusNode = null;
      }
      _focusNode.addListener(_onFocusChange);
      _hasFocus = _focusNode.hasFocus;
    }
  }

  void _onFocusChange() {
    if (_hasFocus != _focusNode.hasFocus) {
      setState(() => _hasFocus = _focusNode.hasFocus);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  static const _animationDuration = Duration(milliseconds: 150);

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: _animationDuration,
      curve: Curves.easeOut,
      transformAlignment: Alignment.center,
      transform: _hasFocus && widget.scaleOnFocus
          ? (Matrix4.identity()..scaleByDouble(1.06, 1.06, 1.06, 1))
          : Matrix4.identity(),
      decoration: BoxDecoration(
        borderRadius: widget.borderRadius,
        color: _hasFocus ? AppTheme.primaryColor.withAlpha(40) : null,
        // Sombra mais pronunciada que o "brilho" simples de antes: duas
        // camadas (uma mais concentrada, outra mais espalhada) tingidas da
        // cor primária — nunca preto puro, pra parecer glow, não sombra de
        // elevação comum.
        boxShadow: _hasFocus
            ? [
                BoxShadow(
                  color: AppTheme.primaryColor.withAlpha(150),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
                BoxShadow(
                  color: AppTheme.primaryColor.withAlpha(70),
                  blurRadius: 40,
                  spreadRadius: 6,
                ),
              ]
            : null,
      ),
      child: Stack(
        children: [
          widget.builder(context, _focusNode, _hasFocus),
          // Borda com gradiente (opacidade decrescente ao redor do
          // contorno) sobreposta ao conteúdo real — em vez de um
          // `Border.all` de cor sólida, que é tudo que um `BoxDecoration`
          // consegue desenhar nativamente. Sempre montada (só a opacidade
          // anima) para poder desvanecer suavemente ao perder o foco, com
          // a MESMA duração da escala/sombra acima, em vez de sumir de
          // repente.
          Positioned.fill(
            child: IgnorePointer(
              // `TweenAnimationBuilder`, não `AnimatedOpacity`: a
              // PlayerScreen já localiza SEU PRÓPRIO fade (mostrar/esconder
              // os controles) por tipo (`find.byType(AnimatedOpacity)`,
              // ver player_screen.dart) assumindo que só existe UM na
              // árvore — um segundo (dentro de cada DpadFocusHighlight
              // dos controles) quebraria essa busca.
              child: TweenAnimationBuilder<double>(
                duration: _animationDuration,
                curve: Curves.easeOut,
                tween: Tween<double>(end: _hasFocus ? 1 : 0),
                builder: (context, opacity, child) => Opacity(opacity: opacity, child: child),
                child: CustomPaint(
                  painter: _GradientFocusBorderPainter(borderRadius: widget.borderRadius),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Desenha o contorno em gradiente do foco (ver [_DpadFocusHighlightState.build])
/// — só um `Canvas.drawRRect` com `style: stroke` e um `Shader` de
/// gradiente, sem depender de nenhum pacote externo.
class _GradientFocusBorderPainter extends CustomPainter {
  final BorderRadius borderRadius;

  const _GradientFocusBorderPainter({required this.borderRadius});

  static const _strokeWidth = 2.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final rect = Offset.zero & size;
    // `deflate` mantém o traço inteiro dentro dos limites do widget (sem
    // isso, metade da largura do traço vazaria pra fora, já que
    // `Canvas.drawRRect` com `stroke` centraliza o traço EM CIMA do
    // contorno do retângulo, não por dentro dele).
    final rrect = borderRadius.toRRect(rect).deflate(_strokeWidth / 2);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..shader = SweepGradient(
        colors: [
          AppTheme.primaryColor,
          AppTheme.primaryColor.withAlpha(50),
          AppTheme.primaryColor,
        ],
        stops: const [0, 0.5, 1],
      ).createShader(rect);

    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _GradientFocusBorderPainter oldDelegate) {
    return oldDelegate.borderRadius != borderRadius;
  }
}
