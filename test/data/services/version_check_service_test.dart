import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:iptv_app/data/services/version_check_service.dart';

void main() {
  group('VersionCheckService.isNewerVersion', () {
    test('compara numericamente, não como texto', () {
      expect(VersionCheckService.isNewerVersion('2.10.0', '2.9.0'), isTrue);
      expect(VersionCheckService.isNewerVersion('2.9.0', '2.10.0'), isFalse);
    });

    test('igual não é mais novo; sufixo de build é ignorado', () {
      expect(VersionCheckService.isNewerVersion('2.5.1', '2.5.1+15'), isFalse);
      expect(VersionCheckService.isNewerVersion('2.5', '2.5.0'), isFalse);
      expect(VersionCheckService.isNewerVersion('2.5.2', '2.5.1+15'), isTrue);
    });

    test('texto ilegível nunca é considerado mais novo', () {
      expect(VersionCheckService.isNewerVersion('abc', '2.5.1'), isFalse);
      expect(VersionCheckService.isNewerVersion('', '2.5.1'), isFalse);
      expect(VersionCheckService.isNewerVersion('2.6.0', 'abc'), isFalse);
    });
  });

  group('VersionCheckService.checkForUpdate', () {
    const endpoint = 'https://script.example.com/macros/s/ID/exec';

    VersionCheckService build(
      Future<http.Response> Function(http.Request) handler, {
      String installed = '2.5.1',
      String? platform = 'android',
      bool detectPlatform = false,
    }) {
      return VersionCheckService(
        client: MockClient(handler),
        installedVersion: () async => installed,
        platformName: platform,
        endpoint: endpoint,
        detectPlatform: detectPlatform,
      );
    }

    Future<http.Response> okBody(String version) async => http.Response(
          jsonEncode({
            'status': 'ok',
            'versaoMinima': version,
            'urlDownload': 'https://drive.example.com/arquivo',
            'changelog': 'Novidades',
          }),
          200,
        );

    test('versão da planilha maior: devolve o aviso com url e changelog', () async {
      late http.Request seen;
      final service = build((request) {
        seen = request;
        return okBody('2.6.0');
      });

      final update = await service.checkForUpdate();

      expect(update, isNotNull);
      expect(update!.latestVersion, '2.6.0');
      expect(update.downloadUrl, 'https://drive.example.com/arquivo');
      expect(update.changelog, 'Novidades');
      final sent = jsonDecode(seen.body) as Map;
      expect(sent['action'], 'check_version');
      expect(sent['plataforma'], 'android');
    });

    test('versão igual ou menor: sem aviso', () async {
      expect(await build((_) => okBody('2.5.1')).checkForUpdate(), isNull);
      expect(await build((_) => okBody('1.8.5')).checkForUpdate(), isNull);
    });

    test('segue o redirecionamento 302 do Apps Script', () async {
      final service = build((request) async {
        if (request.method == 'POST') {
          return http.Response('', 302, headers: {'location': 'https://script.googleusercontent.com/x'});
        }
        return okBody('3.0.0');
      });
      expect((await service.checkForUpdate())?.latestVersion, '3.0.0');
    });

    test('falhas nunca lançam e viram "sem aviso"', () async {
      expect(await build((_) async => throw Exception('sem rede')).checkForUpdate(), isNull);
      expect(await build((_) async => http.Response('', 500)).checkForUpdate(), isNull);
      expect(await build((_) async => http.Response('não é json', 200)).checkForUpdate(), isNull);
      expect(
        await build((_) async => http.Response(jsonEncode({'status': 'erro'}), 200)).checkForUpdate(),
        isNull,
      );
    });

    test('plataforma não suportada: nem chama a rede', () async {
      final service = build(
        (_) async => throw StateError('não deveria chamar a rede'),
        platform: null,
      );
      expect(await service.checkForUpdate(), isNull);
    });
  });
}
