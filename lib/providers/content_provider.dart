// `Category` também existe em package:flutter/foundation.dart (anotação de
// teste) — escondida aqui para não colidir com o model Xtream `Category`.
import 'package:flutter/foundation.dart' hide Category;

import '../core/errors/app_exceptions.dart';
import '../data/models/xtream_models.dart';
import '../data/services/xtream_api_service.dart';

enum ContentType { live, vod, series }

enum LoadStatus { idle, loading, success, error }

/// Estado de uma aba (Live TV, VOD ou Séries): categorias + streams da
/// categoria atualmente selecionada. `TStream` é `LiveStream`, `VodStream`
/// ou `Series`, conforme a aba.
///
/// Os streams de cada categoria já buscada ficam em [_streamsCache] durante
/// a sessão, evitando nova chamada de rede ao reselecionar a mesma
/// categoria — [ContentProvider.refresh] limpa esse cache manualmente.
class TabState<TStream> {
  LoadStatus categoriesStatus = LoadStatus.idle;
  String? categoriesError;
  List<Category> categories = const [];

  String? selectedCategoryId;
  LoadStatus streamsStatus = LoadStatus.idle;
  String? streamsError;
  List<TStream> streams = const [];

  final Map<String, List<TStream>> _streamsCache = {};
}

/// Estado das 3 abas de conteúdo (Live TV, VOD, Séries), cada uma com seu
/// próprio ciclo de categorias -> streams, consumindo o [XtreamApiService]
/// já autenticado (via [AuthProvider.apiService]).
///
/// Nenhum widget deve chamar a API diretamente — sempre por aqui, que já
/// trata [XtreamApiException] e expõe mensagens de erro amigáveis.
class ContentProvider extends ChangeNotifier {
  final XtreamApiService _apiService;

  // Nomeado `apiService` (não `_apiService`) de propósito: um parâmetro
  // nomeado privado não pode ser referenciado por quem instancia a classe
  // fora deste arquivo, então o initializing formal `this._apiService` não
  // se aplica aqui.
  // ignore: prefer_initializing_formals
  ContentProvider({required XtreamApiService apiService}) : _apiService = apiService;

  final TabState<LiveStream> live = TabState<LiveStream>();
  final TabState<VodStream> vod = TabState<VodStream>();
  final TabState<Series> series = TabState<Series>();

  // -- Getters de conveniência (não-genéricos) para a UI não precisar lidar
  // com TabState<T> diretamente ao montar seletores de categoria. --

  List<Category> categoriesFor(ContentType type) => switch (type) {
        ContentType.live => live.categories,
        ContentType.vod => vod.categories,
        ContentType.series => series.categories,
      };

  LoadStatus categoriesStatusFor(ContentType type) => switch (type) {
        ContentType.live => live.categoriesStatus,
        ContentType.vod => vod.categoriesStatus,
        ContentType.series => series.categoriesStatus,
      };

  String? categoriesErrorFor(ContentType type) => switch (type) {
        ContentType.live => live.categoriesError,
        ContentType.vod => vod.categoriesError,
        ContentType.series => series.categoriesError,
      };

  String? selectedCategoryIdFor(ContentType type) => switch (type) {
        ContentType.live => live.selectedCategoryId,
        ContentType.vod => vod.selectedCategoryId,
        ContentType.series => series.selectedCategoryId,
      };

  /// Carrega as categorias de [type]. Se já foram carregadas com sucesso
  /// nesta sessão, não repete a chamada de rede (use [refresh] para forçar).
  Future<void> loadCategories(ContentType type) {
    return switch (type) {
      ContentType.live => _loadCategories(live, _apiService.getLiveCategories),
      ContentType.vod => _loadCategories(vod, _apiService.getVodCategories),
      ContentType.series => _loadCategories(series, _apiService.getSeriesCategories),
    };
  }

  /// Seleciona [categoryId] na aba [type] e carrega os streams dessa
  /// categoria (usando cache em memória quando disponível).
  Future<void> selectCategory(ContentType type, String categoryId) {
    return switch (type) {
      ContentType.live => _selectCategory(
          live,
          categoryId,
          (id) => _apiService.getLiveStreams(categoryId: id),
        ),
      ContentType.vod => _selectCategory(
          vod,
          categoryId,
          (id) => _apiService.getVodStreams(categoryId: id),
        ),
      ContentType.series => _selectCategory(
          series,
          categoryId,
          (id) => _apiService.getSeriesList(categoryId: id),
        ),
    };
  }

  /// Força a releitura das categorias de [type] (ignorando o cache) e, se
  /// houver uma categoria selecionada, recarrega os streams dela também.
  /// Usado tanto para "puxar para atualizar" quanto para o botão "Tentar
  /// novamente" após um erro.
  Future<void> refresh(ContentType type) {
    return switch (type) {
      ContentType.live => _refresh(
          live,
          _apiService.getLiveCategories,
          (id) => _apiService.getLiveStreams(categoryId: id),
        ),
      ContentType.vod => _refresh(
          vod,
          _apiService.getVodCategories,
          (id) => _apiService.getVodStreams(categoryId: id),
        ),
      ContentType.series => _refresh(
          series,
          _apiService.getSeriesCategories,
          (id) => _apiService.getSeriesList(categoryId: id),
        ),
    };
  }

  Future<void> _loadCategories<TStream>(
    TabState<TStream> state,
    Future<List<Category>> Function() fetch,
  ) async {
    if (state.categoriesStatus == LoadStatus.success) return;

    state.categoriesStatus = LoadStatus.loading;
    state.categoriesError = null;
    notifyListeners();

    try {
      state.categories = await fetch();
      state.categoriesStatus = LoadStatus.success;
    } on XtreamApiException catch (e) {
      state.categoriesStatus = LoadStatus.error;
      state.categoriesError = e.message;
    } catch (_) {
      state.categoriesStatus = LoadStatus.error;
      state.categoriesError = 'Não foi possível carregar as categorias.';
    }

    notifyListeners();
  }

  Future<void> _selectCategory<TStream>(
    TabState<TStream> state,
    String categoryId,
    Future<List<TStream>> Function(String categoryId) fetch,
  ) async {
    state.selectedCategoryId = categoryId;

    final cached = state._streamsCache[categoryId];
    if (cached != null) {
      state.streams = cached;
      state.streamsStatus = LoadStatus.success;
      state.streamsError = null;
      notifyListeners();
      return;
    }

    state.streamsStatus = LoadStatus.loading;
    state.streamsError = null;
    notifyListeners();

    try {
      final streams = await fetch(categoryId);
      state.streams = streams;
      state._streamsCache[categoryId] = streams;
      state.streamsStatus = LoadStatus.success;
    } on XtreamApiException catch (e) {
      state.streamsStatus = LoadStatus.error;
      state.streamsError = e.message;
    } catch (_) {
      state.streamsStatus = LoadStatus.error;
      state.streamsError = 'Não foi possível carregar os itens desta categoria.';
    }

    notifyListeners();
  }

  Future<void> _refresh<TStream>(
    TabState<TStream> state,
    Future<List<Category>> Function() fetchCategories,
    Future<List<TStream>> Function(String categoryId) fetchStreams,
  ) async {
    state._streamsCache.clear();
    state.categoriesStatus = LoadStatus.idle;
    await _loadCategories(state, fetchCategories);

    final selected = state.selectedCategoryId;
    if (selected != null) {
      await _selectCategory(state, selected, fetchStreams);
    }
  }
}
