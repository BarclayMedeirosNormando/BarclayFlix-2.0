/// Configuração injetada em tempo de build via `--dart-define`, para nunca
/// deixar valores sensíveis (URLs de backend, chaves) hardcoded no código
/// versionado. Ver README.md para como definir cada variável ao rodar/buildar.
class AppConfig {
  AppConfig._();

  static const String appsScriptUrl = String.fromEnvironment(
    'APPS_SCRIPT_URL',
    defaultValue: '',
  );

  /// `true` quando o app foi buildado sem `--dart-define=APPS_SCRIPT_URL=...`
  /// — nesse caso nenhuma ativação pode funcionar.
  static bool get isAppsScriptUrlMissing => appsScriptUrl.trim().isEmpty;
}
