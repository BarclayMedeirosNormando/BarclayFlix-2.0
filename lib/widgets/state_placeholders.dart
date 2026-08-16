import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import 'state_illustration.dart';

/// [TESTE] Estado vazio genérico (ícone + mensagem) — extraído de
/// home_screen.dart pra ser reaproveitado pelas novas telas do redesenho
/// (HubScreen/CategoryListScreen/LiveChannelsScreen/ContentGridScreen),
/// que antes viviam todas dentro de home_screen.dart e cada uma tinha sua
/// própria cópia privada disso.
class EmptyHint extends StatelessWidget {
  final IconData icon;
  final String message;

  const EmptyHint({super.key, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StateIllustration(icon: icon),
            const SizedBox(height: AppSpacing.m),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade400),
            ),
          ],
        ),
      ),
    );
  }
}

/// [TESTE] Estado de erro genérico com botão "Tentar novamente" — mesma
/// origem/motivo de [EmptyHint] acima.
class ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final bool compact;

  const ErrorRetry({
    super.key,
    required this.message,
    required this.onRetry,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Center(
        child: TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: Text(message, overflow: TextOverflow.ellipsis),
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const StateIllustration(icon: Icons.error_outline, isError: true),
            const SizedBox(height: AppSpacing.m),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.l),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar novamente'),
            ),
          ],
        ),
      ),
    );
  }
}
