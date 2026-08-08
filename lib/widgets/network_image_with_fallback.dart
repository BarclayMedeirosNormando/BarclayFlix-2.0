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
  /// comum de grids com muitas capas de alta resolução.
  final int? cacheWidth;

  const NetworkImageWithFallback({
    super.key,
    required this.url,
    required this.fallback,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.cacheWidth,
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
