/// Formato de container solicitado para um stream — só se aplica a Live TV
/// (VOD/série sempre usam a extensão original vinda de `container_extension`
/// da API, ver [StreamContentType]).
enum StreamFormat { ts, hls }

enum StreamContentType { live, vod, series }

/// Erro lançado quando [StreamUrlBuilder] precisa de `containerExtension`
/// (VOD/série) e ele não foi informado. Nunca usa `'mp4'` como padrão
/// silencioso porque cada VOD pode ter uma extensão diferente conforme
/// retornado pela API — um valor errado aqui resultaria numa URL de
/// reprodução que simplesmente não existe no servidor.
class MissingContainerExtensionException implements Exception {
  final String message;

  const MissingContainerExtensionException(this.message);

  @override
  String toString() => message;
}

/// Monta URLs de reprodução Xtream Codes a partir de um `dns` já resolvido
/// pelo Master Login (`SavedProfile.dns`) — esta classe nunca conhece nem
/// assume nenhum domínio de painel específico, apenas recebe [dns] de fora
/// e monta o restante da URL em cima dele. Painéis diferentes (ex: Granfox/
/// TVPlay, P2BRAS/tvlol32) usam domínios completamente distintos, mas o
/// mesmo padrão de rotas Xtream Codes por baixo.
///
/// Não faz nenhuma chamada de rede — só montagem de string.
class StreamUrlBuilder {
  StreamUrlBuilder._();

  /// Monta a URL direta por `stream_id`/`episode_id` — mais eficiente que
  /// `get.php` (que baixa a playlist `m3u` inteira) porque aponta direto pro
  /// stream desejado.
  ///
  /// `{dns}/live/{user}/{pass}/{streamId}.{ts|m3u8}` (Live TV, [format]
  /// escolhe a extensão) `{dns}/movie/{user}/{pass}/{streamId}.{ext}` (VOD)
  /// `{dns}/series/{user}/{pass}/{streamId}.{ext}` (série, `streamId` aqui é
  /// o `episode_id`)
  ///
  /// [containerExtension] é obrigatório para [StreamContentType.vod] e
  /// [StreamContentType.series] — lança [MissingContainerExtensionException]
  /// se ausente, em vez de silenciosamente assumir uma extensão fixa.
  static String build({
    required String dns,
    required String username,
    required String password,
    required String streamId,
    required StreamContentType contentType,
    required StreamFormat format,
    String? containerExtension,
  }) {
    final baseUrl = _sanitizeDns(dns);

    switch (contentType) {
      case StreamContentType.live:
        final ext = format == StreamFormat.ts ? 'ts' : 'm3u8';
        return '$baseUrl/live/$username/$password/$streamId.$ext';
      case StreamContentType.vod:
        final ext = _requireContainerExtension(containerExtension, 'VOD');
        return '$baseUrl/movie/$username/$password/$streamId.$ext';
      case StreamContentType.series:
        final ext = _requireContainerExtension(containerExtension, 'série');
        return '$baseUrl/series/$username/$password/$streamId.$ext';
    }
  }

  /// Cadeia de URLs alternativas a percorrer em caso de falha de reprodução
  /// (consumida sequencialmente por `PlaybackHealthMonitor`).
  ///
  /// Para [StreamContentType.live]: até 4 entradas, na ordem
  /// TS direto -> HLS direto -> TS via `get.php` -> HLS via `get.php` (o
  /// padrão `get.php` é só um fallback de compatibilidade para painéis onde
  /// o direto por `stream_id` falha).
  ///
  /// Para VOD/série: apenas 1 entrada (a extensão original vinda da API) —
  /// não existe fallback de formato para VOD, só retry de conexão na mesma
  /// URL (responsabilidade do monitor, não deste builder).
  static List<String> buildFallbackChain({
    required String dns,
    required String username,
    required String password,
    required String streamId,
    required StreamContentType contentType,
    String? containerExtension,
  }) {
    final baseUrl = _sanitizeDns(dns);

    switch (contentType) {
      case StreamContentType.live:
        return [
          '$baseUrl/live/$username/$password/$streamId.ts',
          '$baseUrl/live/$username/$password/$streamId.m3u8',
          _getPhpUrl(baseUrl, username, password, 'ts'),
          _getPhpUrl(baseUrl, username, password, 'm3u8'),
        ];
      case StreamContentType.vod:
        final ext = _requireContainerExtension(containerExtension, 'VOD');
        return ['$baseUrl/movie/$username/$password/$streamId.$ext'];
      case StreamContentType.series:
        final ext = _requireContainerExtension(containerExtension, 'série');
        return ['$baseUrl/series/$username/$password/$streamId.$ext'];
    }
  }

  static String _requireContainerExtension(String? containerExtension, String label) {
    if (containerExtension == null || containerExtension.trim().isEmpty) {
      throw MissingContainerExtensionException(
        'containerExtension é obrigatório para montar a URL de $label — '
        'verifique se o valor de container_extension da API foi propagado '
        'até aqui.',
      );
    }
    return containerExtension;
  }

  /// `{dns}/get.php?username={user}&password={pass}&type=m3u_plus&output={ts|m3u8}`
  /// — playlist Xtream Codes completa, usado só como fallback do padrão
  /// direto por `stream_id`.
  static String _getPhpUrl(String baseUrl, String username, String password, String output) {
    final query = {
      'username': username,
      'password': password,
      'type': 'm3u_plus',
      'output': output,
    }.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
    return '$baseUrl/get.php?$query';
  }

  /// Remove barra(s) final(is) e colapsa protocolo duplicado no início (ex:
  /// `http://http://painel.com` ou `https://http://painel.com`, mantendo
  /// sempre o último) — defensivo mesmo com `dns` já vindo "sanitizado" do
  /// `SavedProfile`, para não propagar uma URL quebrada caso alguma etapa
  /// anterior do fluxo tenha anteposto um protocolo extra.
  static String _sanitizeDns(String dns) {
    var result = dns.trim();

    final leadingProtocols = RegExp(r'^(https?://)+').firstMatch(result)?.group(0);
    if (leadingProtocols != null) {
      final protocolMatches = RegExp(r'https?://').allMatches(leadingProtocols).toList();
      if (protocolMatches.length > 1) {
        result = result.substring(protocolMatches.last.start);
      }
    }

    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }

    return result;
  }
}
