import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exceptions.dart';
import '../models/xtream_models.dart';
import '../models/xtream_parsers.dart';
import '../models/xtream_user_info.dart';

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

  XtreamApiService({
    required this.dns,
    required this.username,
    required this.password,
    http.Client? client,
  })  : _client = client ?? http.Client(),
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
  Future<List<Category>> getLiveCategories() async {
    final data = await _getJson({'action': 'get_live_categories'});
    return asMapList(data).map(Category.fromJson).toList();
  }

  /// `action=get_live_streams` — lista os canais ao vivo, opcionalmente
  /// filtrados por `category_id`.
  Future<List<LiveStream>> getLiveStreams({String? categoryId}) async {
    final data = await _getJson({
      'action': 'get_live_streams',
      'category_id': ?categoryId,
    });
    return asMapList(data).map(LiveStream.fromJson).toList();
  }

  // ---------------------------------------------------------------------
  // VOD (filmes)
  // ---------------------------------------------------------------------

  /// `action=get_vod_categories` — lista as categorias de filmes.
  Future<List<Category>> getVodCategories() async {
    final data = await _getJson({'action': 'get_vod_categories'});
    return asMapList(data).map(Category.fromJson).toList();
  }

  /// `action=get_vod_streams` — lista os filmes, opcionalmente filtrados
  /// por `category_id`.
  Future<List<VodStream>> getVodStreams({String? categoryId}) async {
    final data = await _getJson({
      'action': 'get_vod_streams',
      'category_id': ?categoryId,
    });
    return asMapList(data).map(VodStream.fromJson).toList();
  }

  // ---------------------------------------------------------------------
  // Séries
  // ---------------------------------------------------------------------

  /// `action=get_series_categories` — lista as categorias de séries.
  Future<List<Category>> getSeriesCategories() async {
    final data = await _getJson({'action': 'get_series_categories'});
    return asMapList(data).map(Category.fromJson).toList();
  }

  /// `action=get_series` — lista as séries, opcionalmente filtradas por
  /// `category_id`.
  Future<List<Series>> getSeriesList({String? categoryId}) async {
    final data = await _getJson({
      'action': 'get_series',
      'category_id': ?categoryId,
    });
    return asMapList(data).map(Series.fromJson).toList();
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

    try {
      return json.decode(response.body);
    } catch (_) {
      throw const XtreamApiException('Resposta inválida do servidor IPTV.');
    }
  }
}
