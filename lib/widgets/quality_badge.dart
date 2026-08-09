import 'package:flutter/material.dart';

import '../core/utils/channel_quality.dart';

/// Selo de qualidade (FHD/HD/SD) sobreposto no canto de um card de canal —
/// fundo claro da cor da qualidade + texto no tom ESCURO da mesma cor
/// (nunca preto puro sobre fundo colorido, ver pedido de UI original).
/// Widget isolado (não só um `Container` inline) para reaproveitar em
/// qualquer lugar que precise do mesmo selo no futuro (ex: detalhes do
/// canal, se vier a existir).
class QualityBadge extends StatelessWidget {
  final ChannelQuality quality;

  const QualityBadge({super.key, required this.quality});

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (quality) {
      ChannelQuality.fhd => (Colors.teal.shade100, Colors.teal.shade900),
      ChannelQuality.hd => (Colors.amber.shade100, Colors.amber.shade900),
      ChannelQuality.sd => (Colors.grey.shade300, Colors.grey.shade800),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        quality.label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: foreground),
      ),
    );
  }
}
