import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// Selo "Novo" sobreposto no canto de um card de VOD (ver
/// HomeScreen._VodGrid) — mesmo padrão visual/posição do [QualityBadge] de
/// Live TV, só que os dois nunca aparecem juntos (VOD não tem selo de
/// qualidade, Live TV não tem data de adição), então reaproveitam o mesmo
/// slot `topLeftBadge` de `_PosterCard` em vez de precisar de um segundo.
class NewBadge extends StatelessWidget {
  const NewBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.primaryColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'Novo',
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
      ),
    );
  }
}
