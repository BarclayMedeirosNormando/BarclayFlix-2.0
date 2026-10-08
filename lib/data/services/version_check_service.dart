import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/constants/app_constants.dart';
import '../models/app_update_info.dart';
import 'apps_script_http.dart';

/// Pergunta ao Apps Script (`action: check_version`) qual é a versão mais
/// nova publicada para esta plataforma (aba "Versao" da planilha) e compara
/// com a versão instalada.
///
/// NUNCA lança e nunca bloqueia o app: qualquer falha (sem rede, planilha
/// sem a plataforma, versão ilegível, plataforma não suportada) vira `null`,
/// igual a "não há atualização".
class VersionCheckService {
  final http.Client _client;
  final Future<String> Function() _installedVersion;
  final String? _platformName;
  final String _endpoint;

  VersionCheckService({
    http.Client? client,
    Future<String> Function()? installedVersion,
    String? platformName,
    String? endpoint,
    bool detectPlatform = true,
  })  : _client = client ?? http.Client(),
        _endpoint = endpoint ?? AppConstants.deviceAuthUrl,
        _installedVersion = installedVersion ?? _readInstalledVersion,
        _platformName = platformName ?? (detectPlatform ? _currentPlatformName() : null);

  static Future<String> _readInstalledVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  static String? _currentPlatformName() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    return null;
  }

  Future<AppUpdateInfo?> checkForUpdate() async {
    final platform = _platformName;
    if (platform == null || _endpoint.trim().isEmpty) return null;

    try {
      final uri = Uri.parse(_endpoint);
      final response = await postJsonFollowingRedirects(
        _client,
        uri,
        jsonEncode({'action': 'check_version', 'plataforma': platform}),
      );
      if (response.statusCode != 200) return null;

      final data = json.decode(response.body);
      if (data is! Map || data['status'] != 'ok') return null;

      final latest = (data['versaoMinima'] ?? '').toString().trim();
      final url = (data['urlDownload'] ?? '').toString().trim();
      if (latest.isEmpty || url.isEmpty) return null;

      final installed = await _installedVersion();
      if (!isNewerVersion(latest, installed)) return null;

      return AppUpdateInfo(
        latestVersion: latest,
        downloadUrl: url,
        changelog: (data['changelog'] ?? '').toString().trim(),
      );
    } catch (_) {
      return null;
    }
  }

  /// `true` se [latest] é estritamente maior que [installed], comparando
  /// número a número ("2.10.0" > "2.9.0"). Ignora sufixo de build ("+15") e
  /// pré-release ("-beta"); parte ausente conta como 0 ("2.5" == "2.5.0").
  /// Texto sem nenhum número nunca é considerado "mais novo".
  static bool isNewerVersion(String latest, String installed) {
    final a = _parts(latest);
    final b = _parts(installed);
    if (a == null || b == null) return false;
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  static List<int>? _parts(String version) {
    final core = version.trim().split(RegExp(r'[+-]')).first;
    final parts = core.split('.');
    final numbers = <int>[];
    for (final part in parts) {
      final n = int.tryParse(part.trim());
      if (n == null) return null;
      numbers.add(n);
    }
    return numbers.isEmpty ? null : numbers;
  }
}
