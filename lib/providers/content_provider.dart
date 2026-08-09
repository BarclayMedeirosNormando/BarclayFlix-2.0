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

  /// Id sintético da categoria "Todos" — nunca vem da API. Mesma ideia nas
  /// 3 abas de conteúdo (Live TV, VOD, Séries), cada uma com sua PRÓPRIA
  /// lista de categorias (nunca misturadas entre si, ver [TabState] — um
  /// [_allCategory] por [TabState], não uma lista global compartilhada). Ao
  /// ser selecionada, busca TODOS os itens da aba numa única chamada (mesmo
  /// endpoint já usado por qualquer categoria real, só que sem
  /// `category_id`), nunca uma soma de chamadas por categoria (ver
  /// [_resolveCategoryId]).
  static const String allCategoriesId = '__all__';

  static const Category _allCategory = Category(
    id: allCategoriesId,
    name: 'Todos',
    parentId: 0,
  );

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

  /// Carrega as categorias de [type], injetando "Todos" como primeira opção
  /// e, na primeira carga (nenhuma categoria selecionada ainda), a
  /// selecionando automaticamente — só na primeira, para não sobrescrever
  /// uma escolha do usuário em cargas seguintes (ex: reabrir a aba depois
  /// de já ter escolhido outra categoria). Se já foram carregadas com
  /// sucesso nesta sessão, não repete a chamada de rede (use [refresh] para
  /// forçar).
  Future<void> loadCategories(ContentType type) {
    return switch (type) {
      ContentType.live => _loadCategoriesAndDefaultToAll(live, _apiService.getLiveCategories, _fetchLiveStreams),
      ContentType.vod => _loadCategoriesAndDefaultToAll(vod, _apiService.getVodCategories, _fetchVodStreams),
      ContentType.series =>
        _loadCategoriesAndDefaultToAll(series, _apiService.getSeriesCategories, _fetchSeriesStreams),
    };
  }

  Future<void> _loadCategoriesAndDefaultToAll<TStream>(
    TabState<TStream> state,
    Future<List<Category>> Function() fetchCategories,
    Future<List<TStream>> Function(String categoryId) fetchStreams,
  ) async {
    await _loadCategories(state, fetchCategories, transform: _withAllCategory);

    if (state.categoriesStatus == LoadStatus.success && state.selectedCategoryId == null) {
      await _selectCategory(state, allCategoriesId, fetchStreams);
    }
  }

  static List<Category> _withAllCategory(List<Category> categories) => [_allCategory, ...categories];

  /// "Todos" ([allCategoriesId]) vira uma chamada SEM `category_id` (a
  /// própria API Xtream já devolve tudo nesse caso) — mesma resolução pras
  /// 3 abas, nunca uma soma de chamadas por categoria.
  String? _resolveCategoryId(String categoryId) => categoryId == allCategoriesId ? null : categoryId;

  Future<List<LiveStream>> _fetchLiveStreams(String categoryId) =>
      _apiService.getLiveStreams(categoryId: _resolveCategoryId(categoryId));

  Future<List<VodStream>> _fetchVodStreams(String categoryId) =>
      _apiService.getVodStreams(categoryId: _resolveCategoryId(categoryId));

  Future<List<Series>> _fetchSeriesStreams(String categoryId) =>
      _apiService.getSeriesList(categoryId: _resolveCategoryId(categoryId));

  /// Seleciona [categoryId] na aba [type] e carrega os streams dessa
  /// categoria (usando cache em memória quando disponível).
  Future<void> selectCategory(ContentType type, String categoryId) {
    return switch (type) {
      ContentType.live => _selectCategory(live, categoryId, _fetchLiveStreams),
      ContentType.vod => _selectCategory(vod, categoryId, _fetchVodStreams),
      ContentType.series => _selectCategory(series, categoryId, _fetchSeriesStreams),
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
          () => _loadCategories(live, _apiService.getLiveCategories, transform: _withAllCategory),
          _fetchLiveStreams,
        ),
      ContentType.vod => _refresh(
          vod,
          () => _loadCategories(vod, _apiService.getVodCategories, transform: _withAllCategory),
          _fetchVodStreams,
        ),
      ContentType.series => _refresh(
          series,
          () => _loadCategories(series, _apiService.getSeriesCategories, transform: _withAllCategory),
          _fetchSeriesStreams,
        ),
    };
  }

  Future<void> _loadCategories<TStream>(
    TabState<TStream> state,
    Future<List<Category>> Function() fetch, {
    List<Category> Function(List<Category>)? transform,
  }) async {
    if (state.categoriesStatus == LoadStatus.success) return;

    state.categoriesStatus = LoadStatus.loading;
    state.categoriesError = null;
    notifyListeners();

    try {
      final categories = await fetch();
      state.categories = transform == null ? categories : transform(categories);
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
    Future<void> Function() loadCategories,
    Future<List<TStream>> Function(String categoryId) fetchStreams,
  ) async {
    state._streamsCache.clear();
    state.categoriesStatus = LoadStatus.idle;
    await loadCategories();

    final selected = state.selectedCategoryId;
    if (selected != null) {
      await _selectCategory(state, selected, fetchStreams);
    }
  }
}
