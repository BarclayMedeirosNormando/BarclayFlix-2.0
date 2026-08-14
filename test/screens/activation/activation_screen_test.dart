import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iptv_app/core/constants/app_constants.dart';
import 'package:iptv_app/data/services/device_auth_service.dart';
import 'package:iptv_app/data/services/storage_service.dart';
import 'package:iptv_app/providers/auth_provider.dart';
import 'package:iptv_app/providers/profiles_provider.dart';
import 'package:iptv_app/providers/settings_provider.dart';
import 'package:iptv_app/screens/activation/activation_screen.dart';
import 'package:iptv_app/screens/home/home_screen.dart';
import 'package:iptv_app/screens/server_selection/server_selection_screen.dart';

const _testDns = 'http://servidor-teste.com:8080';
const _testUser = 'usuario_valido';
const _testPass = 'senha_valida';

Future<http.Response> _json(Object body) async => http.Response(jsonEncode(body), 200);

/// Monta a ActivationScreen isolada com [client] como backend HTTP falso,
/// tanto pra ativação de dispositivo quanto pra Xtream (mesmo `http.Client`
/// pros dois, roteado pela URL de cada request, ver os outros arquivos de
/// teste deste fluxo).
Future<void> pumpActivationScreen(
  WidgetTester tester, {
  required http.Client client,
  String? initialErrorMessage,
  String? initialErrorCode,
}) async {
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
  SharedPreferences.setMockInitialValues({});

  final authProvider = AuthProvider(
    deviceAuthService: DeviceAuthService(client: client),
    xtreamHttpClient: client,
  );

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
        ChangeNotifierProvider<ProfilesProvider>(
          create: (_) => ProfilesProvider(
            authProvider: authProvider,
            storageService: StorageService(storage: const FlutterSecureStorage()),
          ),
        ),
        // HomeScreen (alcançável a partir daqui após ativação com sucesso)
        // lê SettingsProvider assim que renderiza (ver
        // _CategoriesSidebar/_LiveStreamsPanel/etc. em home_screen.dart).
        ChangeNotifierProvider<SettingsProvider>(create: (_) => SettingsProvider()..load()),
      ],
      child: MaterialApp(
        home: ActivationScreen(
          initialErrorMessage: initialErrorMessage,
          initialErrorCode: initialErrorCode,
        ),
      ),
    ),
  );

  // Deixa o deviceId assíncrono (DeviceIdService) resolver e o código
  // aparecer na tela.
  await tester.pump();
}

void main() {
  testWidgets('mostra o código do dispositivo formatado (curto, maiúsculo) e um botão de copiar', (tester) async {
    final client = MockClient((request) async => http.Response('Not Found', 404));
    await pumpActivationScreen(tester, client: client);

    final codeFinder = find.byWidgetPredicate(
      (w) => w is Text && RegExp(r'^[0-9A-F]{4}-[0-9A-F]{4}$').hasMatch(w.data ?? ''),
    );
    expect(codeFinder, findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Copiar código'), findsOneWidget);
    expect(find.text('Envie este código para ativar seu acesso'), findsOneWidget);
  });

  testWidgets('toca em copiar: mostra confirmação', (tester) async {
    final client = MockClient((request) async => http.Response('Not Found', 404));
    await pumpActivationScreen(tester, client: client);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Copiar código'));
    await tester.pump();

    expect(find.text('Código copiado!'), findsOneWidget);
  });

  testWidgets('dispositivo não registrado: continua tentando em silêncio, sem mostrar erro', (tester) async {
    var deviceCheckCalls = 0;
    final client = MockClient((request) async {
      if (request.url.toString().startsWith(AppConstants.deviceAuthUrl)) {
        deviceCheckCalls++;
        return _json({
          'status': 'erro',
          'codigo': 'nao_registrado',
          'mensagem': 'Dispositivo ainda não cadastrado.',
        });
      }
      return http.Response('Not Found', 404);
    });

    await pumpActivationScreen(tester, client: client);
    expect(deviceCheckCalls, 0, reason: 'não deve checar antes do primeiro tick do timer');

    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    expect(deviceCheckCalls, 1);
    expect(find.text('Dispositivo ainda não cadastrado.'), findsNothing);
    expect(find.byType(ActivationScreen), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(deviceCheckCalls, 2, reason: 'continua tentando periodicamente, sem alarmar');
  });

  testWidgets('dispositivo inativo: para de verificar e mostra a mensagem real do backend', (tester) async {
    var deviceCheckCalls = 0;
    final client = MockClient((request) async {
      if (request.url.toString().startsWith(AppConstants.deviceAuthUrl)) {
        deviceCheckCalls++;
        return _json({'status': 'erro', 'codigo': 'inativo', 'mensagem': 'Sua assinatura está inativa.'});
      }
      return http.Response('Not Found', 404);
    });

    await pumpActivationScreen(tester, client: client);

    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    expect(deviceCheckCalls, 1);
    expect(find.text('Sua assinatura está inativa.'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(deviceCheckCalls, 1, reason: 'timer deve ter sido cancelado após o código bloqueante');
  });

  testWidgets('dispositivo expirado: para de verificar e mostra a mensagem real do backend', (tester) async {
    final client = MockClient((request) async {
      if (request.url.toString().startsWith(AppConstants.deviceAuthUrl)) {
        return _json({'status': 'erro', 'codigo': 'expirado', 'mensagem': 'Sua assinatura expirou.'});
      }
      return http.Response('Not Found', 404);
    });

    await pumpActivationScreen(tester, client: client);

    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    expect(find.text('Sua assinatura expirou.'), findsOneWidget);
  });

  testWidgets(
    'código bloqueante já vindo da SplashScreen: mostra a mensagem na abertura, sem checar em segundo plano',
    (tester) async {
      var deviceCheckCalls = 0;
      final client = MockClient((request) async {
        if (request.url.toString().startsWith(AppConstants.deviceAuthUrl)) deviceCheckCalls++;
        return http.Response('Not Found', 404);
      });

      await pumpActivationScreen(
        tester,
        client: client,
        initialErrorMessage: 'Sua assinatura está inativa.',
        initialErrorCode: 'inativo',
      );

      expect(find.text('Sua assinatura está inativa.'), findsOneWidget);

      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(deviceCheckCalls, 0, reason: 'timer não deve nem começar quando já chega um erro bloqueante');
    },
  );

  testWidgets('sucesso com um servidor: valida a Xtream e navega direto pra HomeScreen', (tester) async {
    final client = MockClient((request) async {
      // Checa a rota Xtream PRIMEIRO, por um sufixo de path especifico
      // (`/player_api.php`) -- nunca por `AppConstants.deviceAuthUrl`, que
      // em `flutter test` (sem `--dart-define=APPS_SCRIPT_URL=...`) resolve
      // pra string vazia, e `startsWith('')` bateria com QUALQUER URL,
      // inclusive a da Xtream (ver mesma correção em
      // profiles_provider_test.dart). Em produção nunca acontece: as duas
      // URLs são hosts sempre distintos.
      if (request.url.path.endsWith(AppConstants.xtreamPlayerApiPath)) {
        final action = request.url.queryParameters['action'];
        if (action == null) {
          return _json({
            'user_info': {'auth': 1, 'status': 'Active'},
            'server_info': {'url': 'servidor-teste.com', 'port': '8080'},
          });
        }
        return _json(const []);
      }
      if (request.url.toString().startsWith(AppConstants.deviceAuthUrl)) {
        return _json({
          'status': 'ok',
          'nomeCliente': 'Cliente Teste',
          'servidores': [
            {'nome': 'Servidor Único', 'dns': _testDns, 'username': _testUser, 'password': _testPass},
          ],
        });
      }
      return http.Response('Not Found', 404);
    });

    await pumpActivationScreen(tester, client: client);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(ActivationScreen), findsNothing);
  });

  testWidgets('sucesso com múltiplos servidores: navega pra ServerSelectionScreen', (tester) async {
    final client = MockClient((request) async {
      if (request.url.toString().startsWith(AppConstants.deviceAuthUrl)) {
        return _json({
          'status': 'ok',
          'nomeCliente': 'Cliente Teste',
          'servidores': [
            {'nome': 'TVPLAY', 'dns': 'http://tvplay.example:8080', 'username': 'u1', 'password': 'p1'},
            {'nome': 'P2BRAS', 'dns': 'http://p2bras.example:8080', 'username': 'u2', 'password': 'p2'},
          ],
        });
      }
      return http.Response('Not Found', 404);
    });

    await pumpActivationScreen(tester, client: client);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(find.byType(ServerSelectionScreen), findsOneWidget);
    expect(find.text('TVPLAY'), findsOneWidget);
    expect(find.text('P2BRAS'), findsOneWidget);
    // nomeCliente do Master Login (ver mock acima) chega até o título da
    // ServerSelectionScreen, de ponta a ponta.
    expect(find.text('Bem-vindo, Cliente Teste'), findsOneWidget);
  });
}
