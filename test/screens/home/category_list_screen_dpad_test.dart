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
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iptv_app/data/services/storage_service.dart';
import 'package:iptv_app/data/services/xtream_api_service.dart';
import 'package:iptv_app/providers/auth_provider.dart';
import 'package:iptv_app/providers/content_provider.dart';
import 'package:iptv_app/providers/favorites_provider.dart';
import 'package:iptv_app/providers/settings_provider.dart';
import 'package:iptv_app/screens/home/category_list_screen.dart';
import 'package:iptv_app/screens/home/live_channels_screen.dart';

bool isFocused(WidgetTester tester, Finder finder) => Focus.of(tester.element(finder)).hasFocus;

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

Future<void> pumpCategoryList(WidgetTester tester) async {
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
  SharedPreferences.setMockInitialValues({});

  final client = MockClient((request) async {
    final action = request.url.queryParameters['action'];
    switch (action) {
      case 'get_live_categories':
        return _json([
          {'category_id': '1', 'category_name': 'Esportes', 'parent_id': 0},
          {'category_id': '2', 'category_name': 'Notícias', 'parent_id': 0},
        ]);
      case 'get_live_streams':
        return _json([]);
      default:
        return http.Response('Not Found', 404);
    }
  });

  final apiService = XtreamApiService(dns: 'http://servidor-teste.com:8080', username: 'u', password: 'p', client: client);
  final authProvider = AuthProvider(apiService: apiService);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
        ChangeNotifierProvider<ContentProvider>(create: (_) => ContentProvider(apiService: apiService)),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(storageService: StorageService(storage: const FlutterSecureStorage()))..load(),
        ),
        ChangeNotifierProvider<FavoritesProvider>(
          create: (_) => FavoritesProvider(storageService: StorageService(storage: const FlutterSecureStorage()))..load(),
        ),
      ],
      child: const MaterialApp(home: CategoryListScreen(type: ContentType.live)),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('abre com "Todos" já focado, alcança "Esportes" pela seta, e Enter abre a lista de canais',
      (tester) async {
    await pumpCategoryList(tester);

    expect(find.text('Todos'), findsOneWidget);
    expect(find.text('Esportes'), findsOneWidget);
    expect(find.text('Notícias'), findsOneWidget);

    // Sem nenhum requestFocus() manual antes desta linha -- é exatamente
    // essa ausência que reproduziria o bug de foco preso já corrigido em
    // settings_screen.dart (Focus(autofocus, skipTraversal) vazio por
    // fora), agora evitado de propósito nesta tela desde o início.
    expect(isFocused(tester, find.text('Todos')), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(isFocused(tester, find.text('Esportes')), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(LiveChannelsScreen), findsOneWidget);
    final screen = tester.widget<LiveChannelsScreen>(find.byType(LiveChannelsScreen));
    expect(screen.categoryId, '1');
    expect(screen.categoryName, 'Esportes');
  });

  testWidgets('Escape volta pra tela anterior', (tester) async {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    SharedPreferences.setMockInitialValues({});

    final client = MockClient((request) async {
      if (request.url.queryParameters['action'] == 'get_live_categories') {
        return _json([
          {'category_id': '1', 'category_name': 'Esportes', 'parent_id': 0},
        ]);
      }
      return _json([]);
    });
    final apiService =
        XtreamApiService(dns: 'http://servidor-teste.com:8080', username: 'u', password: 'p', client: client);
    final authProvider = AuthProvider(apiService: apiService);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<ContentProvider>(create: (_) => ContentProvider(apiService: apiService)),
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) =>
                SettingsProvider(storageService: StorageService(storage: const FlutterSecureStorage()))..load(),
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CategoryListScreen(type: ContentType.live)),
              ),
              child: const Text('Abrir Categorias'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Abrir Categorias'));
    await tester.pumpAndSettle();
    expect(find.byType(CategoryListScreen), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(CategoryListScreen), findsNothing);
    expect(find.text('Abrir Categorias'), findsOneWidget);
  });
}
