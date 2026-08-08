import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/theme/app_theme.dart';
import 'providers/auth_provider.dart';
import 'providers/profiles_provider.dart';
import 'providers/series_details_provider.dart';
import 'screens/splash/splash_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // DIAGNÓSTICO TEMPORÁRIO (investigação de travamento da janela ao cair o
  // Wi-Fi durante reprodução) — roda pra sempre, independente de qual tela
  // está em foco, pra revelar se a isolate Dart continua respondendo
  // (heartbeat nunca para) ou trava junto com a janela (heartbeat some do
  // console) quando o app congela. Remover junto com os demais debugPrint
  // depois que a causa raiz for confirmada e corrigida.
  Timer.periodic(const Duration(milliseconds: 500), (_) {
    debugPrint('[Heartbeat] ${DateTime.now()}');
  });

  // A fonte Inter é self-hosted (ver assets/fonts/ + a seção "fonts" do
  // pubspec.yaml) e aplicada via TextTheme.apply(fontFamily: 'Inter') em
  // AppTheme — não pelo helper dinâmico GoogleFonts.interTextTheme() (ver
  // comentário lá do porquê). Ainda assim, desligar allowRuntimeFetching
  // aqui é uma segunda trava: se qualquer código (hoje ou no futuro) chamar
  // GoogleFonts.inter()/GoogleFonts.xxx() diretamente, garante que NUNCA
  // tenta baixar nada pela rede — um app de IPTV não pode ganhar uma
  // dependência de rede só pra abrir a tela inicial.
  GoogleFonts.config.allowRuntimeFetching = false;

  // Obrigatório antes de qualquer uso de Player/VideoController do
  // media_kit (PlayerProvider) — registra os backends nativos (libmpv).
  MediaKit.ensureInitialized();

  // window_manager só tem implementação nativa para Windows/macOS/Linux;
  // chamar em Android/iOS derrubaria o app com MissingPluginException.
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
  }

  runApp(const IptvApp());
}

class IptvApp extends StatelessWidget {
  const IptvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(
          create: (context) =>
              ProfilesProvider(authProvider: context.read<AuthProvider>()),
        ),
        ChangeNotifierProvider(create: (_) => SeriesDetailsProvider()),
      ],
      child: MaterialApp(
        title: 'BarclayFlix 2.0',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: const SplashScreen(),
      ),
    );
  }
}
