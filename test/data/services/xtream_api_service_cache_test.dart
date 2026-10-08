import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:iptv_app/core/errors/app_exceptions.dart';
import 'package:iptv_app/data/services/catalog_cache.dart';
import 'package:iptv_app/data/services/xtream_api_service.dart';

const _dns = 'http://servidor-teste.com:8080';

XtreamApiService _service(http.Client client, CatalogCache? cache) {
  return XtreamApiService(dns: _dns, username: 'u', password: 'p', client: client, cache: cache);
}

http.Response _liveBody(int count) {
  final list = [
    for (var i = 0; i < count; i++)
      {'stream_id': i, 'name': 'Canal $i', 'category_id': '1', 'stream_icon': 'http://img.example/${'x' * 30}$i.png'},
  ];
  return http.Response(jsonEncode(list), 200);
}

/// A gravação do cache é "dispara e esquece" -- espera o arquivo aparecer.
Future<void> _waitForCacheFile(Directory dir) async {
  for (var i = 0; i < 200; i++) {
    final has = dir.existsSync() && dir.listSync().any((e) => e.path.endsWith('.json'));
    if (has) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('arquivo de cache nunca apareceu');
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('xtream_cache_test');
  });

  tearDown(() async {
    // A gravação do cache é "dispara e esquece": no Windows o arquivo ainda
    // pode estar aberto quando o teste termina, e apagar a pasta falha
    // (errno 32). Tenta de novo por um instante; se mesmo assim não der, deixa
    // a pasta temporária pro sistema limpar -- nunca reprova o teste por isso.
    for (var i = 0; i < 40; i++) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  });

  CatalogCache newCache({DateTime Function()? now}) =>
      CatalogCache(directoryProvider: () async => dir, ttl: const Duration(hours: 6), now: now);

  test('segunda chamada dentro do TTL sai do disco, sem rede', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return _liveBody(3);
    });

    final first = await _service(client, newCache()).getLiveStreams(categoryId: '1');
    await _waitForCacheFile(dir);
    final second = await _service(client, newCache()).getLiveStreams(categoryId: '1');

    expect(first.length, 3);
    expect(second.length, 3);
    expect(requests, 1);
  });

  test('forceRefresh ignora o cache e vai à rede', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return _liveBody(2);
    });

    await _service(client, newCache()).getLiveStreams(categoryId: '1');
    await _waitForCacheFile(dir);
    await _service(client, newCache()).getLiveStreams(categoryId: '1', forceRefresh: true);

    expect(requests, 2);
  });

  test('cache vencido (passou do TTL) volta a buscar na rede', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return _liveBody(2);
    });

    await _service(client, newCache()).getLiveStreams(categoryId: '1');
    await _waitForCacheFile(dir);
    final later = DateTime.now().add(const Duration(hours: 7));
    await _service(client, newCache(now: () => later)).getLiveStreams(categoryId: '1');

    expect(requests, 2);
  });

  test('rede falhou e há cache vencido: devolve o cache (modo offline)', () async {
    await _service(MockClient((_) async => _liveBody(4)), newCache()).getLiveStreams(categoryId: '1');
    await _waitForCacheFile(dir);

    final later = DateTime.now().add(const Duration(hours: 7));
    final offline = _service(MockClient((_) async => throw const SocketException('sem rede')), newCache(now: () => later));
    final result = await offline.getLiveStreams(categoryId: '1');

    expect(result.length, 4);
  });

  test('forceRefresh com a rede fora do ar mostra o erro (não esconde atrás do cache)', () async {
    await _service(MockClient((_) async => _liveBody(4)), newCache()).getLiveStreams(categoryId: '1');
    await _waitForCacheFile(dir);

    final offline = _service(MockClient((_) async => throw const SocketException('sem rede')), newCache());
    expect(
      () => offline.getLiveStreams(categoryId: '1', forceRefresh: true),
      throwsA(isA<XtreamApiException>()),
    );
  });

  test('resposta inválida NÃO é gravada no cache', () async {
    final client = MockClient((_) async => http.Response('isto não é json', 200));
    final service = _service(client, newCache());

    await expectLater(service.getLiveStreams(categoryId: '1'), throwsA(isA<XtreamApiException>()));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final files = dir.existsSync() ? dir.listSync().where((e) => e.path.endsWith('.json')) : const [];
    expect(files, isEmpty);
  });

  test('categorias diferentes têm caches independentes', () async {
    final seen = <String?>[];
    final client = MockClient((request) async {
      seen.add(request.url.queryParameters['category_id']);
      return _liveBody(1);
    });
    final service = _service(client, newCache());

    await service.getLiveStreams(categoryId: '1');
    await service.getLiveStreams(categoryId: '2');

    expect(seen, ['1', '2']);
  });

  test('catálogo grande (acima do limite) é decodificado em isolate e volta completo', () async {
    final client = MockClient((_) async => _liveBody(3000));
    final result = await _service(client, null).getLiveStreams();

    expect(result.length, 3000);
    expect(result.first.name, 'Canal 0');
    expect(result.last.name, 'Canal 2999');
  });

  test('sem cache configurado, o comportamento é o antigo (sempre rede)', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return _liveBody(1);
    });
    final service = _service(client, null);

    await service.getLiveStreams(categoryId: '1');
    await service.getLiveStreams(categoryId: '1');

    expect(requests, 2);
  });
}
