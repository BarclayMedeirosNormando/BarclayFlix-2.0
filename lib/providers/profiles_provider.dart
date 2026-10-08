import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../data/models/device_login_result.dart';
import '../data/models/saved_profile.dart';
import '../data/services/storage_service.dart';
import 'auth_provider.dart';

/// Provê a credencial única e salva (perfil do servidor escolhido) e o
/// fluxo de ativação/revalidação por deviceId do app.
class ProfilesProvider extends ChangeNotifier {
  final StorageService _storageService;
  final AuthProvider _authProvider;

  ProfilesProvider({
    required this._authProvider,
    StorageService? storageService,
  }) : _storageService = storageService ?? StorageService();

  final Map<String, bool> _profileLoading = {};
  final Map<String, String?> _profileErrors = {};
  final Map<String, String?> _profileErrorCodes = {};

  List<SavedProfile> _savedProfiles = [];
  bool _loadingList = true;
  String? _listError;

  SavedProfile? get savedProfile => _savedProfiles.isEmpty ? null : _savedProfiles.first;
  List<SavedProfile> get profiles => List.unmodifiable(_savedProfiles);
  bool get loadingList => _loadingList;
  String? get listError => _listError;
  bool isLoading(String id) => _profileLoading[id] ?? false;
  String? errorFor(String id) => _profileErrors[id];

  /// Código específico (`"inativo"`, `"expirado"` etc) do último erro de
  /// ativação para [id], quando o backend informou um — ver
  /// [AuthProvider.errorCode].
  String? errorCodeFor(String id) => _profileErrorCodes[id];

  /// Carrega a única credencial salva, migrando perfis legados de lista se
  /// necessário.
  Future<void> loadProfiles() async {
    _loadingList = true;
    _listError = null;
    notifyListeners();

    try {
      _savedProfiles = await _storageService.getSavedProfiles();
    } catch (_) {
      _listError = 'Não foi possível carregar as credenciais salvas.';
    }

    _loadingList = false;
    notifyListeners();
  }

  /// Consulta a ativação deste dispositivo (ver DeviceIdService) — usada
  /// tanto pela SplashScreen (uma vez, ao abrir o app) quanto pela
  /// ActivationScreen (periodicamente, enquanto aguarda o cadastro).
  Future<DeviceAuthResult?> checkDeviceActivation() {
    return _authProvider.checkDevice();
  }

  /// [TESTE] Entra direto com o perfil salvo SEM consultar a ativação do
  /// dispositivo (Apps Script). Usado pela SplashScreen só quando a
  /// ativação ficou inalcançável por falha de rede/serviço (nunca quando o
  /// backend respondeu inativo/expirado/nao_registrado): monta o
  /// [ServerOption] a partir do [SavedProfile] e valida direto na Xtream.
  /// Retorna `false` (com [AuthProvider.errorMessage] preenchido) se a
  /// Xtream também não respondeu ou recusou a credencial.
  Future<bool> enterWithSavedProfile() async {
    final profile = savedProfile;
    if (profile == null) return false;

    final server = ServerOption(
      nome: profile.nomeServidor ?? profile.nomeExibicao,
      dns: profile.dns,
      username: profile.xtreamUsername,
      password: profile.xtreamPassword,
    );

    final result = await _authProvider.loginWithServer(server: server);
    if (result == null) return false;

    final updated = profile.copyWith(dataUltimoAcesso: DateTime.now());
    _savedProfiles = [
      updated,
      ..._savedProfiles.where((existing) => existing.id != profile.id),
    ];
    try {
      await _storageService.saveProfile(updated);
    } catch (_) {
      // Falha ao gravar só o "último acesso" nunca deve impedir a entrada.
    }
    notifyListeners();
    return true;
  }

  Future<bool> selectProfile(String id) async {
    final index = _savedProfiles.indexWhere((profile) => profile.id == id);
    if (index < 0) return false;
    return _validateSavedProfile(_savedProfiles[index]);
  }

  Future<bool> _validateSavedProfile(SavedProfile profile) async {
    _profileLoading[profile.id] = true;
    _profileErrors.remove(profile.id);
    _profileErrorCodes.remove(profile.id);
    notifyListeners();

    final result = await _authProvider.checkDevice();

    if (result == null) {
      _profileLoading[profile.id] = false;
      _profileErrors[profile.id] = _authProvider.errorMessage;
      _profileErrorCodes[profile.id] = _authProvider.errorCode;
      notifyListeners();
      return false;
    }

    final server = _findServerByDns(result.servidores, profile.dns);
    if (server == null) {
      _profileLoading[profile.id] = false;
      _profileErrors[profile.id] = 'Acesso a este servidor foi removido.';
      notifyListeners();
      return false;
    }

    final authResult = await _authProvider.loginWithServer(server: server);
    if (authResult == null) {
      _profileLoading[profile.id] = false;
      _profileErrors[profile.id] = _authProvider.errorMessage;
      notifyListeners();
      return false;
    }

    final freshNomeCliente = result.nomeCliente.trim();
    final updated = profile.copyWith(
      dataUltimoAcesso: DateTime.now(),
      nomeCliente: freshNomeCliente.isEmpty ? profile.nomeCliente : freshNomeCliente,
    );
    _savedProfiles = [
      updated,
      ..._savedProfiles.where((existing) => existing.id != profile.id),
    ];
    await _storageService.saveProfile(updated);
    _profileLoading[profile.id] = false;
    _profileErrors.remove(profile.id);
    notifyListeners();
    return true;
  }

  /// Valida [server] na Xtream Codes e salva/atualiza o [SavedProfile]
  /// resultante. Usado tanto na primeira ativação (ServerSelectionScreen
  /// alcançada via ActivationScreen) quanto em "Trocar de servidor"
  /// (ServerSelectionScreen alcançada via HomeScreen).
  ///
  /// [existingProfileId], quando informado (fluxo "Trocar de servidor"),
  /// faz o resultado ATUALIZAR esse perfil já salvo (mesmo id, só os
  /// campos do servidor mudam) em vez de criar um registro novo. Sem ele
  /// (primeira ativação), cria um [SavedProfile] novo.
  ///
  /// [nomeCliente], quando informado (vindo do [DeviceAuthResult] mais
  /// recente), é persistido no perfil resultante — fonte da saudação
  /// "Bem-vindo, {nomeCliente}" (ServerSelectionScreen) em acessos futuros.
  /// Se omitido/vazio ao atualizar um perfil existente, o valor já
  /// persistido é mantido em vez de apagado.
  Future<bool> chooseServer({
    required ServerOption server,
    String? existingProfileId,
    String? nomeCliente,
  }) async {
    final result = await _authProvider.loginWithServer(server: server);
    if (result == null) return false;

    final existingProfile = existingProfileId == null ? null : _findProfileById(existingProfileId);
    final trimmedNomeCliente = nomeCliente?.trim();

    final profile = SavedProfile(
      id: existingProfileId ?? 'profile_${DateTime.now().microsecondsSinceEpoch}',
      nomeExibicao: _defaultDisplayName(server),
      xtreamUsername: server.username,
      xtreamPassword: server.password,
      dns: server.dns,
      nomeServidor: server.nome.trim().isEmpty ? null : server.nome.trim(),
      nomeCliente: (trimmedNomeCliente != null && trimmedNomeCliente.isNotEmpty)
          ? trimmedNomeCliente
          : existingProfile?.nomeCliente,
      dataUltimoAcesso: DateTime.now(),
    );

    await _storageService.saveProfile(profile);
    _savedProfiles = [profile, ..._savedProfiles.where((existing) => existing.id != profile.id)];
    notifyListeners();
    return true;
  }

  Future<void> clearSavedProfile() async {
    await _storageService.clearSavedProfile();
    _savedProfiles = [];
    notifyListeners();
  }

  Future<void> removeProfile(String id) async {
    _savedProfiles = _savedProfiles.where((profile) => profile.id != id).toList();
    await _storageService.removeProfile(id);
    notifyListeners();
  }

  Future<void> renameProfile(String id, String novoNome) async {
    final trimmed = novoNome.trim();
    if (trimmed.isEmpty) return;

    final index = _savedProfiles.indexWhere((profile) => profile.id == id);
    if (index < 0) return;

    final updated = _savedProfiles[index].copyWith(nomeExibicao: trimmed);
    _savedProfiles[index] = updated;
    await _storageService.updateProfileNickname(id, trimmed);
    notifyListeners();
  }

  ServerOption? _findServerByDns(List<ServerOption> servers, String dns) {
    for (final server in servers) {
      if (server.dns == dns) return server;
    }
    return null;
  }

  SavedProfile? _findProfileById(String id) {
    for (final profile in _savedProfiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  /// [TESTE] Nunca mais anexa o DNS entre parênteses pra desambiguar nomes
  /// repetidos -- a AppBar da HomeScreen mostra este valor sozinho como
  /// título ("P2BRAS", nunca "P2BRAS (https://...)"), pedido explícito do
  /// usuário. A ServerSelectionScreen (onde uma eventual duplicata
  /// importaria de verdade) já mostra `server.nome` puro em cada card, não
  /// este valor -- então nomes repetidos entre perfis salvos não causam
  /// ambiguidade real em nenhuma tela.
  String _defaultDisplayName(ServerOption server) {
    return server.nome.trim().isNotEmpty ? server.nome.trim() : server.dns;
  }
}
