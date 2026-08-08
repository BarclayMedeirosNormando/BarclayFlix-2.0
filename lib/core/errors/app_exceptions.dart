/// Erro retornado pela ativação por código de dispositivo (Google Apps
/// Script): hoje conhecidos em [code] — `"nao_registrado"` (dispositivo
/// ainda não cadastrado pelo suporte, estado normal de espera),
/// `"inativo"` e `"expirado"` (cliente cadastrado, mas sem acesso válido no
/// momento — precisa de ação humana, não se resolve tentando de novo).
/// `code` é `null` para erros genéricos (ex: falha de rede, resposta
/// inesperada do backend), o que permite distinguir esses casos de um
/// código de negócio conhecido em quem consome esta exceção.
class DeviceLoginException implements Exception {
  final String message;
  final String? code;

  const DeviceLoginException(this.message, {this.code});

  @override
  String toString() => message;
}

/// Erro retornado pela API Xtream Codes (player_api.php) do servidor
/// específico do cliente (dns_encontrado).
class XtreamApiException implements Exception {
  final String message;

  const XtreamApiException(this.message);

  @override
  String toString() => message;
}
