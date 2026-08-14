import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:iptv_app/core/constants/app_constants.dart';
import 'package:iptv_app/data/models/saved_profile.dart';
import 'package:iptv_app/data/services/device_auth_service.dart';
import 'package:iptv_app/data/services/storage_service.dart';
import 'package:iptv_app/providers/auth_provider.dart';
import 'package:iptv_app/providers/profiles_provider.dart';
import 'package:iptv_app/providers/settings_provider.dart';
import 'package:iptv_app/screens/activation/activation_screen.dart';
import 'package:iptv_app/screens/home/home_screen.dart';
import 'package:iptv_app/screens/splash/splash_screen.dart';

const _testDns = 'http://servidor-teste.com:8080';
const _testUser = 'usuario_valido';
const _testPass = 'senha_valida';

Future<http.Response> _json(Object body) async => http.Response(jsonEncode(body), 200);

/// Handler HTTP único pra ativação de dispositivo (Apps Script) e pro
/// `player_api.php` da Xtream — mesmo padrão de
/// `test/providers/profiles_provider_test.dart`. [errorCodeForDevice]/
/// [errorMessageForDevice] simulam a ativação recusando o dispositivo já
/// salvo (ex: revogado depois de ativado).
Future<http.Response> Function(http.Request) _buildHandler({
  String? errorCodeForDevice,
  String? errorMessageForDevice,
}) {
  return (request) async {
    // Checa a rota Xtream PRIMEIRO, por um sufixo de path especifico
    // (`/player_api.php`) -- nunca por `AppConstants.deviceAuthUrl`, que em
    // `flutter test` (sem `--dart-define=APPS_SCRIPT_URL=...`) resolve pra
    // string vazia, e `startsWith('')` bateria com QUALQUER URL, inclusive
    // a da Xtream (mesma correção em profiles_provider_test.dart e
    // activation_screen_test.dart). Em produção nunca acontece: as duas
    // URLs são hosts sempre distintos.
    if (request.url.path.endsWith(AppConstants.xtreamPlayerApiPath)) {
      return _json({
        'user_info': {'auth': 1, 'status': 'Active'},
        'server_info': {'url': 'servidor-teste.com', 'port': '8080'},
      });
    }

    if (request.url.toString().startsWith(AppConstants.deviceAuthUrl)) {
      if (errorCodeForDevice != null) {
        return _json({
          'status': 'erro',
          'codigo': errorCodeForDevice,
          'mensagem': errorMessageForDevice ?? 'Erro de ativação.',
        });
      }
      return _json({
        'status': 'ok',
        'nomeCliente': 'Cliente Teste',
        'servidores': [
          {'nome': 'Meu Servidor', 'dns': _testDns, 'username': _testUser, 'password': _testPass},
        ],
      });
    }

    return http.Response('Not Found', 404);
  };
}

/// Monta a SplashScreen de verdade (com [ProfilesProvider]/[AuthProvider]
/// reais, só a rede é falsa) -- [seed], se informado, pré-popula o perfil
/// salvo (mesmo formato de `flutter_secure_storage`) ANTES do app abrir, pra
/// simular "este dispositivo já tinha sido ativado antes".
Future<void> pumpSplashScreen(
  WidgetTester tester, {
  SavedProfile? seed,
  String? errorCodeForDevice,
  String? errorMessageForDevice,
}) async {
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
  final storageService = StorageService(storage: const FlutterSecureStorage());
  if (seed != null) {
    await storageService.addProfile(seed);
  }

  final client = MockClient(_buildHandler(
    errorCodeForDevice: errorCodeForDevice,
    errorMessageForDevice: errorMessageForDevice,
  ));
  final authProvider = AuthProvider(
    deviceAuthService: DeviceAuthService(client: client),
    xtreamHttpClient: client,
  );

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
        ChangeNotifierProvider<ProfilesProvider>(
          create: (_) => ProfilesProvider(authProvider: authProvider, storageService: storageService),
        ),
        // HomeScreen (alcançável daqui quando já existe perfil salvo) lê
        // SettingsProvider assim que renderiza.
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(storageService: storageService)..load(),
        ),
      ],
      child: const MaterialApp(home: SplashScreen()),
    ),
  );

  await tester.pumpAndSettle();
}

SavedProfile _savedProfile() {
  return const SavedProfile(
    id: 'profile_1',
    nomeExibicao: 'Meu Servidor',
    xtreamUsername: _testUser,
    xtreamPassword: _testPass,
    dns: _testDns,
  );
}

void main() {
  testWidgets('sem perfil salvo: mostra ActivationScreen (sem erro nenhum)', (tester) async {
    await pumpSplashScreen(tester);

    expect(find.byType(ActivationScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byType(SplashScreen), findsNothing);
  });

  testWidgets('perfil salvo, dispositivo ainda ativado: pula direto pra HomeScreen, sem mostrar ActivationScreen', (
    tester,
  ) async {
    await pumpSplashScreen(tester, seed: _savedProfile());

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(ActivationScreen), findsNothing);
    expect(find.byType(SplashScreen), findsNothing);
  });

  testWidgets(
    'perfil salvo com dispositivo inativo: NÃO trava em silêncio -- vai pra ActivationScreen já mostrando a mensagem real',
    (tester) async {
      await pumpSplashScreen(
        tester,
        seed: _savedProfile(),
        errorCodeForDevice: 'inativo',
        errorMessageForDevice: 'Sua assinatura está inativa.',
      );

      expect(find.byType(ActivationScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      // A mensagem aparece IMEDIATAMENTE, sem precisar de nenhum tick do
      // timer -- prova que não é o estado de espera normal nem uma tela em
      // branco.
      expect(find.text('Sua assinatura está inativa.'), findsOneWidget);
    },
  );

  testWidgets(
    'perfil salvo com dispositivo expirado: vai pra ActivationScreen já mostrando a mensagem real',
    (tester) async {
      await pumpSplashScreen(
        tester,
        seed: _savedProfile(),
        errorCodeForDevice: 'expirado',
        errorMessageForDevice: 'Sua assinatura expirou.',
      );

      expect(find.byType(ActivationScreen), findsOneWidget);
      expect(find.text('Sua assinatura expirou.'), findsOneWidget);
    },
  );

  testWidgets(
    'perfil salvo com servidor removido pelo admin: vai pra ActivationScreen sem erro alarmante (estado de espera normal)',
    (tester) async {
      await pumpSplashScreen(
        tester,
        seed: _savedProfile(),
        errorCodeForDevice: 'nao_registrado',
        errorMessageForDevice: 'Dispositivo ainda não cadastrado.',
      );

      expect(find.byType(ActivationScreen), findsOneWidget);
      // "nao_registrado" nunca é bloqueante -- não deve aparecer como erro
      // em destaque na tela, só o código de ativação + espera silenciosa.
      expect(find.text('Dispositivo ainda não cadastrado.'), findsNothing);
    },
  );
}
