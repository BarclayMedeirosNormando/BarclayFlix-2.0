import 'package:flutter/foundation.dart';

import '../core/errors/app_exceptions.dart';
import '../data/models/xtream_models.dart';
import '../data/services/xtream_api_service.dart';
import 'content_provider.dart' show LoadStatus;

/// Estado de detalhes de um filme (`get_vod_info`) -- mesmo padrão exato do
/// [SeriesDetailsProvider] (cache em memória por id, ativo pela sessão
/// inteira, registrado no topo da árvore em `main.dart`); ver aquele para o
/// raciocínio completo de por que não é escopado dentro da HomeScreen.
class VodDetailsProvider extends ChangeNotifier {
  final Map<String, VodInfo> _cache = {};

  String? _activeVodId;
  LoadStatus _status = LoadStatus.idle;
  String? _errorMessage;
  VodInfo? _info;

  String? get activeVodId => _activeVodId;
  LoadStatus get status => _status;
  String? get errorMessage => _errorMessage;
  VodInfo? get info => _info;

  Future<void> loadVodInfo(XtreamApiService apiService, String vodId) async {
    _activeVodId = vodId;

    final cached = _cache[vodId];
    if (cached != null) {
      _info = cached;
      _status = LoadStatus.success;
      _errorMessage = null;
      notifyListeners();
      return;
    }

    _status = LoadStatus.loading;
    _errorMessage = null;
    _info = null;
    notifyListeners();

    try {
      final info = await apiService.getVodInfo(vodId);
      _cache[vodId] = info;
      // O usuário pode ter voltado e aberto outro filme enquanto esta
      // chamada ainda estava em voo -- não sobrescreve o estado dele.
      if (_activeVodId != vodId) return;
      _info = info;
      _status = LoadStatus.success;
    } on XtreamApiException catch (e) {
      if (_activeVodId != vodId) return;
      _status = LoadStatus.error;
      _errorMessage = e.message;
    } catch (_) {
      if (_activeVodId != vodId) return;
      _status = LoadStatus.error;
      _errorMessage = 'Não foi possível carregar os detalhes do filme.';
    }

    notifyListeners();
  }

  /// Força nova busca de [vodId] (ignorando o cache) — usado pelo botão
  /// "Tentar novamente".
  Future<void> retry(XtreamApiService apiService, String vodId) {
    _cache.remove(vodId);
    return loadVodInfo(apiService, vodId);
  }
}
