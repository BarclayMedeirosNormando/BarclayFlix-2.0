import '../../config/app_config.dart';

class AppConstants {
  AppConstants._();

  /// Endpoint do Google Apps Script responsável pela ativação por código de
  /// dispositivo. Recebe POST com corpo JSON `{"deviceId"}` e retorna o
  /// cliente + servidores Xtream Codes vinculados a este dispositivo (ver
  /// DeviceAuthService/DeviceIdService). Valor real vem de `--dart-define`
  /// (ver AppConfig e README.md) — nunca hardcoded aqui.
  static const String deviceAuthUrl = AppConfig.appsScriptUrl;

  /// Caminho padrão da API Xtream Codes usado em qualquer servidor retornado
  /// pelo Master Login.
  static const String xtreamPlayerApiPath = '/player_api.php';

  static const Duration networkTimeout = Duration(seconds: 15);
}
