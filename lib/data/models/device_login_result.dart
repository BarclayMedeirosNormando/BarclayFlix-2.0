import 'xtream_parsers.dart';

/// Um servidor Xtream Codes disponível para o dispositivo ativado. O
/// usuário sempre escolhe qual usar numa tela própria (ver
/// ServerSelectionScreen) — mesmo quando o backend devolve um só, por
/// consistência visual entre clientes com 1 ou vários servidores (ver
/// ActivationScreen._onActivated).
///
/// [username]/[password] são a credencial REAL daquele servidor específico
/// na Xtream Codes. É sempre essa credencial que deve ser usada para montar
/// um [XtreamApiService] ou persistir um [SavedProfile] (ver
/// AuthProvider.loginWithServer e ProfilesProvider.chooseServer).
class ServerOption {
  final String nome;
  final String dns;
  final String username;
  final String password;

  const ServerOption({
    required this.nome,
    required this.dns,
    required this.username,
    required this.password,
  });

  factory ServerOption.fromJson(Map<String, dynamic> json) {
    return ServerOption(
      nome: asString(json['nome']),
      dns: asString(json['dns']),
      username: asString(json['username']),
      password: asString(json['password']),
    );
  }
}

/// Resultado de uma ativação de dispositivo bem-sucedida: o nome do cliente
/// (só para exibição) e a lista de servidores vinculados a ele.
class DeviceAuthResult {
  final String nomeCliente;
  final List<ServerOption> servidores;

  const DeviceAuthResult({required this.nomeCliente, required this.servidores});
}
