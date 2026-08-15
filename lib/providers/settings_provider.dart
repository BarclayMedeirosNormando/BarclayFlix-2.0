import 'package:flutter/foundation.dart';

import '../data/services/storage_service.dart';
import 'content_provider.dart' show ContentType;

/// Bloqueio por PIN de categorias (Live TV/VOD/Séries) -- mesmo padrão de
/// persistência do [FavoritesProvider] (cache em memória + StorageService),
/// mas com uma camada extra: [_unlockedThisSession] é um desbloqueio
/// TEMPORÁRIO (nunca persistido, esquecido ao fechar o app) -- digitar o PIN
/// certo uma vez pra uma categoria a libera pelo resto da sessão, pra não
/// pedir de novo a cada troca de aba/categoria.
class SettingsProvider extends ChangeNotifier {
  final StorageService _storageService;

  SettingsProvider({StorageService? storageService}) : _storageService = storageService ?? StorageService();

  bool _hasPin = false;
  bool get hasPin => _hasPin;

  bool _videoCompatibilityMode = false;

  /// Força decodificação de vídeo por software (desliga hwdec) -- toggle
  /// manual pra quem tem um aparelho (TV/celular) com decodificador de
  /// hardware instável em certos streams. Ver PlayerProvider/PlayerScreen.
  bool get videoCompatibilityMode => _videoCompatibilityMode;

  Map<ContentType, Set<String>> _protectedCategoryIds = {
    for (final type in ContentType.values) type: <String>{},
  };

  final Map<ContentType, Set<String>> _unlockedThisSession = {
    for (final type in ContentType.values) type: <String>{},
  };

  Future<void> load() async {
    final pin = await _storageService.getPin();
    final loaded = <ContentType, Set<String>>{};
    for (final type in ContentType.values) {
      loaded[type] = await _storageService.getProtectedCategoryIds(type.name);
    }
    _hasPin = pin != null && pin.isNotEmpty;
    _protectedCategoryIds = loaded;
    _videoCompatibilityMode = await _storageService.getVideoCompatibilityMode();
    notifyListeners();
  }

  Future<void> setVideoCompatibilityMode(bool enabled) async {
    await _storageService.setVideoCompatibilityMode(enabled);
    _videoCompatibilityMode = enabled;
    notifyListeners();
  }

  bool isProtectedCategory(ContentType type, String categoryId) =>
      _protectedCategoryIds[type]?.contains(categoryId) ?? false;

  /// Categoria protegida E ainda não desbloqueada nesta sessão -- é isto (e
  /// não só [isProtectedCategory]) que decide se um PIN precisa ser pedido
  /// agora (ver `_promptPinIfNeeded` em home_screen.dart) e se os itens dela
  /// somem da visão "Todos" (ver `_LiveStreamsPanel`/`_VodGrid`/
  /// `_SeriesGrid`).
  bool isLocked(ContentType type, String categoryId) {
    if (!_hasPin) return false;
    if (!isProtectedCategory(type, categoryId)) return false;
    return !(_unlockedThisSession[type]?.contains(categoryId) ?? false);
  }

  void unlockForSession(ContentType type, String categoryId) {
    _unlockedThisSession[type] = {...?_unlockedThisSession[type], categoryId};
    notifyListeners();
  }

  Future<void> toggleProtectedCategory(ContentType type, String categoryId) async {
    final nowProtected = await _storageService.toggleProtectedCategory(type.name, categoryId);

    final updated = Set<String>.from(_protectedCategoryIds[type] ?? const {});
    if (nowProtected) {
      updated.add(categoryId);
    } else {
      updated.remove(categoryId);
      // Desproteger já libera pra sessão atual também -- sem isso, a
      // categoria continuaria pedindo PIN até a próxima vez que
      // `isLocked` fosse reavaliado com `isProtectedCategory` false (na
      // prática funcionaria, mas via `_unlockedThisSession` guardando um id
      // que não protege mais nada -- limpa por clareza).
      _unlockedThisSession[type]?.remove(categoryId);
    }
    _protectedCategoryIds = {..._protectedCategoryIds, type: updated};
    notifyListeners();
  }

  Future<bool> verifyPin(String candidate) async {
    final saved = await _storageService.getPin();
    return saved != null && saved == candidate;
  }

  Future<void> setPin(String pin) async {
    await _storageService.setPin(pin);
    _hasPin = true;
    notifyListeners();
  }

  /// Remove o PIN e TODAS as categorias protegidas (ver
  /// `StorageService.clearPin` -- sem isso, categorias ficariam travadas
  /// pra sempre, sem PIN nenhum capaz de abri-las).
  Future<void> removePin() async {
    await _storageService.clearPin();
    _hasPin = false;
    _protectedCategoryIds = {for (final type in ContentType.values) type: <String>{}};
    _unlockedThisSession.updateAll((key, value) => <String>{});
    notifyListeners();
  }
}
