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

  /// [TESTE] Volta ao estado inicial (nenhuma categoria carregada, nenhum
  /// stream em cache) -- chamado por [ContentProvider.updateApiService] ao
  /// detectar troca de servidor. Sem isso, `categoriesStatus == success` de
  /// um servidor ANTERIOR bloqueava `loadCategories` de buscar de novo (ver
  /// aquele método: só busca se `categoriesStatus != success`), e a
  /// categoria selecionada/cache de streams continuavam apontando pra IDs
  /// que só existem no painel antigo -- causa raiz do bug relatado
  /// "trocar de servidor mostra 'nenhum filme encontrado'/canais vazios no
  /// servidor que não foi o primeiro aberto na sessão".
  void reset() {
    categoriesStatus = LoadStatus.idle;
    categoriesError = null;
    categories = const [];
    selectedCategoryId = null;
    streamsStatus = LoadStatus.idle;
    streamsError = null;
    streams = const [];
    _streamsCache.clear();
  }
}

/// Estado das 3 abas de conteúdo (Live TV, VOD, Séries), cada uma com seu
/// próprio ciclo de categorias -> streams, consumindo o [XtreamApiService]
/// já autenticado (via [AuthProvider.apiService]).
///
/// Nenhum widget deve chamar a API diretamente — sempre por aqui, que já
/// trata [XtreamApiException] e expõe mensagens de erro amigáveis.
class ContentProvider extends ChangeNotifier {
  // [TESTE] Nullable + `updateApiService` (em vez de `final ... required`) --
  // este provider agora vive na raiz do app (ver main.dart), não mais só
  // dentro da árvore local da HomeScreen, pra ficar acessível às telas
  // novas do redesenho (CategoryListScreen/LiveChannelsScreen/
  // ContentGridScreen), todas rotas IRMÃS entre si (Navigator.push não
  // aninha uma rota dentro da outra -- ver comentário histórico em
  // vod_details_screen_dpad_test.dart sobre esse mesmo problema com
  // ContinueWatchingProvider). Na raiz do app, porém, `apiService` só
  // existe DEPOIS do login -- por isso nullable aqui, atualizado via
  // `ChangeNotifierProxyProvider<AuthProvider, ContentProvider>` assim que
  // `AuthProvider.apiService` deixa de ser null.
  XtreamApiService? _apiService;

  // Nomeado `apiService` (não `_apiService`) de propósito: um parâmetro
  // nomeado privado não pode ser referenciado por quem instancia a classe
  // fora deste arquivo, então o initializing formal `this._apiService` não
  // se aplica aqui.
  // ignore: prefer_initializing_formals
  ContentProvider({XtreamApiService? apiService}) : _apiService = apiService;

  /// Troca o [XtreamApiService] usado por todas as chamadas subsequentes --
  /// chamado pelo `ChangeNotifierProxyProvider` em main.dart assim que
  /// `AuthProvider.apiService` fica disponível (login) ou muda (trocar de
  /// servidor).
  ///
  /// [TESTE] CORRIGIDO: antes assumia que trocar de servidor recriava este
  /// provider do zero (verdade quando ele vivia dentro da árvore local da
  /// HomeScreen) -- deixou de ser verdade quando ele virou provider de
  /// RAIZ do app (ver doc de [_apiService]): a MESMA instância sobrevive a
  /// qualquer troca de servidor pelo resto da sessão. Sem o reset abaixo,
  /// `live`/`vod`/`series` continuavam com categorias/streams em cache do
  /// servidor ANTERIOR -- `loadCategories` nem tentava buscar de novo
  /// (`categoriesStatus == success` já satisfeito) e a categoria
  /// selecionada/cache de streams apontavam pra IDs que só existem no
  /// painel antigo. Sintoma relatado: trocar de servidor faz o SEGUNDO
  /// (qualquer um que não seja o primeiro aberto na sessão) mostrar
  /// "nenhum filme encontrado"/canais vazios em Ao Vivo/Filmes/Séries.
  /// `identical` (não `==`) de propósito -- um novo login sempre cria uma
  /// instância nova de [XtreamApiService] (ver AuthProvider.login), mesmo
  /// reentrando no MESMO servidor.
  void updateApiService(XtreamApiService apiService) {
    if (_apiService != null && !identical(_apiService, apiService)) {
      live.reset();
      vod.reset();
      series.reset();
      notifyListeners();
    }
    _apiService = apiService;
  }

  /// Asserção de não-nulo no ponto de uso -- seguro porque nenhuma tela que
  /// chega a USAR este provider (tudo a partir da HomeScreen) é alcançável
  /// antes do login (ver checagem `apiService == null` em
  /// home_screen.dart), quando `_apiService` já foi atualizado.
  XtreamApiService get _api {
    assert(_apiService != null, 'ContentProvider usado antes de updateApiService (antes do login)');
    return _apiService!;
  }

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

  /// Carrega SÓ as categorias de [type], injetando "Todos" como primeira
  /// opção. Nenhuma categoria é selecionada sozinha: os streams só são
  /// buscados quando o usuário escolhe uma ([selectCategory]). Antes, "Todos"
  /// era selecionada automaticamente aqui, o que baixava o catálogo INTEIRO
  /// (dezenas de milhares de canais/filmes) só pra mostrar a lista de
  /// categorias. Se já foram carregadas com sucesso nesta sessão, não repete
  /// a chamada de rede (use [refresh] para forçar).
  Future<void> loadCategories(ContentType type) {
    return switch (type) {
      ContentType.live => _loadCategories(live, _api.getLiveCategories, transform: _withAllCategory),
      ContentType.vod => _loadCategories(vod, _api.getVodCategories, transform: _withAllCategory),
      ContentType.series => _loadCategories(series, _api.getSeriesCategories, transform: _withAllCategory),
    };
  }

  static List<Category> _withAllCategory(List<Category> categories) => [_allCategory, ...categories];

  /// "Todos" ([allCategoriesId]) vira uma chamada SEM `category_id` (a
  /// própria API Xtream já devolve tudo nesse caso) — mesma resolução pras
  /// 3 abas, nunca uma soma de chamadas por categoria.
  String? _resolveCategoryId(String categoryId) => categoryId == allCategoriesId ? null : categoryId;

  Future<List<LiveStream>> _fetchLiveStreams(String categoryId, {bool forceRefresh = false}) =>
      _api.getLiveStreams(categoryId: _resolveCategoryId(categoryId), forceRefresh: forceRefresh);

  Future<List<VodStream>> _fetchVodStreams(String categoryId, {bool forceRefresh = false}) =>
      _api.getVodStreams(categoryId: _resolveCategoryId(categoryId), forceRefresh: forceRefresh);

  Future<List<Series>> _fetchSeriesStreams(String categoryId, {bool forceRefresh = false}) =>
      _api.getSeriesList(categoryId: _resolveCategoryId(categoryId), forceRefresh: forceRefresh);

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
          () => _loadCategories(live, () => _api.getLiveCategories(forceRefresh: true), transform: _withAllCategory),
          _fetchLiveStreams,
        ),
      ContentType.vod => _refresh(
          vod,
          () => _loadCategories(vod, () => _api.getVodCategories(forceRefresh: true), transform: _withAllCategory),
          _fetchVodStreams,
        ),
      ContentType.series => _refresh(
          series,
          () => _loadCategories(series, () => _api.getSeriesCategories(forceRefresh: true), transform: _withAllCategory),
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
    Future<List<TStream>> Function(String categoryId, {bool forceRefresh}) fetch, {
    bool forceRefresh = false,
  }) async {
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
      final streams = await fetch(categoryId, forceRefresh: forceRefresh);
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
    Future<List<TStream>> Function(String categoryId, {bool forceRefresh}) fetchStreams,
  ) async {
    state._streamsCache.clear();
    state.categoriesStatus = LoadStatus.idle;
    await loadCategories();

    final selected = state.selectedCategoryId;
    if (selected != null) {
      await _selectCategory(state, selected, fetchStreams, forceRefresh: true);
    }
  }
}
