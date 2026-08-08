import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/errors/app_exceptions.dart';
import '../data/models/device_login_result.dart';
import '../data/models/xtream_user_info.dart';
import '../data/services/device_auth_service.dart';
import '../data/services/device_id_service.dart';
import '../data/services/xtream_api_service.dart';

enum AuthStatus { idle, loading, authenticated, error }

/// Resultado de um [AuthProvider.loginWithServer] bem-sucedido: tudo que
/// [ProfilesProvider] precisa pra persistir um [SavedProfile] (o
/// [ServerOption] validado) — sem que este provider precise saber nada
/// sobre perfis salvos.
class AuthResult {
  final ServerOption server;
  final XtreamUserInfo userInfo;

  const AuthResult({required this.server, required this.userInfo});
}

/// Segura a SESSÃO ATIVA do app: qual [apiService] (já autenticado) o resto
/// do app (HomeScreen, PlayerScreen etc.) deve usar agora. Só isso — não
/// sabe nada sobre múltiplos perfis nem persiste nada em disco.
///
/// O login acontece em DOIS passos, propositalmente separados:
/// 1. [checkDevice]: consulta a ativação deste dispositivo (deviceId) ->
///    lista de servidores vinculados a ele, se já ativado. Ainda NÃO
///    autentica sessão nenhuma.
/// 2. [loginWithServer]: valida UM desses servidores na Xtream Codes e, se
///    bem-sucedido, torna essa a sessão ativa.
///
/// Essa separação é o que permite ao [ProfilesProvider] mostrar um seletor
/// de servidor entre os dois passos quando o dispositivo tem mais de um — e,
/// no caso de revalidação de um perfil já salvo, decidir sozinho (sem UI)
/// qual dos servidores retornados é o mesmo que já estava salvo.
class AuthProvider extends ChangeNotifier {
  final DeviceAuthService _deviceAuthService;
  final DeviceIdService _deviceIdService;
  final http.Client? _xtreamHttpClient;

  /// [apiService] permite construir o provider já "autenticado" (usado em
  /// testes, para não precisar simular o fluxo completo de ativação +
  /// Xtream via HTTP só para montar telas que dependem de
  /// `AuthProvider.apiService`). Em produção nunca é passado.
  ///
  /// [xtreamHttpClient] existe só para teste de ponta a ponta (ex:
  /// ProfilesProvider): o [XtreamApiService] que [loginWithServer] monta
  /// internamente não tinha, até então, nenhum jeito de receber um
  /// `http.Client` fake — sem isso, testar esse fluxo/`ProfilesProvider`
  /// exigiria rede de verdade. Em produção nunca é passado (cada
  /// [XtreamApiService] usa seu `http.Client()` padrão).
  AuthProvider({
    DeviceAuthService? deviceAuthService,
    DeviceIdService? deviceIdService,
    XtreamApiService? apiService,
    http.Client? xtreamHttpClient,
  })  : _deviceAuthService = deviceAuthService ?? DeviceAuthService(),
        _deviceIdService = deviceIdService ?? DeviceIdService(),
        // ignore: prefer_initializing_formals
        _xtreamHttpClient = xtreamHttpClient {
    if (apiService != null) {
      _apiService = apiService;
      _status = AuthStatus.authenticated;
    }
  }

  AuthStatus _status = AuthStatus.idle;
  String? _errorMessage;
  String? _errorCode;
  XtreamUserInfo? _currentUser;
  XtreamApiService? _apiService;

  AuthStatus get status => _status;
  String? get errorMessage => _errorMessage;

  /// Código específico do último erro de ativação, quando o backend
  /// informou um (`"nao_registrado"`, `"inativo"`, `"expirado"`) — `null`
  /// para erros genéricos (rede, resposta inesperada) ou quando o último
  /// erro veio da Xtream Codes, não da ativação de dispositivo.
  String? get errorCode => _errorCode;
  XtreamUserInfo? get currentUser => _currentUser;
  XtreamApiService? get apiService => _apiService;
  bool get isLoading => _status == AuthStatus.loading;

  /// Passo 1 do login: consulta a ativação deste dispositivo (ver
  /// DeviceIdService) e devolve os servidores vinculados a ele, se já
  /// ativado. Retorna `null` em caso de falha (com
  /// [status]/[errorMessage]/[errorCode] já atualizados) — nunca lança.
  Future<DeviceAuthResult?> checkDevice() async {
    _setLoading();

    try {
      final deviceId = await _deviceIdService.getDeviceId();
      final result = await _deviceAuthService.check(deviceId: deviceId);

      _status = AuthStatus.idle;
      _errorMessage = null;
      _errorCode = null;
      notifyListeners();
      return result;
    } on DeviceLoginException catch (e) {
      _status = AuthStatus.error;
      _errorMessage = e.message;
      _errorCode = e.code;
      notifyListeners();
      return null;
    } catch (e) {
      _status = AuthStatus.error;
      _errorMessage = e.toString();
      _errorCode = null;
      notifyListeners();
      return null;
    }
  }

  /// Passo 2 do login: valida [server] na Xtream Codes com a credencial
  /// REAL daquele servidor ([ServerOption.username]/[ServerOption.
  /// password]) e, se bem-sucedido, torna esta a sessão ativa do app.
  /// Retorna `null` em caso de falha (com [status]/[errorMessage] já
  /// atualizados) — nunca lança.
  Future<AuthResult?> loginWithServer({required ServerOption server}) async {
    _setLoading();

    try {
      final apiService = XtreamApiService(
        dns: server.dns,
        username: server.username,
        password: server.password,
        client: _xtreamHttpClient,
      );
      final userInfo = await apiService.login();

      _apiService = apiService;
      _currentUser = userInfo;
      _status = AuthStatus.authenticated;
      _errorMessage = null;
      _errorCode = null;
      notifyListeners();

      return AuthResult(server: server, userInfo: userInfo);
    } catch (e) {
      _status = AuthStatus.error;
      _errorMessage = e.toString();
      _errorCode = null;
      notifyListeners();
      return null;
    }
  }

  /// Encerra a sessão ativa (em memória) — não apaga nenhum perfil salvo;
  /// quem quiser removê-lo de verdade usa `ProfilesProvider.clearSavedProfile`.
  void logout() {
    _apiService = null;
    _currentUser = null;
    _status = AuthStatus.idle;
    _errorMessage = null;
    _errorCode = null;
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    _errorCode = null;
    if (_status == AuthStatus.error) _status = AuthStatus.idle;
    notifyListeners();
  }

  void _setLoading() {
    _status = AuthStatus.loading;
    _errorMessage = null;
    _errorCode = null;
    notifyListeners();
  }
}
