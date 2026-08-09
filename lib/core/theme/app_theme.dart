import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const Color primaryColor = Color(0xFF1E88E5);
  static const Color backgroundColor = Color(0xFF121212);
  static const Color surfaceColor = Color(0xFF1E1E1E);
  static const Color errorColor = Color(0xFFCF6679);

  /// Título/legenda de qualquer card de conteúdo (Live TV, VOD, Séries,
  /// Continuar Assistindo) — usado em TODOS eles de propósito (ver
  /// AppCardSizes), pra uma eventual mudança de escala futura ser central,
  /// não uma caça por estilos ad-hoc espalhados. `12` é o piso de
  /// legibilidade a distância de TV (ver AppCardSizes.minCardFontSize) —
  /// não reduz mais que isso mesmo com os cards menores.
  static const TextStyle cardTitleStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w600);

  /// Nome do canal em Live TV (lista simples E cards com [QualityBadge], ver
  /// HomeScreen._LiveStreamsPanel) — ~40% menor que [cardTitleStyle] a
  /// pedido do ajuste de UI (12 * 0.6 = 7.2), mas nunca abaixo do piso de
  /// legibilidade a distância de sofá pedido junto (10-11px): 7.2 ficaria
  /// ilegível numa TV, então o piso prevalece sobre o multiplicador exato.
  /// Deliberadamente SEPARADO de [cardTitleStyle] (não uma redução do
  /// próprio valor compartilhado) para não afetar VOD/Séries/Continuar
  /// Assistindo, que continuam com o tamanho de sempre.
  static const TextStyle liveChannelNameStyle = TextStyle(fontSize: 11, fontWeight: FontWeight.w600);

  /// Nome do canal/filme/episódio na barra superior do OSD do player —
  /// maior/mais peso que o título de card, já que é o único texto na tela
  /// enquanto o conteúdo toca. A sombra compensa o OSD (Bloco 2) só ter
  /// gradiente escurecendo a base da tela, não o topo — sem ela o título
  /// perderia contraste sobre um vídeo claro.
  static const TextStyle playerTitleStyle = TextStyle(
    color: Colors.white,
    fontSize: 20,
    fontWeight: FontWeight.bold,
    shadows: [Shadow(color: Colors.black87, blurRadius: 8, offset: Offset(0, 1))],
  );

  static ThemeData get darkTheme {
    final base = ThemeData.dark(useMaterial3: true);

    return base.copyWith(
      // Fonte única centralizada aqui: os `TextStyle` ad-hoc espalhados
      // pelas telas (incluindo cardTitleStyle/playerTitleStyle acima) não
      // declaram `fontFamily` — herdam a família Inter deste textTheme via
      // o merge padrão do Flutter com o DefaultTextStyle ambiente, sem
      // precisar tocar em cada um deles.
      //
      // De propósito NÃO usa `GoogleFonts.interTextTheme()` aqui: aquele
      // helper resolve cada peso chamando o carregador dinâmico do pacote
      // (`FontLoader` + busca no asset manifest por um arquivo cujo nome
      // termine em "Inter-Regular"/"Inter-Medium"/"Inter-SemiBold" etc. —
      // a convenção de nomes ESTÁTICOS por peso que a Google Fonts usava).
      // A fonte variável que baixamos (ver assets/fonts/Inter-Variable.ttf)
      // não bate com esse padrão, então esse caminho lançaria (e
      // imprimiria) uma exceção pra cada peso, mesmo com o texto acabando
      // renderizado certo via `fontFamilyFallback`. Referenciar a família
      // "Inter" diretamente usa a resolução PADRÃO do Flutter (fontes
      // declaradas no pubspec), que já escolhe o peso mais próximo dentro
      // da fonte variável corretamente — sem nenhuma dependência do
      // carregador dinâmico do google_fonts nem do que ele espera de nome
      // de arquivo.
      textTheme: base.textTheme.apply(
        fontFamily: 'Inter',
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),
      colorScheme: base.colorScheme.copyWith(
        primary: primaryColor,
        surface: surfaceColor,
        error: errorColor,
      ),
      scaffoldBackgroundColor: backgroundColor,
      appBarTheme: const AppBarTheme(
        backgroundColor: backgroundColor,
        elevation: 0,
        centerTitle: true,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryColor, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: errorColor, width: 1.2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle:
              const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// Escala de espaçamento (padding/margin) usada nas 4 telas principais —
/// os valores já eram consistentes entre si antes desta classe existir
/// (múltiplos de 4), só não estavam nomeados; nomear evita que uma tela
/// nova introduza um valor "quase igual" (ex: 14 em vez de 16) sem querer.
class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
}

/// Tamanhos dos cards de conteúdo (Live TV, VOD, Séries, Continuar
/// Assistindo) usados pela HomeScreen — centralizados aqui em vez de
/// valores soltos repetidos em cada grid/lista, pra um ajuste de escala
/// futuro ser uma mudança só, não uma caça em vários arquivos.
///
/// Os tamanhos de card abaixo são ~40% do que eram antes desta classe
/// existir (pôster 160->96, miniatura de canal 40->24), mantendo a MESMA
/// proporção de aspecto de cada tipo — só em escala menor, pra caber mais
/// itens visíveis por tela (relevante especialmente em TV). "Continuar
/// Assistindo" reaproveita o mesmo [posterGridDelegate] do pôster (ver
/// HomeScreen._ContinueWatchingGrid) — não tem constante própria.
class AppCardSizes {
  AppCardSizes._();

  /// Menor tamanho de fonte aceito pra título/legenda de card, mesmo com
  /// os cards reduzidos — abaixo disso, fica ilegível a distância de TV.
  /// Ver [AppTheme.cardTitleStyle], que já respeita este piso.
  static const double minCardFontSize = 12;

  /// Largura máxima de cada célula do grid de pôsteres (VOD, Séries — e,
  /// desde a aba "Continuar Assistindo", também esse conteúdo, ver
  /// HomeScreen) — o número de colunas do GridView se ajusta sozinho a
  /// partir deste valor (SliverGridDelegateWithMaxCrossAxisExtent), sem
  /// precisar calcular/hardcodar uma contagem de colunas à mão.
  static const double posterGridMaxExtent = 96;

  /// Proporção largura/altura de cada célula do grid de pôsteres — a MESMA
  /// de antes desta classe existir, só aplicada à célula menor acima.
  static const double posterGridAspectRatio = 0.6;

  /// Delegate PRONTO e compartilhado entre todos os grids de pôster
  /// (_VodGrid, _SeriesGrid, _PosterGridSkeleton e a aba "Continuar
  /// Assistindo") — instância única reaproveitada em vez de reconstruir a
  /// mesma configuração em cada widget.
  static const SliverGridDelegateWithMaxCrossAxisExtent posterGridDelegate =
      SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: posterGridMaxExtent,
    mainAxisSpacing: AppSpacing.s,
    crossAxisSpacing: AppSpacing.s,
    childAspectRatio: posterGridAspectRatio,
  );

  /// Diâmetro da miniatura circular de cada canal na lista de Live TV.
  static const double liveThumbSize = 24;

  /// Tamanho do ícone de "imagem indisponível" mostrado no lugar do pôster
  /// quando a URL falha ao carregar (ver _PosterImage).
  static const double posterFallbackIconSize = 24;
}
