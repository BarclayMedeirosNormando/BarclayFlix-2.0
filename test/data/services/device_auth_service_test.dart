import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:iptv_app/core/constants/app_constants.dart';
import 'package:iptv_app/core/errors/app_exceptions.dart';
import 'package:iptv_app/data/services/device_auth_service.dart';

// Usa a mesma URL que o serviço real consulta (AppConstants.deviceAuthUrl,
// vinda de --dart-define/AppConfig) em vez de duplicar um valor aqui —
// assim o mock intercepta a chamada de verdade sem hardcodar URL nenhuma.
const _deviceAuthUrl = AppConstants.deviceAuthUrl;
const _redirectTarget = 'https://script.googleusercontent.com/macros/echo?fake=1';

/// Simula o comportamento REAL do Google Apps Script observado em produção
/// (ver histórico de diagnóstico): a URL `/exec` sempre responde 302 com
/// corpo VAZIO, redirecionando (header `location`) para uma URL de
/// `script.googleusercontent.com` -- é lá que mora o JSON de verdade.
http.Response _redirectResponse() => http.Response('', 302, headers: {'location': _redirectTarget});

void main() {
  test('check segue o redirecionamento 302 do Apps Script e devolve os servidores', () async {
    final client = MockClient((request) async {
      if (request.url.toString() == _deviceAuthUrl && request.method == 'POST') {
        return _redirectResponse();
      }
      if (request.url.toString() == _redirectTarget && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'status': 'ok',
            'nomeCliente': 'Cliente Teste',
            'servidores': [
              {'nome': 'Servidor 1', 'dns': 'http://servidor1.com:8080', 'username': 'u1', 'password': 'p1'},
            ],
          }),
          200,
        );
      }
      return http.Response('Not Found', 404);
    });

    final service = DeviceAuthService(client: client);
    final result = await service.check(deviceId: 'device-1');

    expect(result.nomeCliente, 'Cliente Teste');
    expect(result.servidores, hasLength(1));
    expect(result.servidores.first.nome, 'Servidor 1');
    expect(result.servidores.first.dns, 'http://servidor1.com:8080');
  });

  test('check segue o redirecionamento 302 e propaga a mensagem/código de erro do JSON final', () async {
    final client = MockClient((request) async {
      if (request.url.toString() == _deviceAuthUrl && request.method == 'POST') {
        return _redirectResponse();
      }
      if (request.url.toString() == _redirectTarget && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'status': 'erro',
            'codigo': 'nao_registrado',
            'mensagem': 'Dispositivo ainda não cadastrado. Aguarde.',
          }),
          200,
        );
      }
      return http.Response('Not Found', 404);
    });

    final service = DeviceAuthService(client: client);

    await expectLater(
      () => service.check(deviceId: 'device-1'),
      throwsA(
        isA<DeviceLoginException>()
            .having((e) => e.message, 'message', 'Dispositivo ainda não cadastrado. Aguarde.')
            .having((e) => e.code, 'code', 'nao_registrado'),
      ),
    );
  });

  test('check propaga o código "inativo"', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({'status': 'erro', 'codigo': 'inativo', 'mensagem': 'Sua assinatura está inativa.'}),
        200,
      );
    });

    final service = DeviceAuthService(client: client);

    await expectLater(
      () => service.check(deviceId: 'device-1'),
      throwsA(
        isA<DeviceLoginException>()
            .having((e) => e.message, 'message', 'Sua assinatura está inativa.')
            .having((e) => e.code, 'code', 'inativo'),
      ),
    );
  });

  test('check propaga o código "expirado"', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({'status': 'erro', 'codigo': 'expirado', 'mensagem': 'Sua assinatura expirou.'}),
        200,
      );
    });

    final service = DeviceAuthService(client: client);

    await expectLater(
      () => service.check(deviceId: 'device-1'),
      throwsA(
        isA<DeviceLoginException>()
            .having((e) => e.message, 'message', 'Sua assinatura expirou.')
            .having((e) => e.code, 'code', 'expirado'),
      ),
    );
  });

  test('check sem header location num 3xx cai na mensagem genérica (sem loop nem crash)', () async {
    final client = MockClient((request) async {
      return http.Response('', 302); // 3xx sem "location" nenhum.
    });

    final service = DeviceAuthService(client: client);

    await expectLater(
      () => service.check(deviceId: 'device-1'),
      throwsA(
        isA<DeviceLoginException>().having(
          (e) => e.message,
          'message',
          'Servidor de ativação indisponível. Tente novamente mais tarde.',
        ),
      ),
    );
  });

  test('check envia o deviceId no corpo da requisição, sem user/pass', () async {
    Map<String, dynamic>? sentBody;
    final client = MockClient((request) async {
      sentBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'status': 'ok',
          'nomeCliente': 'Cliente',
          'servidores': [
            {'nome': 'S', 'dns': 'http://s.com', 'username': 'u', 'password': 'p'},
          ],
        }),
        200,
      );
    });

    final service = DeviceAuthService(client: client);
    await service.check(deviceId: 'meu-device-id');

    expect(sentBody, {'deviceId': 'meu-device-id'});
  });
}
