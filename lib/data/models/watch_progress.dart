import 'xtream_parsers.dart';

/// Tipo de conteúdo rastreado pela seção "Continuar Assistindo" — Live TV
/// nunca gera um [WatchProgress] (não tem posição/duração, ver
/// [PlayerProvider.isLive]), então só existem estes dois casos.
enum WatchProgressType {
  vod,
  episode;

  String get _wireValue => switch (this) {
        WatchProgressType.vod => 'vod',
        WatchProgressType.episode => 'episode',
      };

  static WatchProgressType _fromWire(String value) => switch (value) {
        'episode' => WatchProgressType.episode,
        _ => WatchProgressType.vod,
      };
}

/// Progresso de reprodução de um filme ou episódio, persistido localmente
/// para alimentar a seção "Continuar Assistindo" da HomeScreen.
///
/// [contentId] identifica o conteúdo de forma estável entre sessões
/// (streamId do filme ou id do episódio, como String) — é a chave usada
/// para atualizar/remover o progresso salvo (ver StorageService.saveProgress).
class WatchProgress {
  final String contentId;
  final String title;
  final String imageUrl;
  final int positionSeconds;
  final int durationSeconds;
  final WatchProgressType type;

  /// URL de reprodução já pronta (mesmo formato construído pelos
  /// `build*Url` do XtreamApiService) — salva pronta para não precisar
  /// reconstruir a partir de credenciais/IDs ao retomar.
  final String playbackUrl;
  final DateTime lastWatchedAt;

  const WatchProgress({
    required this.contentId,
    required this.title,
    required this.imageUrl,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.type,
    required this.playbackUrl,
    required this.lastWatchedAt,
  });

  double get fraction =>
      durationSeconds > 0 ? (positionSeconds / durationSeconds).clamp(0, 1) : 0;

  factory WatchProgress.fromJson(Map<String, dynamic> json) {
    return WatchProgress(
      contentId: asString(json['contentId']),
      title: asString(json['title']),
      imageUrl: asString(json['imageUrl']),
      positionSeconds: asInt(json['positionSeconds']),
      durationSeconds: asInt(json['durationSeconds']),
      type: WatchProgressType._fromWire(asString(json['type'])),
      playbackUrl: asString(json['playbackUrl']),
      lastWatchedAt: asUnixDate(json['lastWatchedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'contentId': contentId,
      'title': title,
      'imageUrl': imageUrl,
      'positionSeconds': positionSeconds,
      'durationSeconds': durationSeconds,
      'type': type._wireValue,
      'playbackUrl': playbackUrl,
      'lastWatchedAt': lastWatchedAt.millisecondsSinceEpoch ~/ 1000,
    };
  }
}
