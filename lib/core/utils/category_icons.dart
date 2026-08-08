import 'package:flutter/material.dart';

/// Mapeia o nome de uma categoria (Live TV/VOD/Séries, como vem da API
/// Xtream) para um ícone representativo, por palavra-chave — puramente
/// textual, sem nenhuma dependência de rede/estado, então fácil de testar
/// isoladamente com uma lista de nomes de exemplo.
///
/// Cada painel Xtream nomeia categorias do seu próprio jeito (com/sem
/// acento, em português ou inglês, tudo maiúsculo...) — por isso a
/// comparação é sempre em minúsculas e aceita as duas grafias (com e sem
/// acento) dos termos em português. Nenhuma palavra-chave reconhecida cai
/// no ícone genérico [Icons.category].
IconData categoryIcon(String categoryName) {
  final name = categoryName.toLowerCase();

  bool has(List<String> keywords) => keywords.any(name.contains);

  if (has(['ação', 'acao', 'action'])) return Icons.local_fire_department;
  if (has(['comédia', 'comedia', 'comedy'])) return Icons.theater_comedy;
  if (has(['documentário', 'documentario', 'document'])) return Icons.menu_book;
  if (has(['infantil', 'kids'])) return Icons.child_care;
  if (has(['esporte', 'sport'])) return Icons.sports_soccer;
  if (has(['notícia', 'noticia', 'news'])) return Icons.newspaper;
  if (has(['filme', 'movie'])) return Icons.movie;
  if (has(['série', 'serie', 'series'])) return Icons.tv;

  return Icons.category;
}
