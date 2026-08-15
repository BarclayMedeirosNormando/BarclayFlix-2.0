import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_profile.dart';
import '../models/watch_progress.dart';

/// Guarda localmente, de forma segura, a lista de servidores IPTV já
/// configurados (estilo IBO Player/XCIPTV: um [SavedProfile] por card na
/// tela inicial) — permite revalidar/entrar em qualquer um deles sem digitar
/// usuário/senha de novo.
///
/// Estratégia de armazenamento: uma ÚNICA chave (`saved_profiles`) contendo
/// a lista inteira serializada em JSON, em vez de chaves indexadas
/// (`profile_0_user`, `profile_1_user`...). Justificativa: adicionar/remover
/// um perfil vira "ler a lista inteira, alterar em memória, escrever de
/// volta" — uma escrita atômica só, sem precisar deslocar índices dos
/// perfis seguintes ao remover um do meio, nem controlar um contador
/// separado de "quantos perfis existem". O volume de dados (algumas dezenas
/// de perfis, cada um só com strings curtas) é trivial pro
/// flutter_secure_storage.
class StorageService {
  static const _keyLegacyUser = 'master_user';
  static const _keyLegacyPass = 'master_pass';
  static const _keyLegacyDns = 'server_dns';
  static const _keySavedProfiles = 'saved_profiles';
  static const _keyWatchProgress = 'watch_progress';
  static const _keyFavorites = 'favorites';
  static const _keyPin = 'lock_pin';
  static const _keyProtectedCategories = 'protected_categories';
  static const _keyVideoCompatibilityMode = 'video_compatibility_mode';

  final FlutterSecureStorage _storage;

  StorageService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Retorna a única credencial ativa salva localmente, ou `null` se ainda
  /// não houver nenhuma. Lê a migração legada antes de retornar o valor.
  Future<SavedProfile?> getSavedProfile() async {
    final profiles = await getSavedProfiles();
    return profiles.isEmpty ? null : profiles.first;
  }

  Future<List<SavedProfile>> getSavedProfiles() async {
    await _migrateLegacyCredentialIfNeeded();
    return _readProfiles();
  }

  Future<void> saveProfile(SavedProfile profile) async {
    final all = await getSavedProfiles();
    final updated = [
      ...all.where((existing) => existing.id != profile.id),
      profile,
    ];
    await _writeProfiles(updated);
  }

  Future<void> clearSavedProfile() async {
    await _storage.delete(key: _keySavedProfiles);
  }

  Future<void> addProfile(SavedProfile profile) async {
    final all = await getSavedProfiles();
    final updated = [
      ...all.where((existing) => existing.id != profile.id),
      profile,
    ];
    await _writeProfiles(updated);
  }

  Future<void> removeProfile(String id) async {
    final all = await getSavedProfiles();
    final updated = all.where((profile) => profile.id != id).toList();
    await _writeProfiles(updated);
  }

  Future<void> updateProfileNickname(String id, String novoNome) async {
    final all = await getSavedProfiles();
    final updated = all.map((profile) {
      if (profile.id != id) return profile;
      return profile.copyWith(nomeExibicao: novoNome);
    }).toList();
    await _writeProfiles(updated);
  }

  /// Atualiza [SavedProfile.dataUltimoAcesso] para [when] — chamado após uma
  /// revalidação bem-sucedida, para manter o estado de uso mais recente.
  Future<void> touchProfileLastAccess(String id, DateTime when) async {
    final all = await getSavedProfiles();
    final updated = all.map((profile) {
      if (profile.id != id) return profile;
      return profile.copyWith(dataUltimoAcesso: when);
    }).toList();
    await _writeProfiles(updated);
  }

  /// Progresso de reprodução salvo, mais recente primeiro — alimenta a
  /// seção "Continuar Assistindo" da HomeScreen. Mesmo padrão de
  /// armazenamento dos perfis (uma chave só com a lista inteira em JSON),
  /// mas via `shared_preferences`: dado não sensível, escrito com muito
  /// mais frequência (a cada ~10s de reprodução) — não faz sentido pagar o
  /// custo de criptografia do `flutter_secure_storage` pra isso (ver
  /// comentário de justificativa no pubspec.yaml).
  Future<List<WatchProgress>> getAllProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyWatchProgress);
    if (raw == null || raw.isEmpty) return const [];

    try {
      final decoded = json.decode(raw);
      if (decoded is! List) return const [];

      final items = decoded
          .whereType<Map>()
          .map((e) => WatchProgress.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
          .toList();

      items.sort((a, b) => b.lastWatchedAt.compareTo(a.lastWatchedAt));
      return items;
    } catch (_) {
      // Mesmo raciocínio de _readProfiles: JSON corrompido não pode travar
      // a HomeScreen, só volta pra "nada assistido ainda".
      return const [];
    }
  }

  /// Salva/atualiza o progresso de [progress.contentId] (substitui, não
  /// duplica, se já existir uma entrada pro mesmo conteúdo).
  Future<void> saveProgress(WatchProgress progress) async {
    final all = await getAllProgress();
    final updated = [
      ...all.where((p) => p.contentId != progress.contentId),
      progress,
    ];
    await _writeProgress(updated);
  }

  Future<void> removeProgress(String contentId) async {
    final all = await getAllProgress();
    final updated = all.where((p) => p.contentId != contentId).toList();
    await _writeProgress(updated);
  }

  Future<void> _writeProgress(List<WatchProgress> items) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = json.encode(items.map((p) => p.toJson()).toList());
    await prefs.setString(_keyWatchProgress, encoded);
  }

  /// IDs favoritados de [contentType] ('live'/'vod'/'series' -- string livre
  /// de propósito, não o enum `ContentType`: este service não deve depender
  /// da camada de providers, ver FavoritesProvider). Mesmo raciocínio de
  /// armazenamento do progresso acima (`shared_preferences`, dado não
  /// sensível): uma única chave (`favorites`) com um mapa `{contentType:
  /// [ids...]}` inteiro em JSON.
  Future<Set<String>> getFavoriteIds(String contentType) async {
    final all = await _readFavorites();
    return all[contentType] ?? const {};
  }

  /// Alterna (favorita se não estava, remove se já estava) o id [contentId]
  /// dentro de [contentType]. Devolve o novo estado (`true` = favoritado
  /// agora), pra quem chamou não precisar reler pra saber o resultado.
  Future<bool> toggleFavorite(String contentType, String contentId) async {
    final all = await _readFavorites();
    final current = Set<String>.from(all[contentType] ?? const {});
    final nowFavorited = !current.remove(contentId);
    if (nowFavorited) current.add(contentId);

    all[contentType] = current;
    await _writeFavorites(all);
    return nowFavorited;
  }

  Future<Map<String, Set<String>>> _readFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyFavorites);
    if (raw == null || raw.isEmpty) return {};

    try {
      final decoded = json.decode(raw);
      if (decoded is! Map) return {};

      return decoded.map(
        (key, value) => MapEntry(
          key.toString(),
          value is List ? value.map((e) => e.toString()).toSet() : <String>{},
        ),
      );
    } catch (_) {
      // Mesmo raciocínio de _readProfiles/getAllProgress: JSON corrompido
      // não pode travar a tela, só volta pra "nenhum favorito".
      return {};
    }
  }

  Future<void> _writeFavorites(Map<String, Set<String>> data) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = json.encode(data.map((key, value) => MapEntry(key, value.toList())));
    await prefs.setString(_keyFavorites, encoded);
  }

  /// PIN do bloqueio por categoria (ver SettingsProvider/SettingsScreen) --
  /// via `flutter_secure_storage` (não `shared_preferences`, ao contrário de
  /// favoritos/progresso): é um segredo de verdade, mesmo raciocínio de
  /// [SavedProfile.xtreamPassword] já guardado aqui. `null` = nenhum PIN
  /// definido ainda (bloqueio desligado).
  Future<String?> getPin() => _storage.read(key: _keyPin);

  Future<void> setPin(String pin) => _storage.write(key: _keyPin, value: pin);

  /// Remove o PIN E todas as categorias protegidas -- sem isso, categorias
  /// ficariam marcadas como protegidas sem NENHUM PIN pra desbloqueá-las de
  /// novo (trava permanente, sem saída).
  Future<void> clearPin() async {
    await _storage.delete(key: _keyPin);
    await _storage.delete(key: _keyProtectedCategories);
  }

  /// Preferência (não segredo, por isso `shared_preferences` e não
  /// `flutter_secure_storage`) que força o player a decodificar vídeo por
  /// software em vez de hardware -- ver PlayerProvider._videoControllerConfiguration.
  /// `false` por padrão (usa hardware, mais eficiente na maioria dos
  /// aparelhos); alguns TVs/celulares têm decodificadores de hardware
  /// instáveis com certos streams, daí o usuário poder desligar manualmente
  /// pelo próprio aparelho afetado em vez do app tentar adivinhar.
  Future<bool> getVideoCompatibilityMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyVideoCompatibilityMode) ?? false;
  }

  Future<void> setVideoCompatibilityMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyVideoCompatibilityMode, enabled);
  }

  /// IDs de categoria protegidos de [contentType] ('live'/'vod'/'series' --
  /// mesma convenção de string livre dos favoritos, ver
  /// `getFavoriteIds`/FavoritesProvider).
  Future<Set<String>> getProtectedCategoryIds(String contentType) async {
    final all = await _readProtectedCategories();
    return all[contentType] ?? const {};
  }

  /// Alterna (protege se não estava, remove se já estava) [categoryId]
  /// dentro de [contentType]. Devolve o novo estado (`true` = protegida
  /// agora).
  Future<bool> toggleProtectedCategory(String contentType, String categoryId) async {
    final all = await _readProtectedCategories();
    final current = Set<String>.from(all[contentType] ?? const {});
    final nowProtected = !current.remove(categoryId);
    if (nowProtected) current.add(categoryId);

    all[contentType] = current;
    await _writeProtectedCategories(all);
    return nowProtected;
  }

  Future<Map<String, Set<String>>> _readProtectedCategories() async {
    final raw = await _storage.read(key: _keyProtectedCategories);
    if (raw == null || raw.isEmpty) return {};

    try {
      final decoded = json.decode(raw);
      if (decoded is! Map) return {};

      return decoded.map(
        (key, value) => MapEntry(
          key.toString(),
          value is List ? value.map((e) => e.toString()).toSet() : <String>{},
        ),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeProtectedCategories(Map<String, Set<String>> data) async {
    final encoded = json.encode(data.map((key, value) => MapEntry(key, value.toList())));
    await _storage.write(key: _keyProtectedCategories, value: encoded);
  }

  Future<List<SavedProfile>> _readProfiles() async {
    final raw = await _storage.read(key: _keySavedProfiles);
    if (raw == null || raw.isEmpty) return const [];

    try {
      final decoded = json.decode(raw);
      if (decoded is! List) return const [];

      final profiles = decoded
          .whereType<Map>()
          .map((e) => SavedProfile.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
          .toList();

      profiles.sort((a, b) {
        final aTime = a.dataUltimoAcesso;
        final bTime = b.dataUltimoAcesso;
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });

      return profiles;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _writeProfiles(List<SavedProfile> profiles) async {
    final encoded = json.encode(profiles.map((profile) => profile.toJson()).toList());
    await _storage.write(key: _keySavedProfiles, value: encoded);
  }

  Future<List<SavedProfile>> _readProfilesFromLegacyList() async {
    final raw = await _storage.read(key: _keySavedProfiles);
    if (raw == null || raw.isEmpty) return const [];

    try {
      final decoded = json.decode(raw);
      if (decoded is! List) return const [];

      final profiles = decoded
          .whereType<Map>()
          .map((e) => SavedProfile.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
          .toList();

      profiles.sort((a, b) {
        final aTime = a.dataUltimoAcesso;
        final bTime = b.dataUltimoAcesso;
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });

      return profiles;
    } catch (_) {
      return const [];
    }
  }

  /// Migra a credencial única salva pelo app antes do suporte a múltiplos
  /// perfis (chaves `master_user`/`master_pass`/`server_dns`) para o novo
  /// formato de lista, uma única vez.
  ///
  /// OBRIGATÓRIO nunca pular esta etapa: sem ela, quem já usava o app
  /// perderia acesso ao servidor configurado silenciosamente após a
  /// atualização. Idempotente (seguro chamar em toda leitura) — se a chave
  /// `saved_profiles` já existir (mesmo vazia, `[]`), a migração já rodou
  /// antes e não faz nada.
  ///
  /// As chaves antigas nunca são apagadas por aqui — ficam como rede de
  /// segurança caso a migração precise ser investigada depois; nenhum outro
  /// código do app as lê mais uma vez migradas.
  Future<void> _migrateLegacyCredentialIfNeeded() async {
    final existing = await _storage.read(key: _keySavedProfiles);
    if (existing != null) return;

    final oldProfiles = await _readProfilesFromLegacyList();
    if (oldProfiles.isNotEmpty) {
      await _writeProfiles(oldProfiles);
      return;
    }

    final legacy = await _readLegacyCredentials();
    if (legacy == null) return;

    final migratedProfile = SavedProfile(
      id: 'legacy_${DateTime.now().microsecondsSinceEpoch}',
      nomeExibicao: legacy.dns,
      xtreamUsername: legacy.user,
      xtreamPassword: legacy.pass,
      dns: legacy.dns,
    );

    await _writeProfiles([migratedProfile]);
  }

  Future<_LegacyCredentials?> _readLegacyCredentials() async {
    final values = await Future.wait([
      _storage.read(key: _keyLegacyUser),
      _storage.read(key: _keyLegacyPass),
      _storage.read(key: _keyLegacyDns),
    ]);

    final user = values[0];
    final pass = values[1];
    final dns = values[2];

    if (user == null || pass == null || dns == null) return null;
    if (user.isEmpty || pass.isEmpty || dns.isEmpty) return null;

    return _LegacyCredentials(user: user, pass: pass, dns: dns);
  }
}

class _LegacyCredentials {
  final String user;
  final String pass;
  final String dns;

  const _LegacyCredentials({
    required this.user,
    required this.pass,
    required this.dns,
  });
}
