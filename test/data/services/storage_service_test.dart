import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iptv_app/data/models/saved_profile.dart';
import 'package:iptv_app/data/models/watch_progress.dart';
import 'package:iptv_app/data/services/storage_service.dart';

/// Monta um [StorageService] apoiado num backend em memória (não no
/// Keychain/Keystore/DPAPI real, indisponível em `flutter_test`) — [seed]
/// permite simular chaves já existentes (ex: a credencial legada) antes do
/// primeiro acesso.
///
/// Também zera o backend em memória do `shared_preferences` (usado pelo
/// progresso de reprodução, ver grupo "Progresso de reprodução" abaixo) —
/// sem isso, o estado de um teste vazaria pro próximo (o mock é global,
/// por processo).
StorageService _buildService({Map<String, String>? seed, Map<String, Object>? progressSeed}) {
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(seed ?? {});
  SharedPreferences.setMockInitialValues(progressSeed ?? {});
  return StorageService(storage: const FlutterSecureStorage());
}

WatchProgress _progress({
  String contentId = '1',
  String title = 'Filme Teste',
  int positionSeconds = 120,
  int durationSeconds = 3600,
  WatchProgressType type = WatchProgressType.vod,
  DateTime? lastWatchedAt,
}) {
  return WatchProgress(
    contentId: contentId,
    title: title,
    imageUrl: 'http://x.com/poster.jpg',
    positionSeconds: positionSeconds,
    durationSeconds: durationSeconds,
    type: type,
    playbackUrl: 'http://servidor-teste.com:8080/movie/u/p/$contentId.mp4',
    lastWatchedAt: lastWatchedAt ?? DateTime(2025, 1, 1),
  );
}

void main() {
  group('Perfis: CRUD básico', () {
    test('getSavedProfiles() retorna lista vazia quando nada foi salvo', () async {
      final service = _buildService();
      expect(await service.getSavedProfiles(), isEmpty);
    });

    test('addProfile() salva e getSavedProfiles() retorna o perfil salvo', () async {
      final service = _buildService();
      const profile = SavedProfile(
        id: '1',
        nomeExibicao: 'Servidor A',
        xtreamUsername: 'user_a',
        xtreamPassword: 'pass_a',
        dns: 'http://a.com:8080',
      );

      await service.addProfile(profile);
      final profiles = await service.getSavedProfiles();

      expect(profiles, hasLength(1));
      expect(profiles.single.id, '1');
      expect(profiles.single.nomeExibicao, 'Servidor A');
      expect(profiles.single.xtreamUsername, 'user_a');
      expect(profiles.single.xtreamPassword, 'pass_a');
      expect(profiles.single.dns, 'http://a.com:8080');
    });

    test('addProfile() com o mesmo id substitui o perfil existente (não duplica)', () async {
      final service = _buildService();
      await service.addProfile(const SavedProfile(
        id: '1',
        nomeExibicao: 'Nome Antigo',
        xtreamUsername: 'u',
        xtreamPassword: 'p',
        dns: 'http://x.com',
      ));
      await service.addProfile(const SavedProfile(
        id: '1',
        nomeExibicao: 'Nome Novo',
        xtreamUsername: 'u',
        xtreamPassword: 'p',
        dns: 'http://x.com',
      ));

      final profiles = await service.getSavedProfiles();
      expect(profiles, hasLength(1));
      expect(profiles.single.nomeExibicao, 'Nome Novo');
    });

    test('removeProfile() remove só o perfil pedido', () async {
      final service = _buildService();
      await service.addProfile(const SavedProfile(
        id: '1',
        nomeExibicao: 'A',
        xtreamUsername: 'a',
        xtreamPassword: 'p',
        dns: 'd',
      ));
      await service.addProfile(const SavedProfile(
        id: '2',
        nomeExibicao: 'B',
        xtreamUsername: 'b',
        xtreamPassword: 'p',
        dns: 'd',
      ));

      await service.removeProfile('1');

      final profiles = await service.getSavedProfiles();
      expect(profiles, hasLength(1));
      expect(profiles.single.id, '2');
    });

    test('updateProfileNickname() renomeia sem alterar os outros campos', () async {
      final service = _buildService();
      await service.addProfile(const SavedProfile(
        id: '1',
        nomeExibicao: 'Nome Original',
        xtreamUsername: 'user',
        xtreamPassword: 'senha',
        dns: 'http://x.com',
      ));

      await service.updateProfileNickname('1', 'Apelido Novo');

      final profile = (await service.getSavedProfiles()).single;
      expect(profile.nomeExibicao, 'Apelido Novo');
      expect(profile.xtreamUsername, 'user');
      expect(profile.xtreamPassword, 'senha');
      expect(profile.dns, 'http://x.com');
    });

    test('touchProfileLastAccess() ordena a lista pelo mais recente primeiro', () async {
      final service = _buildService();
      await service.addProfile(const SavedProfile(
        id: '1',
        nomeExibicao: 'Antigo',
        xtreamUsername: 'a',
        xtreamPassword: 'p',
        dns: 'd',
      ));
      await service.addProfile(const SavedProfile(
        id: '2',
        nomeExibicao: 'Recente',
        xtreamUsername: 'b',
        xtreamPassword: 'p',
        dns: 'd',
      ));

      await service.touchProfileLastAccess('1', DateTime(2020, 1, 1));
      await service.touchProfileLastAccess('2', DateTime(2025, 1, 1));

      final profiles = await service.getSavedProfiles();
      expect(profiles.map((p) => p.id), ['2', '1']);
    });
  });

  group('Migração da credencial única legada', () {
    test('credencial legada existente vira um SavedProfile automaticamente', () async {
      final service = _buildService(seed: {
        'master_user': 'usuario_legado',
        'master_pass': 'senha_legada',
        'server_dns': 'http://servidor-legado.com:8080',
      });

      final profiles = await service.getSavedProfiles();

      expect(profiles, hasLength(1));
      // Credencial legada única: o mesmo usuário/senha usado antes do
      // suporte a credencial por servidor migra pra xtreamUsername/
      // xtreamPassword.
      expect(profiles.single.xtreamUsername, 'usuario_legado');
      expect(profiles.single.xtreamPassword, 'senha_legada');
      expect(profiles.single.dns, 'http://servidor-legado.com:8080');
      // Sem nome de servidor disponível na credencial antiga, cai no dns.
      expect(profiles.single.nomeExibicao, 'http://servidor-legado.com:8080');
    });

    test('sem credencial legada e sem perfis, getSavedProfiles() só retorna vazio (sem erro)', () async {
      final service = _buildService();
      expect(await service.getSavedProfiles(), isEmpty);
    });

    test('migração roda uma única vez (idempotente) e não duplica em chamadas seguintes', () async {
      final service = _buildService(seed: {
        'master_user': 'usuario_legado',
        'master_pass': 'senha_legada',
        'server_dns': 'http://servidor-legado.com:8080',
      });

      final first = await service.getSavedProfiles();
      final second = await service.getSavedProfiles();

      expect(first, hasLength(1));
      expect(second, hasLength(1));
      expect(second.single.id, first.single.id);
    });

    test('perfil migrado pode ser removido/renomeado normalmente, como qualquer outro', () async {
      final service = _buildService(seed: {
        'master_user': 'usuario_legado',
        'master_pass': 'senha_legada',
        'server_dns': 'http://servidor-legado.com:8080',
      });

      final migratedId = (await service.getSavedProfiles()).single.id;
      await service.updateProfileNickname(migratedId, 'Meu servidor de sempre');

      expect((await service.getSavedProfiles()).single.nomeExibicao, 'Meu servidor de sempre');

      await service.removeProfile(migratedId);
      expect(await service.getSavedProfiles(), isEmpty);
    });

    test('credencial legada incompleta (um campo ausente) não é migrada', () async {
      final service = _buildService(seed: {
        'master_user': 'usuario_legado',
        'server_dns': 'http://servidor-legado.com:8080',
        // 'master_pass' ausente de propósito.
      });

      expect(await service.getSavedProfiles(), isEmpty);
    });
  });

  group('Persistência entre "reinícios" (instância nova do StorageService)', () {
    // Diferença proposital destes testes pros demais deste arquivo: NÃO
    // reseta `FlutterSecureStoragePlatform.instance` entre o write e o
    // read -- o ponto é justamente simular dois momentos distintos do app
    // (ex: antes/depois de fechar e reabrir) apontando pro MESMO backend
    // persistido, cada um com sua PRÓPRIA instância de StorageService (sem
        // reaproveitar estado em memória de uma instância pra outra).
    test('perfil salvo por uma instância é lido corretamente por OUTRA instância (sem estado em memória compartilhado)', () async {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});

      final beforeRestart = StorageService(storage: const FlutterSecureStorage());
      await beforeRestart.addProfile(const SavedProfile(
        id: 'profile_1',
        nomeExibicao: 'Meu Servidor',
        xtreamUsername: 'usuario_xtream',
        xtreamPassword: 'senha_xtream',
        dns: 'http://servidor-teste.com:8080',
      ));

      // Instância NOVA -- nenhum campo/estado em memória da anterior é
      // reaproveitado, só o backend persistido (equivalente ao processo
      // ter sido fechado e reaberto).
      final afterRestart = StorageService(storage: const FlutterSecureStorage());
      final profiles = await afterRestart.getSavedProfiles();

      expect(profiles, hasLength(1));
      expect(profiles.single.id, 'profile_1');
      expect(profiles.single.xtreamUsername, 'usuario_xtream');
      expect(profiles.single.xtreamPassword, 'senha_xtream');
      expect(profiles.single.dns, 'http://servidor-teste.com:8080');
    });

    test('perfil sobrevive a múltiplas instâncias novas em sequência (várias "reaberturas")', () async {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});

      await StorageService(storage: const FlutterSecureStorage()).addProfile(const SavedProfile(
        id: 'profile_1',
        nomeExibicao: 'Servidor',
        xtreamUsername: 'u',
        xtreamPassword: 'p',
        dns: 'd',
      ));

      // Três "reaberturas" seguidas -- cada uma com sua própria instância.
      for (var i = 0; i < 3; i++) {
        final profiles = await StorageService(storage: const FlutterSecureStorage()).getSavedProfiles();
        expect(profiles, hasLength(1), reason: 'reabertura #$i deveria encontrar o perfil salvo');
        expect(profiles.single.id, 'profile_1');
      }
    });
  });

  group('Resiliência', () {
    test('JSON corrompido na chave de perfis não lança exceção (volta lista vazia)', () async {
      final service = _buildService(seed: {'saved_profiles': 'não é um json válido'});
      expect(await service.getSavedProfiles(), isEmpty);
    });

    test('JSON corrompido na chave de progresso não lança exceção (volta lista vazia)', () async {
      final service = _buildService(progressSeed: {'watch_progress': 'não é um json válido'});
      expect(await service.getAllProgress(), isEmpty);
    });
  });

  group('Progresso de reprodução', () {
    test('getAllProgress() retorna lista vazia quando nada foi salvo', () async {
      final service = _buildService();
      expect(await service.getAllProgress(), isEmpty);
    });

    test('saveProgress() salva e getAllProgress() retorna o progresso salvo', () async {
      final service = _buildService();
      await service.saveProgress(_progress(contentId: '1', positionSeconds: 300, durationSeconds: 3600));

      final all = await service.getAllProgress();
      expect(all, hasLength(1));
      expect(all.single.contentId, '1');
      expect(all.single.positionSeconds, 300);
      expect(all.single.durationSeconds, 3600);
      expect(all.single.type, WatchProgressType.vod);
    });

    test('saveProgress() com o mesmo contentId substitui a entrada existente (não duplica)', () async {
      final service = _buildService();
      await service.saveProgress(_progress(contentId: '1', positionSeconds: 100));
      await service.saveProgress(_progress(contentId: '1', positionSeconds: 500));

      final all = await service.getAllProgress();
      expect(all, hasLength(1));
      expect(all.single.positionSeconds, 500);
    });

    test('removeProgress() remove só o contentId pedido', () async {
      final service = _buildService();
      await service.saveProgress(_progress(contentId: '1'));
      await service.saveProgress(_progress(contentId: '2'));

      await service.removeProgress('1');

      final all = await service.getAllProgress();
      expect(all, hasLength(1));
      expect(all.single.contentId, '2');
    });

    test('getAllProgress() ordena do mais recente pro mais antigo', () async {
      final service = _buildService();
      await service.saveProgress(_progress(contentId: '1', lastWatchedAt: DateTime(2024, 1, 1)));
      await service.saveProgress(_progress(contentId: '2', lastWatchedAt: DateTime(2025, 6, 1)));

      final all = await service.getAllProgress();
      expect(all.map((p) => p.contentId), ['2', '1']);
    });

    test('round-trip preserva o tipo episode', () async {
      final service = _buildService();
      await service.saveProgress(_progress(contentId: 'ep1', type: WatchProgressType.episode));

      final all = await service.getAllProgress();
      expect(all.single.type, WatchProgressType.episode);
    });
  });
}
