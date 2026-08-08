import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// Retângulo cinza com leve efeito de "pulso" (opacidade oscilando) — usado
/// como placeholder de skeleton loading no formato aproximado do conteúdo
/// real, em vez do spinner genérico centralizado que "esconde" o layout que
/// está prestes a aparecer.
///
/// Cada tela de skeleton tem no máximo algumas dezenas de instâncias
/// visíveis por vez (grid/lista truncada pela viewport do
/// `SliverGridDelegate`/`ListView`), então um [AnimationController] por
/// [SkeletonBox] (em vez de um único controller compartilhado) não pesa o
/// suficiente para justificar a complexidade extra de propagar esse
/// controller por toda a árvore.
class SkeletonBox extends StatefulWidget {
  final double? width;
  final double? height;
  final BorderRadius borderRadius;

  const SkeletonBox({
    super.key,
    this.width,
    this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
  });

  const SkeletonBox.circle({super.key, required double size})
      : width = size,
        height = size,
        borderRadius = const BorderRadius.all(Radius.circular(999));

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween<double>(begin: 0.35, end: 0.85).animate(
    CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Colors.grey.shade600,
          borderRadius: widget.borderRadius,
        ),
      ),
    );
  }
}

/// Placeholder de uma linha de lista (canal Live TV, episódio): círculo +
/// duas barras de texto, mesma silhueta geral de um [ListTile] com
/// `leading`/`title`/`subtitle`.
class SkeletonListRow extends StatelessWidget {
  final bool withSubtitle;

  const SkeletonListRow({super.key, this.withSubtitle = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.l, vertical: AppSpacing.s),
      child: Row(
        children: [
          const SkeletonBox.circle(size: 40),
          const SizedBox(width: AppSpacing.l),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(height: 14, width: withSubtitle ? 220 : 160),
                if (withSubtitle) ...[
                  const SizedBox(height: AppSpacing.s),
                  const SkeletonBox(height: 11, width: 120),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder de um card de pôster (VOD/Séries): retângulo vertical +
/// barra de título abaixo, mesma silhueta do `_PosterCard` real.
class SkeletonPosterCard extends StatelessWidget {
  const SkeletonPosterCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Expanded(child: SkeletonBox(borderRadius: BorderRadius.all(Radius.circular(8)))),
        const SizedBox(height: 6),
        SkeletonBox(height: 13, width: double.infinity, borderRadius: BorderRadius.circular(4)),
      ],
    );
  }
}

/// Placeholder de um chip de categoria/temporada — mesma altura/formato
/// arredondado do [ChoiceChip] real.
class SkeletonChip extends StatelessWidget {
  final double width;

  const SkeletonChip({super.key, this.width = 90});

  @override
  Widget build(BuildContext context) {
    return SkeletonBox(width: width, height: 32, borderRadius: BorderRadius.circular(20));
  }
}
