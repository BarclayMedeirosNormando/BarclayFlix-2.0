import 'package:flutter/foundation.dart';

import '../data/services/storage_service.dart';
import 'content_provider.dart' show ContentType;

/// Favoritos (canal/filme/série) persistidos localmente — sem chamada de
/// rede nenhuma, só leitura/escrita via [StorageService] (mesmo padrão do
/// [ContinueWatchingProvider]). Chaveado por [ContentType] em memória, mas
/// gravado com `type.name` (string) — o [StorageService] não conhece esse
/// enum de propósito, ver comentário em `StorageService.getFavoriteIds`.
class FavoritesProvider extends ChangeNotifier {
  final StorageService _storageService;

  FavoritesProvider({StorageService? storageService})
      : _storageService = storageService ?? StorageService();

  Map<ContentType, Set<String>> _favorites = {
    for (final type in ContentType.values) type: <String>{},
  };

  Future<void> load() async {
    final loaded = <ContentType, Set<String>>{};
    for (final type in ContentType.values) {
      loaded[type] = await _storageService.getFavoriteIds(type.name);
    }
    _favorites = loaded;
    notifyListeners();
  }

  bool isFavorite(ContentType type, String id) => _favorites[type]?.contains(id) ?? false;

  /// true se [type] tiver pelo menos um favorito -- usado pra saber se vale
  /// a pena mostrar o toggle "só favoritos" da aba (ver HomeScreen).
  bool hasAny(ContentType type) => _favorites[type]?.isNotEmpty ?? false;

  Future<void> toggleFavorite(ContentType type, String id) async {
    final nowFavorited = await _storageService.toggleFavorite(type.name, id);

    final updated = Set<String>.from(_favorites[type] ?? const {});
    if (nowFavorited) {
      updated.add(id);
    } else {
      updated.remove(id);
    }
    _favorites = {..._favorites, type: updated};
    notifyListeners();
  }
}
