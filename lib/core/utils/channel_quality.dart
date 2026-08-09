/// Tag de qualidade reconhecida no NOME de um canal de Live TV (ex: "Globo
/// FHD", "SporTV HD", "Record SD") — puramente textual, igual
/// [categoryIcon] (ver category_icons.dart): sem nenhuma dependência de
/// rede/estado, então fácil de testar isoladamente com uma lista de nomes.
enum ChannelQuality {
  fhd,
  hd,
  sd;

  String get label => switch (this) {
        ChannelQuality.fhd => 'FHD',
        ChannelQuality.hd => 'HD',
        ChannelQuality.sd => 'SD',
      };
}

/// `\b` garante que "HD" não combine com o meio de "FHD" (não há fronteira
/// de palavra entre F e H) — sem isso, todo canal "FHD" também "bateria"
/// com o padrão de HD. Ordem dos grupos não importa para a fronteira, só
/// para qual grupo é capturado.
final RegExp _qualityTagPattern = RegExp(r'\b(FHD|HD|SD)\b', caseSensitive: false);

/// Extrai a tag de qualidade do nome de um canal, quando presente — decide
/// se um canal de Live TV aparece como card com [QualityBadge] (grid) ou na
/// lista simples (ver HomeScreen._LiveStreamsPanel). `null` quando o nome
/// não contém nenhuma das 3 tags reconhecidas.
ChannelQuality? parseChannelQuality(String channelName) {
  final match = _qualityTagPattern.firstMatch(channelName);
  if (match == null) return null;

  return switch (match.group(1)!.toUpperCase()) {
    'FHD' => ChannelQuality.fhd,
    'HD' => ChannelQuality.hd,
    'SD' => ChannelQuality.sd,
    _ => null,
  };
}
