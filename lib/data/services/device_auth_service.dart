import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exceptions.dart';
import '../models/device_login_result.dart';
import '../models/xtream_parsers.dart';

/// Consulta o Google Apps Script que ativa este dispositivo: envia só o
/// [deviceId] desta instalação (ver DeviceIdService) e devolve os
/// servidores Xtream Codes vinculados a ele, quando já cadastrado.
///
/// Respostas conhecidas do Apps Script:
/// - `{"status":"ok","nomeCliente":"...","servidores":[{"nome":"...","dns":"http://servidor.com:porta","username":"...","password":"..."},...]}`
///   (`username`/`password` são a credencial REAL daquele servidor na
///   Xtream Codes, ver ServerOption)
/// - `{"status":"erro","codigo":"nao_registrado","mensagem":"..."}` (estado
///   normal de espera, antes do suporte cadastrar o dispositivo)
/// - `{"status":"erro","codigo":"inativo","mensagem":"..."}`
/// - `{"status":"erro","codigo":"expirado","mensagem":"..."}`
/// - `{"status":"erro","mensagem":"..."}` (sem `codigo`, erro genérico)
class DeviceAuthService {
  final http.Client _client;

  /// Limite de saltos ao seguir um redirecionamento manualmente (ver
  /// [_followRedirect]) — generoso o bastante pra nunca ser o gargalo real
  /// (o Apps Script hoje só redireciona uma vez, de `/exec` para
  /// `script.googleusercontent.com`), mas finito pra nunca entrar num loop
  /// infinito caso o servidor um dia redirecione de forma indevida.
  static const _maxRedirectHops = 5;

  DeviceAuthService({http.Client? client}) : _client = client ?? http.Client();

  Future<DeviceAuthResult> check({required String deviceId}) async {
    final uri = Uri.parse(AppConstants.deviceAuthUrl);

    late final http.Response response;
    try {
      final initialResponse = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'deviceId': deviceId}),
          )
          .timeout(AppConstants.networkTimeout);
      response = await _followRedirect(initialResponse, uri);
    } catch (_) {
      throw const DeviceLoginException(
        'Não foi possível conectar ao servidor de ativação. Verifique sua conexão.',
      );
    }

    if (response.statusCode != 200) {
      try {
        final decoded = json.decode(response.body);
        if (decoded is Map) {
          final message = decoded['mensagem']?.toString();
          final code = asStringOrNull(decoded['codigo']);
          if (message != null && message.isNotEmpty) {
            throw DeviceLoginException(message, code: code);
          }

          final status = decoded['status']?.toString();
          if (status != 'ok') {
            throw DeviceLoginException(
              'Dispositivo ainda não ativado.',
              code: code,
            );
          }
        }
      } on DeviceLoginException {
        rethrow;
      } catch (_) {
        // Intencional: se o corpo não for JSON ou não tiver o formato
        // esperado, volta para a mensagem genérica de indisponibilidade.
      }

      throw const DeviceLoginException(
        'Servidor de ativação indisponível. Tente novamente mais tarde.',
      );
    }

    final Map<String, dynamic> data;
    try {
      data = json.decode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const DeviceLoginException(
        'Resposta inválida do servidor de ativação.',
      );
    }

    final status = data['status']?.toString();

    if (status != 'ok') {
      throw DeviceLoginException(
        data['mensagem']?.toString() ?? 'Dispositivo ainda não ativado.',
        code: asStringOrNull(data['codigo']),
      );
    }

    final servers = asMapList(data['servidores']).map(ServerOption.fromJson).toList();
    if (servers.isEmpty) {
      throw const DeviceLoginException(
        'Nenhum servidor retornado pela ativação. Contate o suporte.',
      );
    }

    return DeviceAuthResult(
      nomeCliente: asString(data['nomeCliente']),
      servidores: servers,
    );
  }

  /// Segue manualmente um redirecionamento HTTP (3xx + header `location`).
  ///
  /// Necessário porque toda URL `/exec` de um Google Apps Script Web App
  /// redireciona (302, corpo vazio) para uma URL de
  /// `script.googleusercontent.com` — é lá que mora o JSON de verdade. Isso
  /// é comportamento NORMAL/esperado do Apps Script, não uma falha de rede.
  ///
  /// O destino do redirect já serve o conteúdo pronto — sempre via GET,
  /// mesmo quando a requisição original (aqui, sempre POST) foi outro
  /// método: não é um caso de reenviar o mesmo corpo/verbo, é buscar o
  /// resultado já computado que o Apps Script deixou esperando naquela URL.
  Future<http.Response> _followRedirect(
    http.Response response,
    Uri requestUri, {
    int remainingHops = _maxRedirectHops,
  }) async {
    final isRedirect = response.statusCode >= 300 && response.statusCode < 400;
    if (!isRedirect || remainingHops <= 0) return response;

    final location = response.headers['location'];
    if (location == null || location.isEmpty) return response;

    final redirectUri = requestUri.resolve(location);
    final redirected = await _client.get(redirectUri).timeout(AppConstants.networkTimeout);
    return _followRedirect(redirected, redirectUri, remainingHops: remainingHops - 1);
  }
}
