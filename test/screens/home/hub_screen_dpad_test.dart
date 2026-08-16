import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iptv_app/data/services/storage_service.dart';
import 'package:iptv_app/data/services/xtream_api_service.dart';
import 'package:iptv_app/providers/auth_provider.dart';
import 'package:iptv_app/providers/content_provider.dart';
import 'package:iptv_app/providers/continue_watching_provider.dart';
import 'package:iptv_app/providers/favorites_provider.dart';
import 'package:iptv_app/providers/profiles_provider.dart';
import 'package:iptv_app/providers/settings_provider.dart';
import 'package:iptv_app/screens/home/category_list_screen.dart';
import 'package:iptv_app/screens/home/continue_watching_screen.dart';
import 'package:iptv_app/screens/home/home_screen.dart';
import 'package:iptv_app/screens/settings/settings_screen.dart';

/// Mesmo padrão usado em player_screen_dpad_test.dart/settings_screen_dpad_test.dart:
/// [Focus.of] busca o FocusNode do ANCESTRAL mais próximo a partir do
/// contexto informado, então os finders sempre apontam pra algo DENTRO do
/// widget interativo real, nunca pro DpadFocusHighlight que o envolve por
/// fora.
bool isFocused(WidgetTester tester, Finder finder) => Focus.of(tester.element(finder)).hasFocus;

Future<void> pumpHub(WidgetTester tester) async {
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
  SharedPreferences.setMockInitialValues({});

  final client = MockClient((request) async => http.Response('{}', 200));
  final apiService =
      XtreamApiService(dns: 'http://servidor-teste.com:8080', username: 'u', password: 'p', client: client);
  final authProvider = AuthProvider(apiService: apiService);

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
        // Mesmo nível do app de verdade (ver main.dart) -- toda tela
        // alcançável a partir do hub é uma rota IRMÃ dele, não descendente,
        // então esses 3 providers precisam estar ACIMA de HomeScreen, não
        // dentro dela (ver ContentProvider.updateApiService).
        ChangeNotifierProvider<ContentProvider>(create: (_) => ContentProvider(apiService: apiService)),
        ChangeNotifierProvider<ContinueWatchingProvider>(create: (_) => ContinueWatchingProvider()..load()),
        ChangeNotifierProvider<FavoritesProvider>(create: (_) => FavoritesProvider()..load()),
        ChangeNotifierProvider<SettingsProvider>(create: (_) => SettingsProvider()..load()),
      ],
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('abre com o card "TV Ao Vivo" já focado, sem nenhum requestFocus() manual', (tester) async {
    await pumpHub(tester);

    expect(find.text('TV Ao Vivo'), findsOneWidget);
    expect(find.text('Filmes'), findsOneWidget);
    expect(find.text('Séries'), findsOneWidget);
    expect(find.text('Continuar Assistindo'), findsOneWidget);
    expect(find.text('Configurações'), findsOneWidget);

    expect(isFocused(tester, find.text('TV Ao Vivo')), isTrue);
  });

  testWidgets('seta pra baixo/direita percorre os cards; Enter ativa o card focado', (tester) async {
    await pumpHub(tester);

    expect(isFocused(tester, find.text('TV Ao Vivo')), isTrue);

    // O grid tem `maxCrossAxisExtent: 220` numa janela de teste larga o
    // bastante pra caber mais de uma coluna -- ArrowDown deveria mesmo
    // assim alcançar outro card (geometria vertical), sem travar no
    // primeiro (mesma classe de bug já corrigida em settings_screen.dart:
    // confirma que NENHUM wrapper Focus(skipTraversal) está prendendo o
    // foco aqui).
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(isFocused(tester, find.text('TV Ao Vivo')), isFalse);

    // Navega até "Configurações" pra confirmar que o Enter de fato ativa o
    // card focado (evita depender de qual card específico o ArrowDown
    // acima alcançou, que depende só da geometria da grade).
    for (var i = 0; i < 6 && !isFocused(tester, find.text('Configurações')); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(isFocused(tester, find.text('Configurações')), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('card "TV Ao Vivo" abre CategoryListScreen(type: live)', (tester) async {
    await pumpHub(tester);

    await tester.tap(find.text('TV Ao Vivo'));
    await tester.pumpAndSettle();

    final screen = tester.widget<CategoryListScreen>(find.byType(CategoryListScreen));
    expect(screen.type.name, 'live');
  });

  testWidgets('card "Continuar Assistindo" abre ContinueWatchingScreen', (tester) async {
    await pumpHub(tester);

    await tester.tap(find.text('Continuar Assistindo'));
    await tester.pumpAndSettle();

    expect(find.byType(ContinueWatchingScreen), findsOneWidget);
  });
}
