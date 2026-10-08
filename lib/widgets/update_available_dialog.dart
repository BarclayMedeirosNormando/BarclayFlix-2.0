import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models/app_update_info.dart';

/// Aviso (nunca bloqueante) de que existe uma versão mais nova. "Depois"
/// fecha e o app segue normal; "Atualizar" abre o link de download no
/// navegador. Ambos os botões são focáveis por D-Pad/teclado (o foco inicial
/// fica em "Atualizar").
Future<void> showUpdateAvailableDialog(BuildContext context, AppUpdateInfo info) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Nova versão ${info.latestVersion} disponível'),
      content: info.changelog.isEmpty
          ? const Text('Há uma atualização do aplicativo disponível.')
          : SingleChildScrollView(child: Text(info.changelog)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Depois'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            Navigator.of(dialogContext).pop();
            var opened = false;
            try {
              opened = await launchUrl(
                Uri.parse(info.downloadUrl),
                mode: LaunchMode.externalApplication,
              );
            } catch (_) {
              opened = false;
            }
            if (!opened) {
              messenger.showSnackBar(
                const SnackBar(content: Text('Não foi possível abrir o link de download.')),
              );
            }
          },
          child: const Text('Atualizar'),
        ),
      ],
    ),
  );
}
