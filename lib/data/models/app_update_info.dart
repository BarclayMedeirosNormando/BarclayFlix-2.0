/// Versão mais nova do app publicada na aba "Versao" da planilha (ver
/// VersionCheckService) — só existe quando a versão instalada é MENOR que
/// ela.
class AppUpdateInfo {
  final String latestVersion;
  final String downloadUrl;
  final String changelog;

  const AppUpdateInfo({
    required this.latestVersion,
    required this.downloadUrl,
    required this.changelog,
  });
}
