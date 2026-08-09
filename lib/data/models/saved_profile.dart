import 'xtream_parsers.dart';

/// Um servidor IPTV já configurado e salvo localmente (estilo IBO Player/
/// XCIPTV: a tela inicial mostra um card por perfil, em vez de só um
/// usuário/senha fixos). Guarda tudo que é necessário para revalidar a
/// sessão (ativação de dispositivo -> Xtream Codes) sem pedir input do
/// usuário de novo — a identidade usada na revalidação é o deviceId desta
/// instalação (ver DeviceIdService), não uma credencial guardada aqui.
class SavedProfile {
  final String id;
  final String nomeExibicao;

  /// Usuário/senha REAIS deste servidor específico na Xtream Codes (vindos
  /// do [ServerOption] escolhido) — é isso que autentica o
  /// [XtreamApiService] usado pelo resto do app.
  final String xtreamUsername;
  final String xtreamPassword;

  final String dns;

  /// Nome do servidor (vindo da ativação de dispositivo) que resultou neste
  /// perfil — distinto de [nomeExibicao] (que o usuário pode renomear
  /// livremente). `null` para perfis migrados da credencial única legada
  /// (ver StorageService._migrateLegacyCredentialIfNeeded), que nunca
  /// tiveram essa informação.
  final String? nomeServidor;

  /// Nome do cliente (vindo do Master Login/ativação de dispositivo, ver
  /// DeviceAuthResult) — persistido para que a saudação "Bem-vindo,
  /// {nomeCliente}" (ServerSelectionScreen) sobreviva a fechar/reabrir o
  /// app, e não dependa de o fluxo atual ter acabado de buscar esse nome de
  /// novo na rede. `null` para perfis que nunca receberam esse dado (ex:
  /// migrados da credencial única legada).
  final String? nomeCliente;

  final DateTime? dataUltimoAcesso;

  const SavedProfile({
    required this.id,
    required this.nomeExibicao,
    required this.xtreamUsername,
    required this.xtreamPassword,
    required this.dns,
    this.nomeServidor,
    this.nomeCliente,
    this.dataUltimoAcesso,
  });

  factory SavedProfile.fromJson(Map<String, dynamic> json) {
    return SavedProfile(
      id: asString(json['id']),
      nomeExibicao: asString(json['nomeExibicao']),
      xtreamUsername: asString(json['xtreamUsername']),
      xtreamPassword: asString(json['xtreamPassword']),
      dns: asString(json['dns']),
      nomeServidor: asStringOrNull(json['nomeServidor']),
      nomeCliente: asStringOrNull(json['nomeCliente']),
      dataUltimoAcesso: DateTime.tryParse(asString(json['dataUltimoAcesso'])),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'nomeExibicao': nomeExibicao,
      'xtreamUsername': xtreamUsername,
      'xtreamPassword': xtreamPassword,
      'dns': dns,
      if (nomeServidor != null) 'nomeServidor': nomeServidor,
      if (nomeCliente != null) 'nomeCliente': nomeCliente,
      if (dataUltimoAcesso != null) 'dataUltimoAcesso': dataUltimoAcesso!.toIso8601String(),
    };
  }

  SavedProfile copyWith({
    String? nomeExibicao,
    String? xtreamUsername,
    String? xtreamPassword,
    String? dns,
    String? nomeServidor,
    String? nomeCliente,
    DateTime? dataUltimoAcesso,
  }) {
    return SavedProfile(
      id: id,
      nomeExibicao: nomeExibicao ?? this.nomeExibicao,
      xtreamUsername: xtreamUsername ?? this.xtreamUsername,
      xtreamPassword: xtreamPassword ?? this.xtreamPassword,
      dns: dns ?? this.dns,
      nomeServidor: nomeServidor ?? this.nomeServidor,
      nomeCliente: nomeCliente ?? this.nomeCliente,
      dataUltimoAcesso: dataUltimoAcesso ?? this.dataUltimoAcesso,
    );
  }

  /// Nunca inclui senhas — protege contra vazamento acidental em
  /// `print`/`debugPrint`/logs que interpolem o objeto direto (`'$profile'`)
  /// em vez de um campo específico.
  @override
  String toString() {
    return 'SavedProfile(id: $id, nomeExibicao: $nomeExibicao, xtreamUsername: $xtreamUsername, dns: $dns)';
  }
}
