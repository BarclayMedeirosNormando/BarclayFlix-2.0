import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/settings_provider.dart';

/// Tela de Configurações -- por enquanto só o bloqueio por PIN (definir/
/// alterar/remover). Marcar QUAIS categorias ficam protegidas acontece fora
/// daqui, direto no cadeado de cada categoria (ver `_CategoriesSidebar`/
/// `_CategoriesChips` em home_screen.dart) -- só faz sentido protegido
/// alguma coisa depois de já existir um PIN pra abri-la de novo, então o
/// fluxo natural é "definir o PIN aqui, depois voltar e trancar categorias
/// lá".
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _definePin(BuildContext context) async {
    final pin = await showDialog<String>(
      context: context,
      builder: (_) => const _SetPinDialog(),
    );
    if (pin == null || !context.mounted) return;
    await context.read<SettingsProvider>().setPin(pin);
  }

  Future<void> _removePin(BuildContext context) async {
    final settings = context.read<SettingsProvider>();
    final currentPin = await showDialog<String>(
      context: context,
      builder: (_) => const _EnterPinDialog(title: 'Digite o PIN atual pra remover'),
    );
    if (currentPin == null || !context.mounted) return;

    final valid = await settings.verifyPin(currentPin);
    if (!context.mounted) return;
    if (!valid) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN incorreto.')));
      return;
    }

    await settings.removePin();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PIN removido. Todas as categorias foram destravadas.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Configurações')),
        body: Focus(
          autofocus: true,
          skipTraversal: true,
          child: Consumer<SettingsProvider>(
            builder: (context, settings, _) {
              return ListView(
                padding: const EdgeInsets.all(AppSpacing.l),
                children: [
                  const Text(
                    'Bloqueio por PIN',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    settings.hasPin
                        ? 'PIN definido. Marque o cadeado de qualquer categoria (Live TV, Filmes ou Séries) para protegê-la.'
                        : 'Sem PIN definido ainda -- nenhuma categoria pode ser protegida até definir um.',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                  ),
                  const SizedBox(height: AppSpacing.l),
                  if (!settings.hasPin)
                    ElevatedButton.icon(
                      autofocus: true,
                      onPressed: () => _definePin(context),
                      icon: const Icon(Icons.lock_outline),
                      label: const Text('Definir PIN'),
                    )
                  else ...[
                    OutlinedButton.icon(
                      autofocus: true,
                      onPressed: () => _definePin(context),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Alterar PIN'),
                    ),
                    const SizedBox(height: AppSpacing.s),
                    OutlinedButton.icon(
                      onPressed: () => _removePin(context),
                      icon: const Icon(Icons.lock_open_outlined),
                      label: const Text('Remover PIN'),
                      style: OutlinedButton.styleFrom(foregroundColor: AppTheme.errorColor),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  const Text(
                    'Reprodução de vídeo',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Ative se os vídeos travarem/engasgarem periodicamente neste '
                    'aparelho específico (comum em algumas TVs). Desliga a '
                    'decodificação por hardware, mais compatível porém mais '
                    'pesada para o processador.',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Modo compatibilidade de vídeo'),
                    value: settings.videoCompatibilityMode,
                    onChanged: (value) => settings.setVideoCompatibilityMode(value),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Pede o PIN novo duas vezes (confirmação) -- usado tanto pra definir
/// quanto pra alterar (o botão "Alterar PIN" chama o mesmo fluxo: um PIN
/// novo simplesmente sobrescreve o antigo, ver `setPin`). NÃO pede o PIN
/// atual antes de trocar -- quem já está dentro de Configurações já passou
/// pela HomeScreen normal, não há um "dono" mais privilegiado da tela pra
/// exigir confirmação extra aqui.
class _SetPinDialog extends StatefulWidget {
  const _SetPinDialog();

  @override
  State<_SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends State<_SetPinDialog> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _pinController.text.trim();
    final confirm = _confirmController.text.trim();

    if (pin.length < 4) {
      setState(() => _error = 'O PIN precisa ter pelo menos 4 dígitos.');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'Os PINs não são iguais.');
      return;
    }

    Navigator.of(context).pop(pin);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Definir PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _pinController,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 8,
            decoration: const InputDecoration(labelText: 'Novo PIN'),
          ),
          TextField(
            controller: _confirmController,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 8,
            decoration: const InputDecoration(labelText: 'Confirme o PIN'),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(_error!, style: const TextStyle(color: AppTheme.errorColor, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        TextButton(onPressed: _submit, child: const Text('Salvar')),
      ],
    );
  }
}

/// Pede um PIN já existente pra confirmar uma ação -- usado tanto pra
/// remover o PIN (SettingsScreen) quanto pra desbloquear uma categoria
/// protegida (ver `_promptPinIfNeeded` em home_screen.dart). Devolve o PIN
/// digitado (não um bool) porque quem chama precisa validá-lo contra o
/// [SettingsProvider] de qualquer forma -- centraliza só a COLETA aqui.
class _EnterPinDialog extends StatefulWidget {
  final String title;

  const _EnterPinDialog({required this.title});

  @override
  State<_EnterPinDialog> createState() => _EnterPinDialogState();
}

class _EnterPinDialogState extends State<_EnterPinDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _controller.text.trim();
    if (pin.isEmpty) return;
    Navigator.of(context).pop(pin);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 8,
        decoration: const InputDecoration(labelText: 'PIN'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        TextButton(onPressed: _submit, child: const Text('Confirmar')),
      ],
    );
  }
}

/// Exportado pra home_screen.dart poder abrir o mesmo diálogo de "digite o
/// PIN" ao tentar entrar numa categoria protegida (ver
/// `_promptPinIfNeeded`), sem duplicar o widget.
Future<String?> showEnterPinDialog(BuildContext context, {required String title}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _EnterPinDialog(title: title),
  );
}
