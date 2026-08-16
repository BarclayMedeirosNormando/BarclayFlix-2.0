import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import 'dpad_focus_highlight.dart';
import 'network_image_with_fallback.dart';
import 'skeleton_loader.dart';

/// [TESTE] Card de pôster genérico (VOD/Séries/Continuar Assistindo/Live TV
/// com selo de qualidade) — extraído de home_screen.dart (era `_PosterCard`,
/// privado ali) pra ser reaproveitado pelas novas telas do redesenho
/// (ContentGridScreen/ContinueWatchingScreen), que agora vivem em arquivos
/// separados.
class PosterCard extends StatelessWidget {
  final String title;
  final String imageUrl;
  final IconData fallbackIcon;
  final double rating;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  /// 0.0-1.0 — quando não nulo, sobrepõe uma barra fina de progresso na
  /// base do pôster (usado só pela seção "Continuar Assistindo"; `null` em
  /// todo o resto do app, onde o card não representa progresso nenhum).
  final double? progressFraction;

  /// Selo extra no canto SUPERIOR ESQUERDO do pôster (ex: [QualityBadge]
  /// dos canais de Live TV). `null` em VOD/Séries/Continuar Assistindo, que
  /// só usam o selo de nota (canto superior direito, ver [rating]).
  final Widget? topLeftBadge;

  /// Estilo do título abaixo do pôster — default [AppTheme.cardTitleStyle].
  final TextStyle? titleStyle;

  /// `null` (nos dois) = sem coração nenhum -- usado pela aba "Continuar
  /// Assistindo", que reaproveita este mesmo card mas não tem noção de
  /// favorito.
  final bool? isFavorite;
  final VoidCallback? onToggleFavorite;

  /// Linha secundária abaixo do título -- ex: EPG de Live TV. `null` em
  /// VOD/Séries/Continuar Assistindo.
  final Widget? subtitle;

  /// [TESTE] `null` = sem botão de remover nenhum -- usado só por
  /// ContinueWatchingScreen (canto superior direito, mesmo canto do selo de
  /// nota, mas os dois nunca coexistem: "Continuar Assistindo" sempre passa
  /// `rating: 0`).
  final VoidCallback? onRemove;

  /// [TESTE] `true` só no primeiro card de cada grid (`index == 0`, ver
  /// ContentGridScreen/ContinueWatchingScreen) -- sem isso NENHUM grid de
  /// pôster tem autofoco nenhum ao abrir: Escape/D-Pad não alcançam nada
  /// até o usuário tocar em algo primeiro (mesma classe de bug já corrigida
  /// em settings_screen.dart/category_list_screen.dart, encontrada aqui
  /// tarde porque não existia teste de D-Pad cobrindo o grid de VOD/Séries
  /// no redesenho).
  final bool autofocus;

  const PosterCard({
    super.key,
    required this.title,
    required this.imageUrl,
    required this.fallbackIcon,
    required this.rating,
    required this.onTap,
    this.focusNode,
    this.progressFraction,
    this.topLeftBadge,
    this.titleStyle,
    this.isFavorite,
    this.onToggleFavorite,
    this.subtitle,
    this.onRemove,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      focusNode: focusNode,
      autofocus: autofocus,
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: PosterImage(
                    url: imageUrl,
                    fallbackIcon: fallbackIcon,
                  ),
                ),
                if (rating > 0)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: RatingBadge(rating: rating),
                  ),
                if (onRemove != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: PosterRemoveButton(onPressed: onRemove!),
                  ),
                if (topLeftBadge != null)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: topLeftBadge!,
                  ),
                if (progressFraction != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: PosterProgressBar(fraction: progressFraction!),
                  ),
                if (isFavorite != null && onToggleFavorite != null)
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: PosterFavoriteToggle(
                      isFavorite: isFavorite!,
                      onPressed: onToggleFavorite!,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: titleStyle ?? AppTheme.cardTitleStyle,
          ),
          ?subtitle,
        ],
      ),
    );
  }
}

class PosterImage extends StatelessWidget {
  final String url;
  final IconData fallbackIcon;

  const PosterImage({super.key, required this.url, required this.fallbackIcon});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: AppTheme.surfaceColor,
      alignment: Alignment.center,
      child: Icon(fallbackIcon, size: AppCardSizes.posterFallbackIconSize, color: Colors.grey.shade500),
    );

    return NetworkImageWithFallback(
      url: url,
      fallback: fallback,
      // 3x a largura lógica do pôster (AppCardSizes.posterGridMaxExtent) —
      // mesma proporção de antes desta constante existir, cobrindo telas de
      // até devicePixelRatio 3 sem decodificar mais pixels do que o card
      // consegue exibir.
      cacheWidth: (AppCardSizes.posterGridMaxExtent * 3).round(),
    );
  }
}

class PosterGridSkeleton extends StatelessWidget {
  const PosterGridSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(AppSpacing.m),
      gridDelegate: AppCardSizes.posterGridDelegate,
      itemCount: 12,
      itemBuilder: (context, index) => const SkeletonPosterCard(),
    );
  }
}

/// Card grande de destaque no topo de um grid de pôsteres (VOD/Séries) --
/// reaproveita SEMPRE dados já carregados (o item com maior nota da
/// categoria/busca atual), nenhuma chamada de rede extra. Some sozinho
/// durante busca/"só favoritos" (ver os call sites): faria pouco sentido
/// "destacar" algo enquanto o usuário já está filtrando por outra coisa.
class FeaturedBanner extends StatelessWidget {
  final String title;
  final String imageUrl;
  final double rating;
  final IconData fallbackIcon;
  final VoidCallback onTap;

  const FeaturedBanner({
    super.key,
    required this.title,
    required this.imageUrl,
    required this.rating,
    required this.fallbackIcon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.m, AppSpacing.m, AppSpacing.m, 0),
      child: DpadFocusHighlight(
        borderRadius: BorderRadius.circular(12),
        builder: (context, focusNode, hasFocus) => InkWell(
          focusNode: focusNode,
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 180,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NetworkImageWithFallback(
                    url: imageUrl,
                    fallback: Container(
                      color: AppTheme.surfaceColor,
                      alignment: Alignment.center,
                      child: Icon(fallbackIcon, size: 48, color: Colors.grey.shade600),
                    ),
                  ),
                  // Só um scrim escurecendo a BASE (onde fica o texto) --
                  // nunca a imagem inteira, pra continuar reconhecível.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [0.4, 1.0],
                        colors: [Colors.transparent, Colors.black87],
                      ),
                    ),
                  ),
                  Positioned(
                    top: 12,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'DESTAQUE',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        if (rating > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.star, size: 14, color: Colors.amber),
                                const SizedBox(width: 4),
                                Text(rating.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontSize: 13)),
                              ],
                            ),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.play_circle_fill, size: 20, color: AppTheme.primaryColor),
                            const SizedBox(width: 6),
                            const Text(
                              'Assistir',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RatingBadge extends StatelessWidget {
  final double rating;

  const RatingBadge({super.key, required this.rating});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(180),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, size: 12, color: Colors.amber),
          const SizedBox(width: 2),
          Text(
            rating.toStringAsFixed(1),
            style: const TextStyle(fontSize: 11, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// Coração de favoritar sobreposto no canto inferior direito de um pôster
/// (ver [PosterCard.isFavorite]/[PosterCard.onToggleFavorite]) —
/// `GestureDetector` PRÓPRIO (não outro `InkWell`) de propósito: fica
/// dentro do `InkWell` maior do card inteiro (que toca/reproduz), e o
/// Flutter resolve o toque pro gesture recognizer mais interno
/// automaticamente, sem precisar de `HitTestBehavior` nem `Listener`
/// explícitos.
class PosterFavoriteToggle extends StatelessWidget {
  final bool isFavorite;
  final VoidCallback onPressed;

  const PosterFavoriteToggle({super.key, required this.isFavorite, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(180),
          shape: BoxShape.circle,
        ),
        child: Icon(
          isFavorite ? Icons.favorite : Icons.favorite_border,
          size: 14,
          color: isFavorite ? AppTheme.primaryColor : Colors.white,
        ),
      ),
    );
  }
}

/// [TESTE] "X" de remover sobreposto no canto superior direito de um
/// pôster (ver [PosterCard.onRemove]) -- usado só por
/// ContinueWatchingScreen, pra tirar um item específico de "Continuar
/// Assistindo" sem precisar de uma tela/modo de seleção à parte. Mesmo
/// padrão de `GestureDetector` PRÓPRIO de [PosterFavoriteToggle] (ver doc
/// lá do porquê).
class PosterRemoveButton extends StatelessWidget {
  final VoidCallback onPressed;

  const PosterRemoveButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(180),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.close, size: 14, color: Colors.white),
      ),
    );
  }
}

/// Barra fina de progresso sobreposta na base de um pôster — usada só pela
/// seção "Continuar Assistindo" (ver [PosterCard.progressFraction]). Um
/// fundo semitransparente sob a barra em si garante contraste mesmo sobre
/// capas muito claras.
class PosterProgressBar extends StatelessWidget {
  final double fraction;

  const PosterProgressBar({super.key, required this.fraction});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 4,
      color: Colors.black.withAlpha(120),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: fraction.clamp(0, 1),
        child: Container(color: AppTheme.primaryColor),
      ),
    );
  }
}
