import 'xtream_parsers.dart';

/// Representa o `user_info` + `server_info` retornados por
/// `{dns_encontrado}/player_api.php?username=...&password=...`.
class XtreamUserInfo {
  final String username;
  final bool isAuthenticated;
  final String status;
  final DateTime? expDate;
  final bool isTrial;
  final int activeConnections;
  final int maxConnections;
  final String serverUrl;
  final String serverPort;

  const XtreamUserInfo({
    required this.username,
    required this.isAuthenticated,
    required this.status,
    required this.expDate,
    required this.isTrial,
    required this.activeConnections,
    required this.maxConnections,
    required this.serverUrl,
    required this.serverPort,
  });

  factory XtreamUserInfo.fromJson(Map<String, dynamic> json) {
    final userInfo = asMap(json['user_info']);
    final serverInfo = asMap(json['server_info']);

    return XtreamUserInfo(
      username: asString(userInfo['username']),
      isAuthenticated: asInt(userInfo['auth']) == 1,
      status: asString(userInfo['status'], 'Unknown'),
      expDate: asUnixDate(userInfo['exp_date']),
      isTrial: asBool(userInfo['is_trial']),
      activeConnections: asInt(userInfo['active_cons']),
      maxConnections: asInt(userInfo['max_connections']),
      serverUrl: asString(serverInfo['url']),
      serverPort: asString(serverInfo['port']),
    );
  }

  bool get isExpired {
    if (expDate == null) return false;
    return expDate!.isBefore(DateTime.now());
  }

  bool get isActive => isAuthenticated && status.toLowerCase() == 'active' && !isExpired;
}
