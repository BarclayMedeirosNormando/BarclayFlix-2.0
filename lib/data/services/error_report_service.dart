import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/constants/app_constants.dart';
import 'apps_script_http.dart';
import 'device_id_service.dart';

/// Categorias aceitas pelo Apps Script (aba "Logs").
class ErrorCategory {
  ErrorCategory._();

  static const ativacao = 'ativacao';
  static const catalogo = 'catalogo';
  static const reproducao = 'reproducao';
  static const app = 'app';
}

/// Envia ao Apps Script as FALHAS REAIS do app (aba "Logs" da planilha),
/// pra o suporte achar o problema de um cliente pelo código do aparelho.
///
/// Garantias:
/// - Nunca lança e nunca atrasa quem chama: [report] é "dispara e esquece".
/// - Nunca envia usuário, senha nem caminho de URL: [sanitize] reduz toda URL
///   a `host:porta` e mascara `username=`/`password=`.
/// - Limites no aparelho: no máximo [maxPerSession] envios por abertura do
///   app e a mesma falha (categoria + texto) só uma vez a cada
///   [dedupeWindow]. O servidor ainda aplica o limite dele por aparelho.
/// - Sem `APPS_SCRIPT_URL` (ex: `flutter test`), não faz nada.
class ErrorReportService {
  /// Instância usada pelo app inteiro; testes trocam por uma com cliente
  /// falso.
  static ErrorReportService instance = ErrorReportService();

  final http.Client _client;
  final Future<String> Function() _deviceId;
  final Future<String> Function() _appVersion;
  final String? _platformName;
  final String _endpoint;
  final DateTime Function() _now;
  final int maxPerSession;
  final Duration dedupeWindow;

  final Map<String, DateTime> _lastSent = {};
  int _sentCount = 0;

  ErrorReportService({
    http.Client? client,
    Future<String> Function()? deviceId,
    Future<String> Function()? appVersion,
    String? platformName,
    String? endpoint,
    DateTime Function()? now,
    this.maxPerSession = 15,
    this.dedupeWindow = const Duration(minutes: 10),
    bool detectPlatform = true,
  })  : _client = client ?? http.Client(),
        _deviceId = deviceId ?? DeviceIdService().getDeviceId,
        _appVersion = appVersion ?? _readInstalledVersion,
        _platformName = platformName ?? (detectPlatform ? _currentPlatformName() : null),
        _endpoint = endpoint ?? AppConstants.deviceAuthUrl,
        _now = now ?? DateTime.now;

  static Future<String> _readInstalledVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  static String? _currentPlatformName() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    return null;
  }

  /// Dispara o envio sem esperar. Seguro de chamar de qualquer `catch`.
  void report(String category, String message) {
    unawaited(reportAndWait(category, message));
  }

  /// Igual a [report], mas devolve o Future (usado nos testes). Nunca lança.
  Future<void> reportAndWait(String category, String message) async {
    try {
      final platform = _platformName;
      if (platform == null || _endpoint.trim().isEmpty) return;

      final clean = sanitize(message);
      if (clean.isEmpty) return;

      // Checagens de limite ANTES de qualquer await: várias falhas
      // simultâneas não furam o teto.
      final now = _now();
      _lastSent.removeWhere((_, at) => now.difference(at) >= dedupeWindow);
      final key = '$category|$clean';
      if (_lastSent.containsKey(key)) return;
      if (_sentCount >= maxPerSession) return;
      _lastSent[key] = now;
      _sentCount++;

      final body = jsonEncode({
        'action': 'log_error',
        'deviceId': await _deviceId(),
        'plataforma': platform,
        'versaoApp': await _appVersion(),
        'categoria': category,
        'mensagem': clean,
      });
      await postJsonFollowingRedirects(_client, Uri.parse(_endpoint), body);
    } catch (_) {
      // Registrar erro nunca pode causar outro erro.
    }
  }

  static const _maxLength = 300;

  static final _urlPattern = RegExp(r'''https?://[^\s"')\]>]+''', caseSensitive: false);
  static final _credentialPattern = RegExp(
    r'''\b(username|password|user|pass|token)=([^&\s"']+)''',
    caseSensitive: false,
  );

  /// Deixa só o que ajuda o suporte: cada URL vira `host:porta` (o caminho
  /// de um stream carrega usuário e senha), `username=`/`password=` soltos
  /// são mascarados, quebras de linha viram espaço e o texto é cortado.
  static String sanitize(String text) {
    var out = text.replaceAllMapped(_urlPattern, (match) {
      // A pontuação logo após a URL ("...m3u8:", "...ts,") não faz parte
      // dela: sai do trecho a trocar e volta ao texto.
      final raw = match.group(0)!;
      final url = raw.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
      final tail = raw.substring(url.length);
      final uri = Uri.tryParse(url);
      if (uri == null || uri.host.isEmpty) return '[url]$tail';
      return (uri.hasPort ? '${uri.host}:${uri.port}' : uri.host) + tail;
    });
    out = out.replaceAllMapped(_credentialPattern, (match) => '${match.group(1)}=***');
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (out.length > _maxLength) out = out.substring(0, _maxLength);
    return out;
  }

  /// `host:porta` de [url] (ou `desconhecido`), pra citar o servidor numa
  /// mensagem sem expor o caminho.
  static String hostOf(String? url) {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return 'desconhecido';
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }
}
