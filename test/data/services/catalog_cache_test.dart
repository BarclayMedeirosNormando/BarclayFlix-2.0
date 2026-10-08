import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptv_app/data/services/catalog_cache.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('catalog_cache_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('grava e lê de volta o mesmo corpo', () async {
    final cache = CatalogCache(directoryProvider: () async => dir);
    await cache.write('chave', '[{"a":1}]');

    final cached = await cache.read('chave');
    expect(cached, isNotNull);
    expect(cached!.body, '[{"a":1}]');
  });

  test('chave inexistente devolve null', () async {
    final cache = CatalogCache(directoryProvider: () async => dir);
    expect(await cache.read('nunca-gravada'), isNull);
  });

  test('chaves diferentes não se misturam e nenhum nome de arquivo expõe a chave', () async {
    final cache = CatalogCache(directoryProvider: () async => dir);
    await cache.write('http://srv|usuario|get_live_streams|1', 'A');
    await cache.write('http://srv|usuario|get_live_streams|2', 'B');

    expect((await cache.read('http://srv|usuario|get_live_streams|1'))!.body, 'A');
    expect((await cache.read('http://srv|usuario|get_live_streams|2'))!.body, 'B');
    for (final entity in dir.listSync()) {
      expect(entity.path.contains('usuario'), isFalse);
      expect(entity.path.contains('srv'), isFalse);
    }
  });

  test('isFresh respeita o TTL', () async {
    final cache = CatalogCache(directoryProvider: () async => dir, ttl: const Duration(hours: 6));
    await cache.write('k', 'x');
    final cached = (await cache.read('k'))!;

    expect(cached.isFresh(cache.ttl, cached.savedAt.add(const Duration(hours: 5))), isTrue);
    expect(cached.isFresh(cache.ttl, cached.savedAt.add(const Duration(hours: 7))), isFalse);
  });

  test('regravar a mesma chave substitui o conteúdo', () async {
    final cache = CatalogCache(directoryProvider: () async => dir);
    await cache.write('k', 'velho');
    await cache.write('k', 'novo');
    expect((await cache.read('k'))!.body, 'novo');
  });

  test('nunca lança quando a pasta de cache não está disponível', () async {
    final cache = CatalogCache(directoryProvider: () async => throw const FileSystemException('sem disco'));
    await cache.write('k', 'x');
    expect(await cache.read('k'), isNull);
  });
}
