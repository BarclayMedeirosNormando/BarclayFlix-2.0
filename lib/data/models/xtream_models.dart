import 'xtream_parsers.dart';

/// Categoria genérica, usada tanto para Live TV quanto VOD e Séries
/// (`get_live_categories`, `get_vod_categories`, `get_series_categories`).
class Category {
  final String id;
  final String name;
  final int parentId;

  const Category({
    required this.id,
    required this.name,
    required this.parentId,
  });

  factory Category.fromJson(Map<String, dynamic> json) {
    return Category(
      id: asString(json['category_id']),
      name: asString(json['category_name']),
      parentId: asInt(json['parent_id']),
    );
  }
}

/// Canal de TV ao vivo (`get_live_streams`).
class LiveStream {
  final int streamId;
  final String name;
  final String streamIcon;
  final String categoryId;
  final String? epgChannelId;
  final DateTime? added;
  final bool tvArchive;

  const LiveStream({
    required this.streamId,
    required this.name,
    required this.streamIcon,
    required this.categoryId,
    required this.epgChannelId,
    required this.added,
    required this.tvArchive,
  });

  factory LiveStream.fromJson(Map<String, dynamic> json) {
    return LiveStream(
      streamId: asInt(json['stream_id']),
      name: asString(json['name']),
      streamIcon: asString(json['stream_icon']),
      categoryId: asString(json['category_id']),
      epgChannelId: asStringOrNull(json['epg_channel_id']),
      added: asUnixDate(json['added']),
      tvArchive: asBool(json['tv_archive']),
    );
  }
}

/// Um item de `get_short_epg` (guia de programação) -- "agora" ou "a
/// seguir" num canal, ver `_EpgSubtitle` em home_screen.dart. `title`
/// chega em base64 na API Xtream (ver [asBase64String]).
class EpgProgram {
  final String title;
  final DateTime? start;
  final DateTime? end;

  const EpgProgram({required this.title, required this.start, required this.end});

  factory EpgProgram.fromJson(Map<String, dynamic> json) {
    return EpgProgram(
      title: asBase64String(json['title']),
      start: asUnixDate(json['start_timestamp']),
      end: asUnixDate(json['stop_timestamp']),
    );
  }
}

/// Filme (`get_vod_streams`).
class VodStream {
  final int streamId;
  final String name;
  final String streamIcon;
  final String categoryId;
  final String containerExtension;
  final double rating;
  final DateTime? added;

  const VodStream({
    required this.streamId,
    required this.name,
    required this.streamIcon,
    required this.categoryId,
    required this.containerExtension,
    required this.rating,
    required this.added,
  });

  factory VodStream.fromJson(Map<String, dynamic> json) {
    return VodStream(
      streamId: asInt(json['stream_id']),
      name: asString(json['name']),
      streamIcon: asString(json['stream_icon']),
      categoryId: asString(json['category_id']),
      containerExtension: asString(json['container_extension'], 'mp4'),
      rating: asDouble(json['rating']),
      added: asUnixDate(json['added']),
    );
  }
}

/// Metadados extras de um filme, dentro de `info` em `get_vod_info` --
/// ausentes de `get_vod_streams` (listagem), só chegam ao abrir a ficha do
/// filme (ver VodDetailsProvider/VodDetailsScreen). Mesmos campos de
/// [SeriesDetails] (plot/cast/director/genre/releaseDate/rating) + duração,
/// que só faz sentido pra filme (série tem duração por EPISÓDIO, ver
/// [EpisodeInfo], não pela série inteira).
class VodDetails {
  final String plot;
  final String cast;
  final String director;
  final String genre;
  final String releaseDate;
  final double rating;
  final double durationSecs;

  const VodDetails({
    required this.plot,
    required this.cast,
    required this.director,
    required this.genre,
    required this.releaseDate,
    required this.rating,
    required this.durationSecs,
  });

  factory VodDetails.fromJson(Map<String, dynamic> json) {
    return VodDetails(
      plot: asString(json['plot']),
      cast: asString(json['cast']),
      director: asString(json['director']),
      genre: asString(json['genre']),
      // Alguns painéis retornam "releaseDate", outros "release_date" (mesma
      // inconsistência já tratada em SeriesDetails.fromJson).
      releaseDate: asStringOrNull(json['releaseDate']) ?? asString(json['release_date']),
      rating: asDouble(json['rating']),
      durationSecs: asDouble(json['duration_secs']),
    );
  }
}

/// Resposta completa de `get_vod_info`: só os metadados (`info`) importam
/// aqui -- o objeto irmão `movie_data` da resposta real repete campos que o
/// app já tem via [VodStream] (vindo da listagem, ver HomeScreen), então não
/// há necessidade de um segundo model só pra ele.
class VodInfo {
  final VodDetails info;

  const VodInfo({required this.info});

  factory VodInfo.fromJson(Map<String, dynamic> json) {
    return VodInfo(info: VodDetails.fromJson(asMap(json['info'])));
  }
}

/// Série (`get_series`), sem os episódios — só os metadados de listagem.
class Series {
  final int seriesId;
  final String name;
  final String cover;
  final String plot;
  final String cast;
  final String director;
  final String genre;
  final String releaseDate;
  final double rating;
  final String categoryId;

  const Series({
    required this.seriesId,
    required this.name,
    required this.cover,
    required this.plot,
    required this.cast,
    required this.director,
    required this.genre,
    required this.releaseDate,
    required this.rating,
    required this.categoryId,
  });

  factory Series.fromJson(Map<String, dynamic> json) {
    return Series(
      seriesId: asInt(json['series_id']),
      name: asString(json['name']),
      cover: asString(json['cover']),
      plot: asString(json['plot']),
      cast: asString(json['cast']),
      director: asString(json['director']),
      genre: asString(json['genre']),
      // Alguns painéis retornam "releaseDate", outros "release_date".
      releaseDate: asStringOrNull(json['releaseDate']) ??
          asString(json['release_date']),
      rating: asDouble(json['rating']),
      categoryId: asString(json['category_id']),
    );
  }
}

/// Metadados extras de um episódio (`info`), quando disponíveis. O painel
/// pode retornar `info` como objeto vazio, `[]` ou ausente — nesses casos
/// todos os campos ficam com seus valores padrão.
class EpisodeInfo {
  final String plot;
  final double durationSecs;
  final String movieImage;
  final double rating;

  const EpisodeInfo({
    required this.plot,
    required this.durationSecs,
    required this.movieImage,
    required this.rating,
  });

  factory EpisodeInfo.fromJson(Map<String, dynamic> json) {
    return EpisodeInfo(
      plot: asString(json['plot']),
      durationSecs: asDouble(json['duration_secs']),
      movieImage: asString(json['movie_image']),
      rating: asDouble(json['rating']),
    );
  }
}

/// Episódio de uma série, retornado dentro de `episodes` em
/// `get_series_info`.
class Episode {
  final String id;
  final int episodeNum;
  final String title;
  final String containerExtension;
  final int season;
  final EpisodeInfo info;

  const Episode({
    required this.id,
    required this.episodeNum,
    required this.title,
    required this.containerExtension,
    required this.season,
    required this.info,
  });

  factory Episode.fromJson(Map<String, dynamic> json) {
    return Episode(
      id: asString(json['id']),
      episodeNum: asInt(json['episode_num']),
      title: asString(json['title']),
      containerExtension: asString(json['container_extension'], 'mp4'),
      season: asInt(json['season']),
      info: EpisodeInfo.fromJson(asMap(json['info'])),
    );
  }
}

/// Metadados detalhados de uma série, retornados em `info` de
/// `get_series_info` (mais completos que o [Series] da listagem).
class SeriesDetails {
  final String name;
  final String cover;
  final String plot;
  final String cast;
  final String director;
  final String genre;
  final String releaseDate;
  final double rating;
  final String categoryId;

  const SeriesDetails({
    required this.name,
    required this.cover,
    required this.plot,
    required this.cast,
    required this.director,
    required this.genre,
    required this.releaseDate,
    required this.rating,
    required this.categoryId,
  });

  factory SeriesDetails.fromJson(Map<String, dynamic> json) {
    return SeriesDetails(
      name: asString(json['name']),
      cover: asString(json['cover']),
      plot: asString(json['plot']),
      cast: asString(json['cast']),
      director: asString(json['director']),
      genre: asString(json['genre']),
      releaseDate: asStringOrNull(json['releaseDate']) ??
          asString(json['release_date']),
      rating: asDouble(json['rating']),
      categoryId: asString(json['category_id']),
    );
  }
}

/// Resposta completa de `get_series_info`: metadados da série + episódios
/// agrupados por temporada (chave = número da temporada como String).
class SeriesInfo {
  final SeriesDetails info;
  final Map<String, List<Episode>> seasons;

  const SeriesInfo({
    required this.info,
    required this.seasons,
  });

  factory SeriesInfo.fromJson(Map<String, dynamic> json) {
    final episodesBySeason = asMap(json['episodes']);

    final seasons = episodesBySeason.map((seasonNumber, episodesJson) {
      final episodes = (episodesJson as List? ?? const [])
          .whereType<Map>()
          .map((e) => Episode.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
          .toList();
      return MapEntry(seasonNumber, episodes);
    });

    return SeriesInfo(
      info: SeriesDetails.fromJson(asMap(json['info'])),
      seasons: seasons,
    );
  }
}
