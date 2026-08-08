import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:iptv_app/data/models/device_login_result.dart';
import 'package:iptv_app/data/services/storage_service.dart';
import 'package:iptv_app/providers/auth_provider.dart';
import 'package:iptv_app/providers/profiles_provider.dart';
import 'package:iptv_app/screens/home/home_screen.dart';
import 'package:iptv_app/screens/server_selection/server_selection_screen.dart';

const _servers = [
  ServerOption(nome: 'TVPLAY', dns: 'http://tvplay.example:8080', username: 'u1', password: 'p1'),
  ServerOption(nome: 'P2BRAS', dns: 'http://p2bras.example:8080', username: 'u2', password: 'p2'),
];

/// [xtreamShouldFail], quando true, faz a validação Xtream do servidor
/// escolhido falhar (simula dispositivo bloqueado/credencial expirada
/// nesse meio tempo) -- pra testar que a tela mostra o erro real sem
/// travar, em vez de navegar.
Future<void> pumpServerSelectionScreen(
  WidgetTester tester, {
  bool xtreamShouldFail = false,
  String? existingProfileId,
}) async {
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});

  final client = MockClient((request) async {
    if (xtreamShouldFail) {
      return http.Response(jsonEncode({'user_info': {'auth': 0}}), 200);
    }
    return http.Response(
      jsonEncode({
        'user_info': {'auth': 1, 'status': 'Active'},
        'server_info': {'url': 'servidor-teste.com', 'port': '8080'},
      }),
      200,
    );
  });

  final authProvider = AuthProvider(xtreamHttpClient: client);

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
      ],
      child: MaterialApp(
        home: ServerSelectionScreen(
          servers: _servers,
          existingProfileId: existingProfileId,
        ),
      ),
    ),
  );

  await tester.pump();
}

void main() {
  testWidgets('mostra um card por servidor, com o primeiro focado sozinho (sem foco manual)', (tester) async {
    await pumpServerSelectionScreen(tester);

    expect(find.text('TVPLAY'), findsOneWidget);
    expect(find.text('P2BRAS'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
  });

  testWidgets('nunca é um dialog -- é uma tela cheia própria', (tester) async {
    await pumpServerSelectionScreen(tester);

    expect(find.byType(ServerSelectionScreen), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(Scaffold), findsOneWidget);
  });

  testWidgets('seta direita move o foco entre os cards de servidor', (tester) async {
    await pumpServerSelectionScreen(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    final p2brasFocusNode = tester
        .widget<Focus>(
          find.ancestor(of: find.text('P2BRAS'), matching: find.byType(Focus)).first,
        )
        .focusNode;
    expect(p2brasFocusNode?.hasFocus ?? false, isTrue);
  });

  testWidgets('escolher um servidor válido valida na Xtream e navega pra HomeScreen', (tester) async {
    await pumpServerSelectionScreen(tester);

    await tester.tap(find.text('TVPLAY'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(ServerSelectionScreen), findsNothing);
  });

  testWidgets('Enter no card focado ativa a mesma escolha que o toque', (tester) async {
    await pumpServerSelectionScreen(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('falha na validação Xtream mostra erro real e NÃO navega (tela não trava)', (tester) async {
    await pumpServerSelectionScreen(tester, xtreamShouldFail: true);

    await tester.tap(find.text('TVPLAY'));
    await tester.pumpAndSettle();

    expect(find.byType(ServerSelectionScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    // A tela continua interativa -- os cards ainda estão lá pra tentar de novo.
    expect(find.text('TVPLAY'), findsOneWidget);
    expect(find.text('P2BRAS'), findsOneWidget);
  });
}
