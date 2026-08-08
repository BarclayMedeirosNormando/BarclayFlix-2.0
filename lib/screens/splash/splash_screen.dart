import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/profiles_provider.dart';
import '../activation/activation_screen.dart';
import '../home/home_screen.dart';

/// Tela de abertura: só a marca do app (mesmo ícone/estilo do header da
/// ActivationScreen, ver [_Brand]), sem nenhum input. Fica visível
/// exatamente pelo tempo real que [ProfilesProvider.loadProfiles] leva pra
/// carregar o perfil salvo do [StorageService] (nunca um atraso artificial)
/// e, se houver um, tentar revalidá-lo via ativação de dispositivo (deviceId,
/// ver DeviceIdService) — só então navega pra HomeScreen (sucesso) ou
/// ActivationScreen (sem perfil salvo, ou revalidação falhou).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAndContinue());
  }

  Future<void> _loadAndContinue() async {
    final provider = context.read<ProfilesProvider>();
    await provider.loadProfiles();

    if (!mounted) return;

    final savedProfile = provider.savedProfile;
    if (savedProfile != null) {
      final success = await provider.selectProfile(savedProfile.id);
      if (!mounted) return;
      if (success) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
        return;
      }

      // Revalidação automática falhou (dispositivo inativo/expirado,
      // servidor removido etc) -- nunca cai aqui em silêncio: leva a
      // mensagem/código REAIS pra ActivationScreen decidir se mostra o erro
      // já de cara ou só começa a verificar em segundo plano.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ActivationScreen(
            initialErrorMessage: provider.errorFor(savedProfile.id),
            initialErrorCode: provider.errorCodeFor(savedProfile.id),
          ),
        ),
      );
      return;
    }

    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ActivationScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: Center(child: _Brand()),
    );
  }
}

/// Mesmo ícone/tamanho/cor usados no header da ActivationScreen — mantém a
/// identidade visual consistente entre as duas telas sem sessão ativa do
/// app.
///
/// Título + slogan da marca "BarclayFlix 2.0" moram AQUI (não na
/// ActivationScreen): esta é a única tela do app sem nenhum outro texto —
/// puramente a marca, sem competir com as instruções da ActivationScreen. O
/// slogan usa um estilo visivelmente menor/mais claro que o título, para a
/// hierarquia ficar óbvia mesmo sem nenhum outro elemento por perto pra
/// comparar.
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.live_tv_rounded,
          size: 72,
          color: AppTheme.primaryColor,
        ),
        const SizedBox(height: 16),
        const Text(
          'BarclayFlix 2.0',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          'Seus canais, onde você estiver',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: Colors.grey.shade400),
        ),
        const SizedBox(height: 32),
        const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            color: AppTheme.primaryColor,
          ),
        ),
      ],
    );
  }
}
