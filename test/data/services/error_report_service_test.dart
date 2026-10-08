import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:iptv_app/data/services/error_report_service.dart';

const _endpoint = 'https://script.example.com/macros/s/ID/exec';

void main() {
  group('ErrorReportService.sanitize', () {
    test('URL de stream vira só host:porta (nunca usuário/senha do caminho)', () {
      final out = ErrorReportService.sanitize(
        'Failed to open http://dns.example.com:8080/live/meuUsuario/minhaSenha/123.m3u8: timeout',
      );
      expect(out, 'Failed to open dns.example.com:8080: timeout');
      expect(out.contains('meuUsuario'), isFalse);
      expect(out.contains('minhaSenha'), isFalse);
    });

    test('URL de player_api (credenciais na query) também some', () {
      final out = ErrorReportService.sanitize(
        'GET https://srv.example.com/player_api.php?username=joao&password=segredo&action=get_live_streams falhou',
      );
      expect(out, 'GET srv.example.com falhou');
      expect(out.contains('joao'), isFalse);
      expect(out.contains('segredo'), isFalse);
    });

    test('username=/password= soltos no texto são mascarados', () {
      final out = ErrorReportService.sanitize('erro username=joao&password=segredo fim');
      expect(out.contains('joao'), isFalse);
      expect(out.contains('segredo'), isFalse);
      expect(out.contains('username=***'), isTrue);
      expect(out.contains('password=***'), isTrue);
    });

    test('quebras de linha viram espaço e o texto é cortado em 300', () {
      expect(ErrorReportService.sanitize('a\n\n  b\tc'), 'a b c');
      expect(ErrorReportService.sanitize('x' * 1000).length, 300);
    });

    test('hostOf nunca expõe o caminho e aceita lixo', () {
      expect(ErrorReportService.hostOf('http://dns.example.com:8080/live/u/p/1.ts'), 'dns.example.com:8080');
      expect(ErrorReportService.hostOf('https://dns.example.com/x'), 'dns.example.com');
      expect(ErrorReportService.hostOf(null), 'desconhecido');
      expect(ErrorReportService.hostOf('isso não é url'), 'desconhecido');
    });
  });

  group('ErrorReportService.reportAndWait', () {
    late List<Map<String, dynamic>> sent;
    late DateTime clock;

    ErrorReportService build({
      String endpoint = _endpoint,
      String? platform = 'windows',
      int maxPerSession = 15,
      Future<http.Response> Function(http.Request)? handler,
    }) {
      return ErrorReportService(
        client: MockClient(handler ??
            (request) async {
              sent.add(jsonDecode(request.body) as Map<String, dynamic>);
              return http.Response('{"status":"ok"}', 200);
            }),
        deviceId: () async => 'a3f921cd-1111-4222-8333-444455556666',
        appVersion: () async => '2.5.2',
        platformName: platform,
        detectPlatform: false,
        endpoint: endpoint,
        now: () => clock,
        maxPerSession: maxPerSession,
      );
    }

    setUp(() {
      sent = [];
      clock = DateTime(2026, 10, 8, 12);
    });

    test('envia o formato esperado pelo Apps Script', () async {
      await build().reportAndWait(ErrorCategory.catalogo, 'falhou em http://x.com:8080/a/b');

      expect(sent.length, 1);
      expect(sent.first['action'], 'log_error');
      expect(sent.first['deviceId'], 'a3f921cd-1111-4222-8333-444455556666');
      expect(sent.first['plataforma'], 'windows');
      expect(sent.first['versaoApp'], '2.5.2');
      expect(sent.first['categoria'], 'catalogo');
      expect(sent.first['mensagem'], 'falhou em x.com:8080');
    });

    test('mesma falha repetida dentro da janela é enviada só uma vez', () async {
      final service = build();
      await service.reportAndWait(ErrorCategory.reproducao, 'mesmo erro');
      await service.reportAndWait(ErrorCategory.reproducao, 'mesmo erro');
      expect(sent.length, 1);

      clock = clock.add(const Duration(minutes: 11));
      await service.reportAndWait(ErrorCategory.reproducao, 'mesmo erro');
      expect(sent.length, 2, reason: 'passou a janela de 10 min');
    });

    test('falhas diferentes passam, até o teto da sessão', () async {
      final service = build(maxPerSession: 3);
      for (var i = 0; i < 10; i++) {
        await service.reportAndWait(ErrorCategory.app, 'erro $i');
      }
      expect(sent.length, 3);
    });

    test('várias falhas simultâneas também respeitam o teto', () async {
      final service = build(maxPerSession: 2);
      await Future.wait([
        for (var i = 0; i < 6; i++) service.reportAndWait(ErrorCategory.app, 'erro $i'),
      ]);
      expect(sent.length, 2);
    });

    test('sem URL do Apps Script ou em plataforma não suportada: não envia nada', () async {
      await build(endpoint: '').reportAndWait(ErrorCategory.app, 'x');
      await build(platform: null).reportAndWait(ErrorCategory.app, 'x');
      expect(sent, isEmpty);
    });

    test('mensagem vazia não é enviada', () async {
      await build().reportAndWait(ErrorCategory.app, '   ');
      expect(sent, isEmpty);
    });

    test('nunca lança, mesmo com a rede fora do ar', () async {
      final service = build(handler: (_) async => throw Exception('sem rede'));
      await service.reportAndWait(ErrorCategory.app, 'x');
    });

    test('segue o redirecionamento 302 do Apps Script', () async {
      var gets = 0;
      final service = build(handler: (request) async {
        if (request.method == 'POST') {
          sent.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('', 302, headers: {'location': 'https://script.googleusercontent.com/x'});
        }
        gets++;
        return http.Response('{"status":"ok"}', 200);
      });
      await service.reportAndWait(ErrorCategory.app, 'x');
      expect(sent.length, 1);
      expect(gets, 1);
    });
  });
}
