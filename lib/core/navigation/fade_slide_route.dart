import 'package:flutter/material.dart';

/// Rota com fade + leve slide vertical (200-300ms) — transição mais suave e
/// "profissional" entre as telas principais do fluxo (Home -> Player, Home
/// -> SeriesDetails, Perfis -> Home) do que o slide horizontal padrão do
/// MaterialPageRoute, sem exagerar (é um player de IPTV — trocar de canal
/// com frequência não pode ficar lento por causa de animação).
///
/// `maintainState`/`opaque` ficam nos valores padrão do [PageRouteBuilder]
/// (`true`) DE PROPÓSITO — é isso que mantém a rota anterior MONTADA (só
/// coberta, não destruída) enquanto esta está em cima, o mesmo mecanismo
/// que já permite o foco do D-Pad sobreviver a push/pop hoje (ver
/// `home_screen_dpad_test.dart`, grupo "Preservação de foco", e
/// `fade_slide_route_test.dart` para essa mesma garantia validada
/// diretamente sobre este helper).
PageRoute<T> fadeSlideRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 250),
    reverseTransitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
