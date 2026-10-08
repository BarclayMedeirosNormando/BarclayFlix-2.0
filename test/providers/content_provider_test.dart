import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:iptv_app/data/services/xtream_api_service.dart';
import 'package:iptv_app/providers/content_provider.dart';

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

void main() {
  group('updateApiService', () {
    test('trocar pra uma instância DIFERENTE de XtreamApiService reseta categorias/streams em cache', () async {
      final serverA = XtreamApiService(
        dns: 'http://servidor-a.example:8080',
        username: 'user_a',
        password: 'pass_a',
        client: MockClient((request) async {
          final action = request.url.queryParameters['action'];
          if (action == 'get_live_categories') {
            return _json([
              {'category_id': '1', 'category_name': 'Categoria A', 'parent_id': 0},
            ]);
          }
          if (action == 'get_live_streams') {
            return _json([
              {'stream_id': 1, 'name': 'Canal A', 'category_id': '1'},
            ]);
          }
          return http.Response('Not Found', 404);
        }),
      );

      final serverB = XtreamApiService(
        dns: 'http://servidor-b.example:8080',
        username: 'user_b',
        password: 'pass_b',
        client: MockClient((request) async {
          final action = request.url.queryParameters['action'];
          // Servidor B não tem NENHUMA categoria de live -- simula um
          // painel diferente, sem as categorias do servidor A.
          if (action == 'get_live_categories') return _json([]);
          return http.Response('Not Found', 404);
        }),
      );

      final provider = ContentProvider(apiService: serverA);
      await provider.loadCategories(ContentType.live);

      expect(provider.live.categoriesStatus, LoadStatus.success);
      expect(provider.categoriesFor(ContentType.live).any((c) => c.name == 'Categoria A'), isTrue);
      expect(
        provider.live.streams,
        isEmpty,
        reason: 'carregar as categorias NÃO baixa nenhum stream sozinho (nada de "Todos" automática)',
      );
      expect(provider.live.selectedCategoryId, isNull);

      await provider.selectCategory(ContentType.live, ContentProvider.allCategoriesId);
      expect(provider.live.streams, isNotEmpty, reason: 'escolher "Todos" explicitamente carrega os streams de A');

      // Troca de servidor -- MESMO objeto ContentProvider (agora provider
      // de raiz do app, ver main.dart), mas outro XtreamApiService.
      provider.updateApiService(serverB);

      expect(
        provider.live.categoriesStatus,
        LoadStatus.idle,
        reason: 'trocar de servidor precisa resetar o status, senão loadCategories nunca busca de novo',
      );
      expect(provider.categoriesFor(ContentType.live), isEmpty);
      expect(provider.live.streams, isEmpty);
      expect(provider.live.selectedCategoryId, isNull);

      // Confirma que dá pra carregar de novo (contra o servidor B) depois
      // do reset -- sem o fix, `categoriesStatus == success` de A
      // bloquearia esta chamada de bater na rede de novo.
      await provider.loadCategories(ContentType.live);
      expect(provider.live.categoriesStatus, LoadStatus.success);
      // "Todos" é sempre injetada (synthetic, ver ContentProvider._withAllCategory)
      // mesmo sem nenhuma categoria real -- o que importa aqui é que
      // "Categoria A" (do servidor anterior) NÃO sobrou.
      expect(
        provider.categoriesFor(ContentType.live).any((c) => c.name == 'Categoria A'),
        isFalse,
        reason: 'categoria do servidor A não pode sobreviver à troca pro servidor B',
      );
    });

    test('reabrir o MESMO servidor (nova instância, mesmas credenciais) também reseta', () async {
      final handler = MockClient((request) async {
        if (request.url.queryParameters['action'] == 'get_live_categories') {
          return _json([
            {'category_id': '1', 'category_name': 'Categoria', 'parent_id': 0},
          ]);
        }
        if (request.url.queryParameters['action'] == 'get_live_streams') return _json([]);
        return http.Response('Not Found', 404);
      });

      final firstLogin = XtreamApiService(dns: 'http://servidor.example:8080', username: 'u', password: 'p', client: handler);
      final provider = ContentProvider(apiService: firstLogin);
      await provider.loadCategories(ContentType.live);
      expect(provider.live.categoriesStatus, LoadStatus.success);

      // Mesmas credenciais, mas uma instância NOVA (equivalente a relogar) --
      // `identical` deve tratar como troca mesmo assim.
      final secondLogin = XtreamApiService(dns: 'http://servidor.example:8080', username: 'u', password: 'p', client: handler);
      provider.updateApiService(secondLogin);

      expect(provider.live.categoriesStatus, LoadStatus.idle);
    });

    test('primeira vez que apiService é setado (login inicial) NÃO reseta nada -- não há nada pra resetar ainda',
        () async {
      final provider = ContentProvider();
      expect(provider.live.categoriesStatus, LoadStatus.idle);

      provider.updateApiService(
        XtreamApiService(dns: 'http://servidor.example:8080', username: 'u', password: 'p', client: MockClient((_) async => http.Response('[]', 200))),
      );

      // Ainda idle -- não deveria ter disparado notifyListeners() nem
      // mexido em nada, só guardado a referência.
      expect(provider.live.categoriesStatus, LoadStatus.idle);
    });
  });
}
