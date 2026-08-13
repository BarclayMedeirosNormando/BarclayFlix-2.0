import 'package:flutter/material.dart';

/// `Image.network` com [fallback] consistente — o MESMO widget mostrado
/// tanto enquanto carrega quanto em caso de erro (sem um spinner separado
/// no meio do caminho) — e fade suave assim que a imagem termina de
/// decodificar.
///
/// Puro Flutter, sem pacote de cache de imagem: o `Image.network` já
/// cacheia em memória durante a sessão via `ImageCache`; a única coisa que
/// faltaria (cache em DISCO entre reaberturas do app) exigiria algo como
/// `cached_network_image`, cuja dependência transitiva
/// `flutter_cache_manager` usa `sqflite` sem implementação nativa para
/// Windows — risco real de quebrar o build desktop deste app (confirmado
/// checando o pacote), então optamos por não adicionar.
class NetworkImageWithFallback extends StatelessWidget {
  final String url;
  final Widget fallback;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// Redimensiona a decodificação para perto do tamanho de exibição (em
  /// pixels físicos) em vez da resolução original da imagem — evita o jank
  /// comum de grids com muitas capas de alta resolução, e reduz a pressão
  /// de memória do `ImageCache` (relevante sobretudo em Android TV, com RAM
  /// mais limitada que celular/desktop).
  final int? cacheWidth;

  /// Contraparte de [cacheWidth] para o eixo vertical — útil sobretudo em
  /// caixas de tamanho fixo (ex: logo de canal em círculo/quadrado, ver
  /// `_StreamThumb`), onde a imagem de origem pode não ter a mesma
  /// proporção da caixa exibida: sem isto, o decoder infere a altura pela
  /// proporção ORIGINAL da imagem (só a partir de [cacheWidth]), o que pode
  /// decodificar mais pixels do que a caixa (com `BoxFit.cover`) realmente
  /// aproveita.
  final int? cacheHeight;

  const NetworkImageWithFallback({
    super.key,
    required this.url,
    required this.fallback,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.cacheWidth,
    this.cacheHeight,
  });

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return fallback;

    return Image.network(
      url,
      width: width,
      height: height,
      fit: fit,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      errorBuilder: (context, error, stackTrace) => fallback,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: frame == null
              ? KeyedSubtree(key: const ValueKey('loading'), child: fallback)
              : KeyedSubtree(key: const ValueKey('loaded'), child: child),
        );
      },
    );
  }
}
