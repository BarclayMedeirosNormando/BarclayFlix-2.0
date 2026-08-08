import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// Composição simples para o ícone de estados vazios/erro (categoria sem
/// conteúdo, falha de carregamento...): duas camadas de círculo bem sutis
/// (`Container` + opacity) atrás do ícone, em vez do ícone solto de 40px
/// que existia antes — só Flutter puro (nenhum asset de imagem), pra dar
/// um pouco mais de peso visual sem virar uma ilustração cara.
class StateIllustration extends StatelessWidget {
  final IconData icon;
  final bool isError;
  final double size;

  const StateIllustration({
    super.key,
    required this.icon,
    this.isError = false,
    this.size = 96,
  });

  @override
  Widget build(BuildContext context) {
    final tint = isError ? AppTheme.errorColor : AppTheme.primaryColor;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle, color: tint.withAlpha(18)),
          ),
          Container(
            width: size * 0.7,
            height: size * 0.7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: tint.withAlpha(32)),
          ),
          Icon(icon, size: size * 0.4, color: tint.withAlpha(230)),
        ],
      ),
    );
  }
}
