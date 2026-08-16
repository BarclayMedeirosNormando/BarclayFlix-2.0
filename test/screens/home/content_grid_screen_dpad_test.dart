import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:iptv_app/providers/settings_provider.dart';
import 'package:iptv_app/providers/vod_details_provider.dart';
import 'package:iptv_app/screens/home/content_grid_screen.dart';
import 'package:iptv_app/screens/vod_details/vod_details_screen.dart';

const _testDns = 'http://servidor-teste.com:8080';
const _testUser = 'u';
const _testPass = 'p';

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

/// "Filme B" tem a nota mais alta de propósito -- vira o destaque
/// (FeaturedBanner, ver ContentGridScreen._buildVodGrid), então aparece
/// DUAS vezes na árvore (banner + grid). "Filme A" (a única usada nas
/// asserções `find.text(...)` abaixo, que esperam exatamente UM widget)
/// nunca é o destaque.
Future<http.Response> _vodStreamsHandler(http.Request request) async {
  if (request.url.queryParameters['action'] != 'get_vod_streams') {
    return http.Response('Not Found', 404);
  }
  return _json([
    {'stream_id': 1, 'name': 'Filme A', 'stream_icon': '', 'category_id': '10', 'container_extension': 'mp4', 'rating': '0'},
    {'stream_id': 2, 'name': 'Filme B', 'stream_icon': '', 'category_id': '10', 'container_extension': 'mp4', 'rating': '9.5'},
  ]);
}

bool isFocused(WidgetTester tester, Finder finder) => Focus.of(tester.element(finder)).hasFocus;

Future<void> pumpContentGridScreen(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});

  final apiService = XtreamApiService(dns: _testDns, username: _testUser, password: _testPass, client: MockClient(_vodStreamsHandler));
  final contentProvider = ContentProvider(apiService: apiService);
  await contentProvider.selectCategory(ContentType.vod, '10');

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider(apiService: apiService)),
        ChangeNotifierProvider<ContentProvider>.value(value: contentProvider),
        ChangeNotifierProvider<VodDetailsProvider>(create: (_) => VodDetailsProvider()),
        ChangeNotifierProvider<ContinueWatchingProvider>(
          create: (_) => ContinueWatchingProvider(storageService: StorageService()),
        ),
        ChangeNotifierProvider<FavoritesProvider>(create: (_) => FavoritesProvider(storageService: StorageService())),
        ChangeNotifierProvider<SettingsProvider>(create: (_) => SettingsProvider(storageService: StorageService())),
      ],
      child: const MaterialApp(
        home: ContentGridScreen(type: ContentType.vod, categoryId: '10', categoryName: 'Categoria Teste'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    // [TESTE] Regressão: PosterCard nunca teve autofoco nenhum antes desta
    // correção -- NENHUM grid de pôster (Filmes/Séries/Continuar
    // Assistindo) tinha ponto de partida pro D-Pad/Escape, e passou
    // despercebido justamente porque não existia teste de D-Pad cobrindo
    // este grid especificamente no redesenho.
    'abre com o primeiro card já focado, sem nenhum requestFocus() manual',
    (tester) async {
      await pumpContentGridScreen(tester);

      expect(isFocused(tester, find.text('Filme A')), isTrue);
    },
  );

  testWidgets('seta pra baixo/direita alcança o segundo card; Enter abre a ficha do filme', (tester) async {
    await pumpContentGridScreen(tester);

    expect(isFocused(tester, find.text('Filme A')), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    // Janela de teste padrão cabe mais de uma coluna -- seta direita deveria
    // sair do primeiro card (geometria horizontal).
    expect(isFocused(tester, find.text('Filme A')), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(VodDetailsScreen), findsOneWidget);
  });

  testWidgets('Escape volta pra tela anterior', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final apiService = XtreamApiService(dns: _testDns, username: _testUser, password: _testPass, client: MockClient(_vodStreamsHandler));
    final contentProvider = ContentProvider(apiService: apiService);
    await contentProvider.selectCategory(ContentType.vod, '10');

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider(apiService: apiService)),
        ChangeNotifierProvider<ContentProvider>.value(value: contentProvider),
        ChangeNotifierProvider<VodDetailsProvider>(create: (_) => VodDetailsProvider()),
          ChangeNotifierProvider<ContinueWatchingProvider>(
            create: (_) => ContinueWatchingProvider(storageService: StorageService()),
          ),
          ChangeNotifierProvider<FavoritesProvider>(create: (_) => FavoritesProvider(storageService: StorageService())),
          ChangeNotifierProvider<SettingsProvider>(create: (_) => SettingsProvider(storageService: StorageService())),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ContentGridScreen(type: ContentType.vod, categoryId: '10', categoryName: 'Categoria Teste'),
                ),
              ),
              child: const Text('Abrir Categoria'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Abrir Categoria'));
    await tester.pumpAndSettle();
    expect(find.byType(ContentGridScreen), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(ContentGridScreen), findsNothing);
    expect(find.text('Abrir Categoria'), findsOneWidget);
  });
}
