import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exceptions.dart';
import '../models/xtream_models.dart';
import '../models/xtream_parsers.dart';
import '../models/xtream_user_info.dart';
import 'catalog_cache.dart';

// Parsers de listas pesadas: funções de NÍVEL SUPERIOR de propósito, pra
// poderem rodar em outro isolate (Isolate.run) sem capturar nenhum estado.
List<Category> _parseCategories(String body) => asMapList(json.decode(body)).map(Category.fromJson).toList();

List<LiveStream> _parseLiveStreams(String body) => asMapList(json.decode(body)).map(LiveStream.fromJson).toList();

List<VodStream> _parseVodStreams(String body) => asMapList(json.decode(body)).map(VodStream.fromJson).toList();

List<Series> _parseSeriesList(String body) => asMapList(json.decode(body)).map(Series.fromJson).toList();

/// Acima deste tamanho (em caracteres) o JSON é decodificado e convertido
/// em modelos num isolate separado, pra não congelar a interface (catálogos
/// de milhares de canais/filmes levam centenas de ms só no parse). Abaixo
/// disso o custo de criar o isolate não compensa.
const _isolateThresholdChars = 100000;

/// Cliente da API padrão Xtream Codes (`/player_api.php`) de um servidor
/// específico (o `dns_encontrado` resolvido pelo Master Login).
///
/// Cada instância já carrega `dns` + `username` + `password`, então todos os
/// métodos de listagem/detalhe podem ser chamados diretamente após o login.
class XtreamApiService {
  final String dns;
  final String username;
  final String password;

  final http.Client _client;
  final String _baseUrl;

  /// Cache em disco das listas pesadas (categorias e streams). `null` =
  /// sem cache (comportamento antigo; é o que os testes de rede usam).
  final CatalogCache? _cache;

  XtreamApiService({
    required this.dns,
    required this.username,
    required this.password,
    http.Client? client,
    CatalogCache? cache,
  })  : _client = client ?? http.Client(),
        // ignore: prefer_initializing_formals
        _cache = cache,
        _baseUrl = dns.endsWith('/') ? dns.substring(0, dns.length - 1) : dns;

  /// Valida as credenciais no servidor (`action` vazio = autenticação
  /// padrão do `player_api.php`) e retorna os dados da conta.
  Future<XtreamUserInfo> login() async {
    final data = await _getJson({});
    final userInfo = XtreamUserInfo.fromJson(asMap(data));

    if (!userInfo.isAuthenticated) {
      throw const XtreamApiException('Usuário ou senha inválidos no servidor IPTV.');
    }
    if (userInfo.isExpired) {
      throw const XtreamApiException('Assinatura expirada. Entre em contato com o suporte.');
    }

    return userInfo;
  }

  // ---------------------------------------------------------------------
  // Live TV
  // ---------------------------------------------------------------------

  /// `action=get_live_categories` — lista as categorias de canais ao vivo.
  Future<List<Category>> getLiveCategories({bool forceRefresh = false}) {
    return _getList({'action': 'get_live_categories'}, _parseCategories, forceRefresh: forceRefresh);
  }

  /// `action=get_live_streams` — lista os canais ao vivo, opcionalmente
  /// filtrados por `category_id`.
  Future<List<LiveStream>> getLiveStreams({String? categoryId, bool forceRefresh = false}) {
    return _getList(
      {'action': 'get_live_streams', 'category_id': ?categoryId},
      _parseLiveStreams,
      forceRefresh: forceRefresh,
    );
  }

  /// `action=get_short_epg` + `stream_id` — programação "agora"/"a seguir"
  /// de um canal (até [limit] itens; painel decide o que "a seguir"
  /// significa, normalmente 1-4). Chamada SOB DEMANDA, por canal (ver
  /// `_EpgSubtitle` em home_screen.dart) -- nunca em lote para todos os
  /// canais de uma categoria de uma vez, que seria uma explosão de
  /// chamadas de rede.
  Future<List<EpgProgram>> getShortEpg(String streamId, {int limit = 2}) async {
    final data = await _getJson({
      'action': 'get_short_epg',
      'stream_id': streamId,
      'limit': limit.toString(),
    });
    return asMapList(asMap(data)['epg_listings']).map(EpgProgram.fromJson).toList();
  }

  // ---------------------------------------------------------------------
  // VOD (filmes)
  // ---------------------------------------------------------------------

  /// `action=get_vod_categories` — lista as categorias de filmes.
  Future<List<Category>> getVodCategories({bool forceRefresh = false}) {
    return _getList({'action': 'get_vod_categories'}, _parseCategories, forceRefresh: forceRefresh);
  }

  /// `action=get_vod_streams` — lista os filmes, opcionalmente filtrados
  /// por `category_id`.
  Future<List<VodStream>> getVodStreams({String? categoryId, bool forceRefresh = false}) {
    return _getList(
      {'action': 'get_vod_streams', 'category_id': ?categoryId},
      _parseVodStreams,
      forceRefresh: forceRefresh,
    );
  }

  /// `action=get_vod_info` + `vod_id` — detalhes de um filme (sinopse,
  /// elenco, duração etc.), ausentes de [getVodStreams] (listagem).
  Future<VodInfo> getVodInfo(String vodId) async {
    final data = await _getJson({
      'action': 'get_vod_info',
      'vod_id': vodId,
    });
    return VodInfo.fromJson(asMap(data));
  }

  // ---------------------------------------------------------------------
  // Séries
  // ---------------------------------------------------------------------

  /// `action=get_series_categories` — lista as categorias de séries.
  Future<List<Category>> getSeriesCategories({bool forceRefresh = false}) {
    return _getList({'action': 'get_series_categories'}, _parseCategories, forceRefresh: forceRefresh);
  }

  /// `action=get_series` — lista as séries, opcionalmente filtradas por
  /// `category_id`.
  Future<List<Series>> getSeriesList({String? categoryId, bool forceRefresh = false}) {
    return _getList(
      {'action': 'get_series', 'category_id': ?categoryId},
      _parseSeriesList,
      forceRefresh: forceRefresh,
    );
  }

  /// `action=get_series_info` + `series_id` — detalhes de uma série
  /// (sinopse, elenco etc.) e seus episódios agrupados por temporada.
  Future<SeriesInfo> getSeriesInfo(String seriesId) async {
    final data = await _getJson({
      'action': 'get_series_info',
      'series_id': seriesId,
    });
    return SeriesInfo.fromJson(asMap(data));
  }

  // ---------------------------------------------------------------------
  // URLs de stream
  // ---------------------------------------------------------------------

  /// URL de reprodução de um canal ao vivo:
  /// `{dns}/live/{username}/{password}/{streamId}.{ext}`.
  String buildLiveStreamUrl(String streamId, {String ext = 'm3u8'}) {
    return '$_baseUrl/live/$username/$password/$streamId.$ext';
  }

  /// URL de reprodução de um filme:
  /// `{dns}/movie/{username}/{password}/{streamId}.{containerExtension}`.
  String buildVodStreamUrl(String streamId, String containerExtension) {
    return '$_baseUrl/movie/$username/$password/$streamId.$containerExtension';
  }

  /// URL de reprodução de um episódio de série:
  /// `{dns}/series/{username}/{password}/{episodeId}.{containerExtension}`.
  String buildSeriesEpisodeUrl(String episodeId, String containerExtension) {
    return '$_baseUrl/series/$username/$password/$episodeId.$containerExtension';
  }

  // ---------------------------------------------------------------------
  // Infraestrutura HTTP
  // ---------------------------------------------------------------------

  /// Executa um GET em `/player_api.php` com `username`/`password` fixos +
  /// os parâmetros extras de cada endpoint (ex: `action`, `category_id`,
  /// `series_id`), tratando timeout, falha de rede, status HTTP e JSON
  /// malformado com mensagens amigáveis.
  Future<dynamic> _getJson(Map<String, String> queryParams) async {
    final body = await _getBody(queryParams);
    try {
      return json.decode(body);
    } catch (_) {
      throw const XtreamApiException('Resposta inválida do servidor IPTV.');
    }
  }

  /// Lista pesada (categorias/streams) com cache em disco e parse fora da
  /// thread da interface:
  /// 1. cache fresco (dentro do TTL) e sem [forceRefresh]: usa direto, sem rede;
  /// 2. senão, busca na rede e, SÓ depois de o parse dar certo, grava o cache;
  /// 3. rede falhou e existe cache velho: usa o velho (offline) -- exceto em
  ///    [forceRefresh], onde o usuário pediu dado novo e o erro deve aparecer.
  Future<List<T>> _getList<T>(
    Map<String, String> queryParams,
    List<T> Function(String body) parser, {
    bool forceRefresh = false,
  }) async {
    final cache = _cache;
    final key = '$_baseUrl|$username|${queryParams['action']}|${queryParams['category_id'] ?? ''}';

    CachedBody? cached;
    if (cache != null) {
      cached = await cache.read(key);
      if (cached != null && !forceRefresh && cached.isFresh(cache.ttl, cache.now)) {
        try {
          return await _parse(cached.body, parser);
        } catch (_) {
          cached = null; // corrompido: ignora e busca na rede
        }
      }
    }

    final String body;
    try {
      body = await _getBody(queryParams);
    } on XtreamApiException {
      if (cached != null && !forceRefresh) {
        try {
          return await _parse(cached.body, parser);
        } catch (_) {
          // cache velho também inutilizável: mostra o erro de rede real
        }
      }
      rethrow;
    }

    final result = await _parse(body, parser);
    if (cache != null) unawaited(cache.write(key, body));
    return result;
  }

  static Future<List<T>> _parse<T>(String body, List<T> Function(String body) parser) async {
    try {
      if (body.length < _isolateThresholdChars) return parser(body);
      return await Isolate.run(() => parser(body));
    } catch (_) {
      throw const XtreamApiException('Resposta inválida do servidor IPTV.');
    }
  }

  /// GET em `/player_api.php` (credenciais + [queryParams]); devolve o corpo
  /// cru da resposta, já tratando timeout, falha de rede e status HTTP.
  Future<String> _getBody(Map<String, String> queryParams) async {
    final uri = Uri.parse('$_baseUrl${AppConstants.xtreamPlayerApiPath}').replace(
      queryParameters: {
        'username': username,
        'password': password,
        ...queryParams,
      },
    );

    late final http.Response response;
    try {
      response = await _client.get(uri).timeout(AppConstants.networkTimeout);
    } on TimeoutException {
      throw const XtreamApiException(
        'Tempo de conexão esgotado ao falar com o servidor IPTV.',
      );
    } catch (_) {
      throw const XtreamApiException(
        'Não foi possível conectar ao servidor IPTV. Verifique sua conexão.',
      );
    }

    if (response.statusCode != 200) {
      throw XtreamApiException(
        'Servidor IPTV retornou erro (HTTP ${response.statusCode}).',
      );
    }

    return response.body;
  }
}
