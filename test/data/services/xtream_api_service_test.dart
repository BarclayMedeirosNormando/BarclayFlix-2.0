import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:iptv_app/core/errors/app_exceptions.dart';
import 'package:iptv_app/data/services/xtream_api_service.dart';

const _testDns = 'http://servidor-teste.com:8080';
const _testUser = 'cliente_teste';
const _testPass = 'senha_teste123';

/// Monta um [XtreamApiService] apontando para [_testDns]/[_testUser]/
/// [_testPass], usando [handler] como resposta simulada (via [MockClient])
/// no lugar de uma chamada de rede real.
XtreamApiService _buildService(
  Future<http.Response> Function(http.Request request) handler,
) {
  return XtreamApiService(
    dns: _testDns,
    username: _testUser,
    password: _testPass,
    client: MockClient(handler),
  );
}

http.Response _jsonResponse(Object body, {int statusCode = 200}) {
  return http.Response(jsonEncode(body), statusCode);
}

void main() {
  group('login()', () {
    test('retorna XtreamUserInfo autenticado a partir de um user_info válido', () async {
      final service = _buildService((request) async {
        expect(request.url.queryParameters['username'], _testUser);
        expect(request.url.queryParameters['password'], _testPass);
        return _jsonResponse({
          'user_info': {
            'username': _testUser,
            'auth': 1,
            'status': 'Active',
            'exp_date': '9999999999',
            'is_trial': '0',
            'active_cons': '0',
            'max_connections': '1',
          },
          'server_info': {
            'url': 'servidor-teste.com',
            'port': '8080',
          },
        });
      });

      final userInfo = await service.login();

      expect(userInfo.username, _testUser);
      expect(userInfo.isAuthenticated, isTrue);
      expect(userInfo.status, 'Active');
      expect(userInfo.maxConnections, 1);
    });

    test('lança XtreamApiException quando auth=0 (credenciais inválidas)', () async {
      final service = _buildService((request) async {
        return _jsonResponse({
          'user_info': {'auth': 0},
        });
      });

      await expectLater(service.login(), throwsA(isA<XtreamApiException>()));
    });

    test('lança XtreamApiException quando a API responde um array vazio inesperado', () async {
      // Alguns painéis Xtream retornam `[]` no lugar de um objeto user_info
      // quando o login falha.
      final service = _buildService((request) async {
        return http.Response('[]', 200);
      });

      await expectLater(service.login(), throwsA(isA<XtreamApiException>()));
    });
  });

  group('Live TV', () {
    test('getLiveCategories retorna a lista de categorias parseada', () async {
      final service = _buildService((request) async {
        expect(request.url.queryParameters['action'], 'get_live_categories');
        return _jsonResponse([
          {'category_id': '1', 'category_name': 'Esportes', 'parent_id': 0},
          {'category_id': '2', 'category_name': 'Filmes 24h', 'parent_id': 0},
        ]);
      });

      final categories = await service.getLiveCategories();

      expect(categories, hasLength(2));
      expect(categories[0].id, '1');
      expect(categories[0].name, 'Esportes');
      expect(categories[1].name, 'Filmes 24h');
    });

    test('getLiveStreams envia category_id quando informado e retorna os canais', () async {
      final service = _buildService((request) async {
        expect(request.url.queryParameters['action'], 'get_live_streams');
        expect(request.url.queryParameters['category_id'], '1');
        return _jsonResponse([
          {
            'stream_id': 10001,
            'name': 'ESPN HD',
            'stream_icon': 'http://img/espn.png',
            'category_id': '1',
            'epg_channel_id': 'espn.us',
            'added': '1690000000',
            'tv_archive': 1,
          },
        ]);
      });

      final streams = await service.getLiveStreams(categoryId: '1');

      expect(streams, hasLength(1));
      final stream = streams.single;
      expect(stream.streamId, 10001);
      expect(stream.name, 'ESPN HD');
      expect(stream.epgChannelId, 'espn.us');
      expect(stream.tvArchive, isTrue);
      expect(stream.added, DateTime.fromMillisecondsSinceEpoch(1690000000 * 1000));
    });

    test('getLiveStreams não envia category_id quando omitido', () async {
      final service = _buildService((request) async {
        expect(request.url.queryParameters.containsKey('category_id'), isFalse);
        return _jsonResponse(const []);
      });

      await service.getLiveStreams();
    });

    test('getShortEpg decodifica title (base64) e envia stream_id/limit', () async {
      final service = _buildService((request) async {
        expect(request.url.queryParameters['action'], 'get_short_epg');
        expect(request.url.queryParameters['stream_id'], '10001');
        expect(request.url.queryParameters['limit'], '2');
        return _jsonResponse({
          'epg_listings': [
            {
              'title': base64Encode(utf8.encode('Jornal da Noite')),
              'start_timestamp': '1690000000',
              'stop_timestamp': '1690003600',
            },
            {
              'title': base64Encode(utf8.encode('Filme da Madrugada')),
              'start_timestamp': '1690003600',
              'stop_timestamp': '1690010800',
            },
          ],
        });
      });

      final programs = await service.getShortEpg('10001');

      expect(programs, hasLength(2));
      expect(programs[0].title, 'Jornal da Noite');
      expect(programs[0].start, DateTime.fromMillisecondsSinceEpoch(1690000000 * 1000));
      expect(programs[1].title, 'Filme da Madrugada');
    });

    test('getShortEpg cai pro texto original quando title não é base64 válido', () async {
      final service = _buildService((request) async {
        return _jsonResponse({
          'epg_listings': [
            {'title': 'Texto puro sem encoding', 'start_timestamp': '0', 'stop_timestamp': '0'},
          ],
        });
      });

      final programs = await service.getShortEpg('10001');

      expect(programs.single.title, 'Texto puro sem encoding');
      expect(programs.single.start, isNull);
    });
  });

  group('VOD (filmes)', () {
    test('getVodCategories retorna a lista de categorias parseada', () async {
      final service = _buildService((request) async {
        expect(request.url.queryParameters['action'], 'get_vod_categories');
        return _jsonResponse([
          {'category_id': '10', 'category_name': 'Lançamentos', 'parent_id': 0},
        ]);
      });

      final categories = await service.getVodCategories();

      expect(categories, hasLength(1));
      expect(categories.single.name, 'Lançamentos');
    });

    test('getVodStreams retorna os filmes parseados', () async {
      final service = _buildService((request) async {
        expect(request.url.queryParameters['action'], 'get_vod_streams');
        return _jsonResponse([
          {
            'stream_id': 5001,
            'name': 'Matrix',
            'stream_icon': 'http://img/matrix.jpg',
            'category_id': '10',
            'rating': '8.7',
            'added': '1690000000',
            'container_extension': 'mkv',
          },
        ]);
      });

      final movies = await service.getVodStreams(categoryId: '10');

      expect(movies, hasLength(1));
      final movie = movies.single;
      expect(movie.streamId, 5001);
      expect(movie.name, 'Matrix');
      expect(movie.containerExtension, 'mkv');
      expect(movie.rating, 8.7);
    });

    test('getVodInfo retorna os metadados parseados', () async {
      final service = _buildService((request) async {
        expect(request.url.queryParameters['action'], 'get_vod_info');
        expect(request.url.queryParameters['vod_id'], '5001');
        return _jsonResponse({
          'info': {
            'plot': 'Um hacker descobre a verdade sobre sua realidade.',
            'cast': 'Keanu Reeves, Laurence Fishburne',
            'director': 'Wachowski',
            'genre': 'Ficção científica',
            'releaseDate': '1999-03-31',
            'rating': '8.7',
            'duration_secs': 8160,
          },
          'movie_data': {'stream_id': 5001},
        });
      });

      final vodInfo = await service.getVodInfo('5001');

      expect(vodInfo.info.plot, 'Um hacker descobre a verdade sobre sua realidade.');
      expect(vodInfo.info.cast, 'Keanu Reeves, Laurence Fishburne');
      expect(vodInfo.info.genre, 'Ficção científica');
      expect(vodInfo.info.rating, 8.7);
      expect(vodInfo.info.durationSecs, 8160);
    });
  });

  group('Séries', () {
    test('getSeriesCategories retorna a lista de categorias parseada', () async {
      final service = _buildService((request) async {
        expect(request.url.queryParameters['action'], 'get_series_categories');
        return _jsonResponse([
          {'category_id': '20', 'category_name': 'Séries', 'parent_id': 0},
        ]);
      });

      final categories = await service.getSeriesCategories();

      expect(categories, hasLength(1));
      expect(categories.single.name, 'Séries');
    });

    test('getSeriesList retorna as séries parseadas', () async {
      final service = _buildService((request) async {
        expect(request.url.queryParameters['action'], 'get_series');
        return _jsonResponse([
          {
            'series_id': 301,
            'name': 'Breaking Bad',
            'cover': 'http://img/bb.jpg',
            'plot': 'Um professor de química se torna fabricante de metanfetamina.',
            'cast': 'Bryan Cranston, Aaron Paul',
            'director': 'Vince Gilligan',
            'genre': 'Drama',
            'releaseDate': '2008-01-20',
            'rating': '9.5',
            'category_id': '20',
          },
        ]);
      });

      final series = await service.getSeriesList(categoryId: '20');

      expect(series, hasLength(1));
      final show = series.single;
      expect(show.seriesId, 301);
      expect(show.name, 'Breaking Bad');
      expect(show.releaseDate, '2008-01-20');
      expect(show.rating, 9.5);
    });

    test('getSeriesInfo agrupa episódios por temporada corretamente', () async {
      final service = _buildService((request) async {
        expect(request.url.queryParameters['action'], 'get_series_info');
        expect(request.url.queryParameters['series_id'], '301');
        return _jsonResponse({
          'info': {
            'name': 'Breaking Bad',
            'cover': 'http://img/bb.jpg',
            'plot': 'Um professor de química se torna fabricante de metanfetamina.',
            'cast': 'Bryan Cranston, Aaron Paul',
            'director': 'Vince Gilligan',
            'genre': 'Drama',
            'releaseDate': '2008-01-20',
            'rating': '9.5',
            'category_id': '20',
          },
          'episodes': {
            '1': [
              {
                'id': '3001',
                'episode_num': 1,
                'title': 'Pilot',
                'container_extension': 'mkv',
                'season': 1,
                'info': {
                  'plot': 'Walter White descobre que tem câncer.',
                  'duration_secs': 2760,
                  'movie_image': 'http://img/ep1.jpg',
                  'rating': '9.0',
                },
              },
              {
                'id': '3002',
                'episode_num': 2,
                'title': "Cat's in the Bag...",
                'container_extension': 'mkv',
                'season': 1,
                'info': <String, dynamic>{},
              },
            ],
            '2': [
              {
                'id': '3010',
                'episode_num': 1,
                'title': 'Seven Thirty-Seven',
                'container_extension': 'mkv',
                'season': 2,
                'info': {
                  'plot': null,
                  'duration_secs': '2700',
                  'rating': null,
                },
              },
            ],
          },
        });
      });

      final seriesInfo = await service.getSeriesInfo('301');

      expect(seriesInfo.info.name, 'Breaking Bad');
      expect(seriesInfo.seasons.keys, containsAll(['1', '2']));
      expect(seriesInfo.seasons['1'], hasLength(2));
      expect(seriesInfo.seasons['2'], hasLength(1));

      final pilot = seriesInfo.seasons['1']!.first;
      expect(pilot.title, 'Pilot');
      expect(pilot.season, 1);
      expect(pilot.info.durationSecs, 2760);
      expect(pilot.info.rating, 9.0);

      final secondEpisode = seriesInfo.seasons['1']![1];
      expect(secondEpisode.title, "Cat's in the Bag...");
      expect(secondEpisode.info.plot, ''); // info vazio -> fallback

      final season2Episode = seriesInfo.seasons['2']!.single;
      expect(season2Episode.info.durationSecs, 2700); // veio como String
      expect(season2Episode.info.rating, 0.0); // rating null -> fallback
    });
  });

  group('Parsing defensivo', () {
    test('parseia stream_id vindo como String sem lançar exceção', () async {
      final service = _buildService((request) async {
        return _jsonResponse([
          {
            'stream_id': '10001', // número como String
            'name': 'Canal Teste',
            'category_id': '1',
          },
        ]);
      });

      final streams = await service.getLiveStreams();

      expect(streams.single.streamId, 10001);
    });

    test('usa fallbacks sensatos para campos ausentes/nulos (stream_icon ausente, rating null)', () async {
      final service = _buildService((request) async {
        return _jsonResponse([
          {
            'stream_id': 5002,
            'name': 'Filme Sem Capa',
            'category_id': '10',
            // 'stream_icon' ausente de propósito
            'rating': null,
            'container_extension': null,
          },
        ]);
      });

      final movies = await service.getVodStreams();

      final movie = movies.single;
      expect(movie.streamIcon, '');
      expect(movie.rating, 0.0);
      expect(movie.containerExtension, 'mp4'); // fallback definido no model
      expect(movie.added, isNull);
    });

    test('retorna lista vazia quando a categoria não tem streams ([])', () async {
      final service = _buildService((request) async {
        return _jsonResponse(const []);
      });

      final streams = await service.getLiveStreams(categoryId: '999');

      expect(streams, isEmpty);
    });

    test('retorna lista vazia (não lança exceção) quando a API responde um objeto no lugar de array', () async {
      final service = _buildService((request) async {
        return _jsonResponse(const {'unexpected': 'shape'});
      });

      final categories = await service.getLiveCategories();

      expect(categories, isEmpty);
    });
  });

  group('Erros de rede/HTTP', () {
    test('lança XtreamApiException em caso de timeout de conexão', () {
      fakeAsync((async) {
        final service = _buildService((request) async {
          await Future<void>.delayed(const Duration(seconds: 20));
          return _jsonResponse(const []);
        });

        Object? capturedError;
        service.getLiveCategories().then((_) {}).catchError((Object error) {
          capturedError = error;
        });

        async.elapse(const Duration(seconds: 16));

        expect(capturedError, isA<XtreamApiException>());
      });
    });

    test('lança XtreamApiException quando o servidor responde HTTP 401', () async {
      final service = _buildService((request) async {
        return http.Response('Unauthorized', 401);
      });

      await expectLater(service.getLiveCategories(), throwsA(isA<XtreamApiException>()));
    });

    test('lança XtreamApiException quando o servidor responde HTTP 500', () async {
      final service = _buildService((request) async {
        return http.Response('Internal Server Error', 500);
      });

      await expectLater(service.getVodStreams(), throwsA(isA<XtreamApiException>()));
    });

    test('lança XtreamApiException para corpo vazio (não deixa FormatException vazar)', () async {
      final service = _buildService((request) async {
        return http.Response('', 200);
      });

      await expectLater(service.getSeriesCategories(), throwsA(isA<XtreamApiException>()));
    });

    test('lança XtreamApiException para JSON malformado (não deixa FormatException vazar)', () async {
      final service = _buildService((request) async {
        return http.Response('{"stream_id": 1,,,}', 200);
      });

      await expectLater(service.getLiveStreams(), throwsA(isA<XtreamApiException>()));
    });

    test('lança XtreamApiException quando o corpo é HTML (dns errado apontando pra página de erro)', () async {
      final service = _buildService((request) async {
        return http.Response(
          '<html><head><title>404</title></head><body>Not Found</body></html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      });

      await expectLater(service.getSeriesList(), throwsA(isA<XtreamApiException>()));
    });
  });

  group('Builders de URL', () {
    test('buildLiveStreamUrl monta a URL no formato {dns}/live/{user}/{pass}/{streamId}.{ext}', () {
      final service = XtreamApiService(dns: _testDns, username: _testUser, password: _testPass);

      expect(
        service.buildLiveStreamUrl('10001'),
        '$_testDns/live/$_testUser/$_testPass/10001.m3u8',
      );
      expect(
        service.buildLiveStreamUrl('10001', ext: 'ts'),
        '$_testDns/live/$_testUser/$_testPass/10001.ts',
      );
    });

    test('buildVodStreamUrl monta a URL no formato {dns}/movie/{user}/{pass}/{streamId}.{ext}', () {
      final service = XtreamApiService(dns: _testDns, username: _testUser, password: _testPass);

      expect(
        service.buildVodStreamUrl('5001', 'mkv'),
        '$_testDns/movie/$_testUser/$_testPass/5001.mkv',
      );
    });

    test('buildSeriesEpisodeUrl monta a URL no formato {dns}/series/{user}/{pass}/{episodeId}.{ext}', () {
      final service = XtreamApiService(dns: _testDns, username: _testUser, password: _testPass);

      expect(
        service.buildSeriesEpisodeUrl('3001', 'mkv'),
        '$_testDns/series/$_testUser/$_testPass/3001.mkv',
      );
    });

    test('builders removem a barra final do dns antes de montar a URL', () {
      final service = XtreamApiService(
        dns: '$_testDns/',
        username: _testUser,
        password: _testPass,
      );

      expect(
        service.buildLiveStreamUrl('10001'),
        '$_testDns/live/$_testUser/$_testPass/10001.m3u8',
      );
    });
  });
}
