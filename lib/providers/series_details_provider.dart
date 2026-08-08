import 'package:flutter/foundation.dart';

import '../core/errors/app_exceptions.dart';
import '../data/models/xtream_models.dart';
import '../data/services/xtream_api_service.dart';
import 'content_provider.dart' show LoadStatus;

/// Estado de detalhes de uma série (metadados + temporadas/episódios via
/// `get_series_info`).
///
/// Registrado no topo da árvore (junto com [AuthProvider] em `main.dart`),
/// não escopado dentro da HomeScreen como o [ContentProvider] — este último
/// é recriado a cada build da HomeScreen e nem seria alcançável pelas rotas
/// empilhadas por cima dela (mesmo motivo pelo qual a PlayerScreen já
/// recebe url/title prontos em vez de ler o ContentProvider). Um provider
/// próprio, vivo pela sessão inteira, é o que permite o cache abaixo
/// sobreviver ao push/pop da tela de detalhes.
class SeriesDetailsProvider extends ChangeNotifier {
  final Map<String, SeriesInfo> _cache = {};

  String? _activeSeriesId;
  LoadStatus _status = LoadStatus.idle;
  String? _errorMessage;
  SeriesInfo? _info;

  String? get activeSeriesId => _activeSeriesId;
  LoadStatus get status => _status;
  String? get errorMessage => _errorMessage;
  SeriesInfo? get info => _info;

  /// Carrega os detalhes de [seriesId] via [apiService]. Se já estiverem em
  /// cache (visita anterior na mesma sessão), reaproveita sem nova chamada
  /// de rede.
  Future<void> loadSeriesInfo(XtreamApiService apiService, String seriesId) async {
    _activeSeriesId = seriesId;

    final cached = _cache[seriesId];
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
      final info = await apiService.getSeriesInfo(seriesId);
      _cache[seriesId] = info;
      // O usuário pode ter voltado e aberto outra série enquanto esta
      // chamada ainda estava em voo — não sobrescreve o estado dela.
      if (_activeSeriesId != seriesId) return;
      _info = info;
      _status = LoadStatus.success;
    } on XtreamApiException catch (e) {
      if (_activeSeriesId != seriesId) return;
      _status = LoadStatus.error;
      _errorMessage = e.message;
    } catch (_) {
      if (_activeSeriesId != seriesId) return;
      _status = LoadStatus.error;
      _errorMessage = 'Não foi possível carregar os detalhes da série.';
    }

    notifyListeners();
  }

  /// Força nova busca de [seriesId] (ignorando o cache) — usado pelo botão
  /// "Tentar novamente".
  Future<void> retry(XtreamApiService apiService, String seriesId) {
    _cache.remove(seriesId);
    return loadSeriesInfo(apiService, seriesId);
  }
}
