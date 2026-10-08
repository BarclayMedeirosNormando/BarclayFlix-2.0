import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'config/app_config.dart';
import 'core/theme/app_theme.dart';
import 'data/services/error_report_service.dart';
import 'providers/auth_provider.dart';
import 'providers/content_provider.dart';
import 'providers/continue_watching_provider.dart';
import 'providers/favorites_provider.dart';
import 'providers/profiles_provider.dart';
import 'providers/series_details_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/vod_details_provider.dart';
import 'screens/splash/splash_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Falhas não tratadas viram uma linha na aba "Logs" (sem bloquear e sem
  // nunca enviar dados sensíveis, ver ErrorReportService). O comportamento
  // padrão (imprimir no console) continua.
  final previousFlutterOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    ErrorReportService.instance.report(ErrorCategory.app, details.exceptionAsString());
    if (previousFlutterOnError != null) {
      previousFlutterOnError(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    ErrorReportService.instance.report(ErrorCategory.app, error.toString());
    debugPrint('Erro não tratado: $error\n$stack');
    return true;
  };

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

  assert(
    !AppConfig.isAppsScriptUrlMissing,
    'APPS_SCRIPT_URL não definida. Rode com '
    '--dart-define=APPS_SCRIPT_URL=https://script.google.com/macros/s/ID/exec '
    '(ou use ./scripts/setup_env.ps1).',
  );

  runApp(
    AppConfig.isAppsScriptUrlMissing
        ? const _MissingConfigApp()
        : const IptvApp(),
  );
}

/// Mostrada no lugar do app quando o build não recebeu APPS_SCRIPT_URL —
/// melhor um erro claro do que "falha de conexão" misteriosa na ativação.
class _MissingConfigApp extends StatelessWidget {
  const _MissingConfigApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'Build sem configuração de ativação (APPS_SCRIPT_URL).\n'
              'Gere o app novamente com ./scripts/build_release.ps1.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18),
            ),
          ),
        ),
      ),
    );
  }
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
        ChangeNotifierProvider(create: (_) => VodDetailsProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        // [TESTE] Na raiz do app (junto de SettingsProvider), não mais só
        // dentro da árvore local da HomeScreen -- ver comentário em
        // ContentProvider.updateApiService pro porquê (redesenho do hub:
        // toda tela hoje é uma rota IRMÃ de qualquer outra, não descendente,
        // então um provider só acessível "dentro" de uma tela específica
        // fica inacessível pras que são empurradas por cima dela).
        ChangeNotifierProvider(create: (_) => ContinueWatchingProvider()..load()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()..load()),
        // ContentProvider precisa do apiService (só existe depois do
        // login) -- ChangeNotifierProxyProvider recria a MESMA instância
        // (nunca perde categorias/streams já carregados) e só chama
        // updateApiService quando AuthProvider notifica uma mudança real
        // (login bem-sucedido, ou troca de servidor).
        ChangeNotifierProxyProvider<AuthProvider, ContentProvider>(
          create: (_) => ContentProvider(),
          update: (_, auth, previous) {
            final contentProvider = previous ?? ContentProvider();
            final apiService = auth.apiService;
            if (apiService != null) contentProvider.updateApiService(apiService);
            return contentProvider;
          },
        ),
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
