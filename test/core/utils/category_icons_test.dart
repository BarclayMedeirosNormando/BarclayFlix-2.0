import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptv_app/core/utils/category_icons.dart';

void main() {
  group('categoryIcon', () {
    test('reconhece "Ação"/"Action" (com e sem acento, qualquer caixa)', () {
      expect(categoryIcon('Ação'), Icons.local_fire_department);
      expect(categoryIcon('ACAO'), Icons.local_fire_department);
      expect(categoryIcon('US | Action Movies'), Icons.local_fire_department);
    });

    test('reconhece "Comédia"/"Comedy"', () {
      expect(categoryIcon('Comédia'), Icons.theater_comedy);
      expect(categoryIcon('Comedy Central'), Icons.theater_comedy);
    });

    test('reconhece "Documentário"', () {
      expect(categoryIcon('Documentários'), Icons.menu_book);
      expect(categoryIcon('Documentary'), Icons.menu_book);
    });

    test('reconhece "Infantil"/"Kids"', () {
      expect(categoryIcon('Infantil'), Icons.child_care);
      expect(categoryIcon('Kids Zone'), Icons.child_care);
    });

    test('reconhece "Esporte"/"Sport"', () {
      expect(categoryIcon('Esportes'), Icons.sports_soccer);
      expect(categoryIcon('Sports HD'), Icons.sports_soccer);
    });

    test('reconhece "Notícia"/"News"', () {
      expect(categoryIcon('Notícias'), Icons.newspaper);
      expect(categoryIcon('News 24h'), Icons.newspaper);
    });

    test('reconhece "Filme"/"Movie"', () {
      expect(categoryIcon('Filmes Lançamentos'), Icons.movie);
      expect(categoryIcon('Movies'), Icons.movie);
    });

    test('reconhece "Série"/"Series"', () {
      expect(categoryIcon('Séries'), Icons.tv);
      expect(categoryIcon('TV Series'), Icons.tv);
    });

    test('reconhece a categoria sintética "Todos" (Live TV)', () {
      expect(categoryIcon('Todos'), Icons.select_all);
    });

    test('cai no ícone genérico quando nenhuma palavra-chave bate', () {
      expect(categoryIcon('Categoria Misteriosa 123'), Icons.category);
      expect(categoryIcon(''), Icons.category);
    });
  });
}
