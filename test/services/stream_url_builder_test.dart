import 'package:flutter_test/flutter_test.dart';

import 'package:iptv_app/services/stream_url_builder.dart';

const _user = 'cliente_teste';
const _pass = 'senha_teste123';
const _streamId = '12345';

void main() {
  group('build() — live', () {
    test('formato TS direto por stream_id', () {
      final url = StreamUrlBuilder.build(
        dns: 'http://painel.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.live,
        format: StreamFormat.ts,
      );

      expect(url, 'http://painel.com:8080/live/$_user/$_pass/$_streamId.ts');
    });

    test('formato HLS direto por stream_id', () {
      final url = StreamUrlBuilder.build(
        dns: 'http://painel.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.live,
        format: StreamFormat.hls,
      );

      expect(url, 'http://painel.com:8080/live/$_user/$_pass/$_streamId.m3u8');
    });
  });

  group('build() — vod', () {
    test('usa containerExtension informado', () {
      final url = StreamUrlBuilder.build(
        dns: 'http://painel.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.vod,
        format: StreamFormat.ts, // ignorado para vod
        containerExtension: 'mkv',
      );

      expect(url, 'http://painel.com:8080/movie/$_user/$_pass/$_streamId.mkv');
    });

    test('lança MissingContainerExtensionException se containerExtension ausente', () {
      expect(
        () => StreamUrlBuilder.build(
          dns: 'http://painel.com:8080',
          username: _user,
          password: _pass,
          streamId: _streamId,
          contentType: StreamContentType.vod,
          format: StreamFormat.ts,
        ),
        throwsA(isA<MissingContainerExtensionException>()),
      );
    });

    test('lança MissingContainerExtensionException se containerExtension vazio', () {
      expect(
        () => StreamUrlBuilder.build(
          dns: 'http://painel.com:8080',
          username: _user,
          password: _pass,
          streamId: _streamId,
          contentType: StreamContentType.vod,
          format: StreamFormat.ts,
          containerExtension: '   ',
        ),
        throwsA(isA<MissingContainerExtensionException>()),
      );
    });

    test('nunca usa "mp4" como padrão silencioso — extensão vem só do parâmetro', () {
      final url = StreamUrlBuilder.build(
        dns: 'http://painel.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.vod,
        format: StreamFormat.ts,
        containerExtension: 'avi',
      );

      expect(url, endsWith('.avi'));
      expect(url, isNot(contains('.mp4')));
    });
  });

  group('build() — series', () {
    test('usa containerExtension informado (streamId = episode_id)', () {
      final url = StreamUrlBuilder.build(
        dns: 'http://painel.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.series,
        format: StreamFormat.ts,
        containerExtension: 'mp4',
      );

      expect(url, 'http://painel.com:8080/series/$_user/$_pass/$_streamId.mp4');
    });

    test('lança MissingContainerExtensionException se containerExtension ausente', () {
      expect(
        () => StreamUrlBuilder.build(
          dns: 'http://painel.com:8080',
          username: _user,
          password: _pass,
          streamId: _streamId,
          contentType: StreamContentType.series,
          format: StreamFormat.hls,
        ),
        throwsA(isA<MissingContainerExtensionException>()),
      );
    });
  });

  group('sanitização de dns', () {
    test('remove barra final única', () {
      final url = StreamUrlBuilder.build(
        dns: 'http://painel.com:8080/',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.live,
        format: StreamFormat.ts,
      );

      expect(url, 'http://painel.com:8080/live/$_user/$_pass/$_streamId.ts');
    });

    test('remove múltiplas barras finais', () {
      final url = StreamUrlBuilder.build(
        dns: 'http://painel.com:8080///',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.live,
        format: StreamFormat.ts,
      );

      expect(url, 'http://painel.com:8080/live/$_user/$_pass/$_streamId.ts');
    });

    test('sem barra final permanece igual', () {
      final url = StreamUrlBuilder.build(
        dns: 'http://painel.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.live,
        format: StreamFormat.ts,
      );

      expect(url, 'http://painel.com:8080/live/$_user/$_pass/$_streamId.ts');
    });

    test('colapsa protocolo http duplicado, mantendo o último', () {
      final url = StreamUrlBuilder.build(
        dns: 'http://http://painel.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.live,
        format: StreamFormat.ts,
      );

      expect(url, 'http://painel.com:8080/live/$_user/$_pass/$_streamId.ts');
    });

    test('colapsa protocolo https seguido de http duplicado, mantendo o último', () {
      final url = StreamUrlBuilder.build(
        dns: 'https://http://painel.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.live,
        format: StreamFormat.ts,
      );

      expect(url, 'http://painel.com:8080/live/$_user/$_pass/$_streamId.ts');
    });

    test('dns sem protocolo permanece igual (não inventa protocolo)', () {
      final url = StreamUrlBuilder.build(
        dns: 'painel.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.live,
        format: StreamFormat.ts,
      );

      expect(url, 'painel.com:8080/live/$_user/$_pass/$_streamId.ts');
    });

    test('painel estilo Granfox (subdomínio "e.") gera URL correta', () {
      final url = StreamUrlBuilder.build(
        dns: 'http://e.exemplo-painel1.com:8880/',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.live,
        format: StreamFormat.hls,
      );

      expect(url, 'http://e.exemplo-painel1.com:8880/live/$_user/$_pass/$_streamId.m3u8');
    });

    test('painel estilo P2BRAS (domínio direto) gera URL correta', () {
      final url = StreamUrlBuilder.build(
        dns: 'http://painel2-direto.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.live,
        format: StreamFormat.hls,
      );

      expect(url, 'http://painel2-direto.com:8080/live/$_user/$_pass/$_streamId.m3u8');
    });
  });

  group('buildFallbackChain() — live', () {
    test('retorna as 4 URLs na ordem: TS direto, HLS direto, TS get.php, HLS get.php', () {
      final chain = StreamUrlBuilder.buildFallbackChain(
        dns: 'http://painel.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.live,
      );

      expect(chain, [
        'http://painel.com:8080/live/$_user/$_pass/$_streamId.ts',
        'http://painel.com:8080/live/$_user/$_pass/$_streamId.m3u8',
        'http://painel.com:8080/get.php?username=$_user&password=$_pass&type=m3u_plus&output=ts',
        'http://painel.com:8080/get.php?username=$_user&password=$_pass&type=m3u_plus&output=m3u8',
      ]);
    });

    test('funciona igual para dns de painéis diferentes (Granfox/P2BRAS)', () {
      final granfox = StreamUrlBuilder.buildFallbackChain(
        dns: 'http://e.exemplo-painel1.com:8880',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.live,
      );
      final p2bras = StreamUrlBuilder.buildFallbackChain(
        dns: 'http://painel2-direto.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.live,
      );

      expect(granfox, hasLength(4));
      expect(granfox.first, startsWith('http://e.exemplo-painel1.com:8880/live/'));
      expect(p2bras, hasLength(4));
      expect(p2bras.first, startsWith('http://painel2-direto.com:8080/live/'));
    });
  });

  group('buildFallbackChain() — vod/series', () {
    test('vod retorna apenas 1 entrada, sem fallback de formato', () {
      final chain = StreamUrlBuilder.buildFallbackChain(
        dns: 'http://painel.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.vod,
        containerExtension: 'mkv',
      );

      expect(chain, ['http://painel.com:8080/movie/$_user/$_pass/$_streamId.mkv']);
    });

    test('series retorna apenas 1 entrada, sem fallback de formato', () {
      final chain = StreamUrlBuilder.buildFallbackChain(
        dns: 'http://painel.com:8080',
        username: _user,
        password: _pass,
        streamId: _streamId,
        contentType: StreamContentType.series,
        containerExtension: 'mp4',
      );

      expect(chain, ['http://painel.com:8080/series/$_user/$_pass/$_streamId.mp4']);
    });

    test('vod sem containerExtension lança MissingContainerExtensionException', () {
      expect(
        () => StreamUrlBuilder.buildFallbackChain(
          dns: 'http://painel.com:8080',
          username: _user,
          password: _pass,
          streamId: _streamId,
          contentType: StreamContentType.vod,
        ),
        throwsA(isA<MissingContainerExtensionException>()),
      );
    });

    test('series sem containerExtension lança MissingContainerExtensionException', () {
      expect(
        () => StreamUrlBuilder.buildFallbackChain(
          dns: 'http://painel.com:8080',
          username: _user,
          password: _pass,
          streamId: _streamId,
          contentType: StreamContentType.series,
        ),
        throwsA(isA<MissingContainerExtensionException>()),
      );
    });
  });
}
