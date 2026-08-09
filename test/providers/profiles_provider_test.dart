import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:iptv_app/core/constants/app_constants.dart';
import 'package:iptv_app/data/models/saved_profile.dart';
import 'package:iptv_app/data/services/device_auth_service.dart';
import 'package:iptv_app/data/services/storage_service.dart';
import 'package:iptv_app/providers/auth_provider.dart';
import 'package:iptv_app/providers/profiles_provider.dart';

const _testDns = 'http://servidor-teste.com:8080';

Future<http.Response> _json(Object body) async => http.Response(jsonEncode(body), 200);

/// Handler HTTP único que serve tanto a ativação de dispositivo (Apps
/// Script) quanto o `player_api.php` da Xtream — o mesmo `http.Client` fake
/// é passado pros dois serviços (ver [_buildAuthProvider]), então a rota é
/// decidida pela URL de cada request, igual um servidor de verdade faria.
///
/// [serversForDevice] simula um dispositivo já ativado com um ou mais
/// servidores vinculados (default: um só). [errorCodeForDevice]/
/// [errorMessageForDevice] simulam a ativação recusando o dispositivo
/// (`nao_registrado`/`inativo`/`expirado`).
Future<http.Response> Function(http.Request) _buildHandler({
  Completer<void>? delayXtreamUntil,
  List<Map<String, String>>? serversForDevice,
  String? errorCodeForDevice,
  String? errorMessageForDevice,
}) {
  return (request) async {
    // Checa a rota Xtream PRIMEIRO, por um sufixo de path especifico
    // (`/player_api.php`) -- nunca por `AppConstants.deviceAuthUrl`, que em
    // `flutter test` (sem `--dart-define=APPS_SCRIPT_URL=...`) resolve pra
    // string vazia, e `startsWith('')` bateria com QUALQUER URL, inclusive
    // a da Xtream, fazendo o login de servidor cair aqui por engano. Em
    // produção isso nunca acontece (a URL do Apps Script é injetada em
    // build time e nunca colide com o `dns` de um servidor Xtream), então é
    // só o fixture de teste que precisa dessa ordem.
    if (request.url.path.endsWith(AppConstants.xtreamPlayerApiPath)) {
      if (delayXtreamUntil != null) await delayXtreamUntil.future;
      return _json({
        'user_info': {'auth': 1, 'status': 'Active'},
        'server_info': {'url': 'servidor-teste.com', 'port': '8080'},
      });
    }

    if (request.url.toString().startsWith(AppConstants.deviceAuthUrl)) {
      if (errorCodeForDevice != null) {
        return _json({
          'status': 'erro',
          'codigo': errorCodeForDevice,
          'mensagem': errorMessageForDevice ?? 'Erro de ativação.',
        });
      }
      return _json({
        'status': 'ok',
        'nomeCliente': 'Cliente Teste',
        'servidores': serversForDevice ??
            const [
              {
                'nome': 'Meu Servidor IPTV',
                'dns': _testDns,
                'username': 'usuario_servidor',
                'password': 'senha_servidor',
              },
            ],
      });
    }

    return http.Response('Not Found', 404);
  };
}

/// Monta um [AuthProvider] real (não um fake) apontando pro handler HTTP
/// falso acima — [ProfilesProvider] delega toda a autenticação pra ele
/// (ver auth_provider.dart), então testá-lo isoladamente com um fake
/// próprio não provaria que a integração real funciona.
AuthProvider _buildAuthProvider({
  Completer<void>? delayXtreamUntil,
  List<Map<String, String>>? serversForDevice,
  String? errorCodeForDevice,
  String? errorMessageForDevice,
}) {
  final client = MockClient(_buildHandler(
    delayXtreamUntil: delayXtreamUntil,
    serversForDevice: serversForDevice,
    errorCodeForDevice: errorCodeForDevice,
    errorMessageForDevice: errorMessageForDevice,
  ));
  return AuthProvider(
    deviceAuthService: DeviceAuthService(client: client),
    xtreamHttpClient: client,
  );
}

StorageService _buildStorageService({Map<String, String>? seed}) {
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(seed ?? {});
  return StorageService(storage: const FlutterSecureStorage());
}

void main() {
  group('checkDeviceActivation + chooseServer', () {
    test('único servidor: devolve 1 e chooseServer salva o perfil, autenticando a sessão ativa', () async {
      final authProvider = _buildAuthProvider();
      final storageService = _buildStorageService();
      final provider = ProfilesProvider(authProvider: authProvider, storageService: storageService);

      final result = await provider.checkDeviceActivation();
      expect(result, isNotNull);
      expect(result!.servidores, hasLength(1));
      expect(result.nomeCliente, 'Cliente Teste');

      final success = await provider.chooseServer(server: result.servidores.single);

      expect(success, isTrue);
      expect(provider.profiles, hasLength(1));
      // A credencial REAL do servidor (vinda do ServerOption) vira
      // xtreamUsername/xtreamPassword.
      expect(provider.profiles.single.xtreamUsername, 'usuario_servidor');
      expect(provider.profiles.single.xtreamPassword, 'senha_servidor');
      expect(provider.profiles.single.dns, _testDns);
      // Nome de exibição vem do `nome` do servidor escolhido.
      expect(provider.profiles.single.nomeExibicao, 'Meu Servidor IPTV');
      expect(provider.profiles.single.nomeServidor, 'Meu Servidor IPTV');
      expect(authProvider.status, AuthStatus.authenticated);
      expect(authProvider.apiService, isNotNull);
    });

    test('múltiplos servidores: devolve todos, chooseServer salva só o escolhido, com a credencial DAQUELE servidor', () async {
      final authProvider = _buildAuthProvider(serversForDevice: const [
        {
          'nome': 'Servidor A',
          'dns': 'http://servidor-a.com:8080',
          'username': 'usuario_servidor_a',
          'password': 'senha_servidor_a',
        },
        {
          'nome': 'Servidor B',
          'dns': 'http://servidor-b.com:8080',
          'username': 'usuario_servidor_b',
          'password': 'senha_servidor_b',
        },
      ]);
      final provider = ProfilesProvider(authProvider: authProvider, storageService: _buildStorageService());

      final result = await provider.checkDeviceActivation();

      expect(result!.servidores, hasLength(2));
      expect(result.servidores.map((s) => s.nome), containsAll(['Servidor A', 'Servidor B']));

      final success = await provider.chooseServer(server: result.servidores[1]);

      expect(success, isTrue);
      expect(provider.profiles, hasLength(1));
      expect(provider.profiles.single.dns, 'http://servidor-b.com:8080');
      expect(provider.profiles.single.nomeExibicao, 'Servidor B');
      expect(provider.profiles.single.xtreamUsername, 'usuario_servidor_b');
      expect(provider.profiles.single.xtreamPassword, 'senha_servidor_b');
    });

    test('dispositivo não registrado: checkDeviceActivation falha com código específico e mensagem do backend', () async {
      final authProvider = _buildAuthProvider(
        errorCodeForDevice: 'nao_registrado',
        errorMessageForDevice: 'Dispositivo ainda não cadastrado. Aguarde.',
      );
      final provider = ProfilesProvider(authProvider: authProvider, storageService: _buildStorageService());

      final result = await provider.checkDeviceActivation();

      expect(result, isNull);
      expect(provider.profiles, isEmpty);
      expect(authProvider.errorCode, 'nao_registrado');
      expect(authProvider.errorMessage, 'Dispositivo ainda não cadastrado. Aguarde.');
    });

    test('dispositivo inativo: checkDeviceActivation falha com código específico e mensagem do backend', () async {
      final authProvider = _buildAuthProvider(
        errorCodeForDevice: 'inativo',
        errorMessageForDevice: 'Sua assinatura está inativa.',
      );
      final provider = ProfilesProvider(authProvider: authProvider, storageService: _buildStorageService());

      final result = await provider.checkDeviceActivation();

      expect(result, isNull);
      expect(provider.profiles, isEmpty);
      expect(authProvider.errorCode, 'inativo');
      expect(authProvider.errorMessage, 'Sua assinatura está inativa.');
    });

    test('dispositivo expirado: checkDeviceActivation falha com código específico e mensagem do backend', () async {
      final authProvider = _buildAuthProvider(
        errorCodeForDevice: 'expirado',
        errorMessageForDevice: 'Sua assinatura expirou.',
      );
      final provider = ProfilesProvider(authProvider: authProvider, storageService: _buildStorageService());

      final result = await provider.checkDeviceActivation();

      expect(result, isNull);
      expect(provider.profiles, isEmpty);
      expect(authProvider.errorCode, 'expirado');
      expect(authProvider.errorMessage, 'Sua assinatura expirou.');
    });
  });

  group('selectProfile', () {
    Future<ProfilesProvider> buildWithSavedProfile({
      required AuthProvider authProvider,
      String dns = _testDns,
    }) async {
      final storageService = _buildStorageService();
      await storageService.addProfile(SavedProfile(
        id: 'profile_1',
        nomeExibicao: 'Servidor Salvo',
        xtreamUsername: 'usuario_qualquer',
        xtreamPassword: 'senha_qualquer',
        dns: dns,
      ));

      final provider = ProfilesProvider(authProvider: authProvider, storageService: storageService);
      await provider.loadProfiles();
      return provider;
    }

    test('dispositivo ainda ativado: revalida sem pedir input e atualiza a sessão ativa', () async {
      final authProvider = _buildAuthProvider();
      final provider = await buildWithSavedProfile(authProvider: authProvider);

      final success = await provider.selectProfile('profile_1');

      expect(success, isTrue);
      expect(provider.isLoading('profile_1'), isFalse);
      expect(provider.errorFor('profile_1'), isNull);
      expect(authProvider.status, AuthStatus.authenticated);
    });

    test('estado de loading fica ligado SÓ durante a revalidação, e só para o card certo', () async {
      final delay = Completer<void>();
      final authProvider = _buildAuthProvider(delayXtreamUntil: delay);
      final provider = await buildWithSavedProfile(authProvider: authProvider);

      final future = provider.selectProfile('profile_1');
      // Ainda não liberou a resposta da Xtream — a revalidação está "em voo".
      await Future<void>.delayed(Duration.zero);
      expect(provider.isLoading('profile_1'), isTrue);
      expect(provider.isLoading('outro_id_qualquer'), isFalse);

      delay.complete();
      final success = await future;

      expect(success, isTrue);
      expect(provider.isLoading('profile_1'), isFalse);
    });

    test('dispositivo inativo: mostra mensagem e código específicos no card, NÃO remove o perfil', () async {
      final authProvider = _buildAuthProvider(
        errorCodeForDevice: 'inativo',
        errorMessageForDevice: 'Sua assinatura está inativa.',
      );
      final provider = await buildWithSavedProfile(authProvider: authProvider);

      final success = await provider.selectProfile('profile_1');

      expect(success, isFalse);
      expect(provider.errorFor('profile_1'), 'Sua assinatura está inativa.');
      expect(provider.errorCodeFor('profile_1'), 'inativo');
      expect(provider.profiles, hasLength(1), reason: 'perfil não deve ser removido automaticamente numa falha');
      expect(provider.profiles.single.id, 'profile_1');
    });

    test('dispositivo expirado: mostra mensagem e código específicos no card', () async {
      final authProvider = _buildAuthProvider(
        errorCodeForDevice: 'expirado',
        errorMessageForDevice: 'Sua assinatura expirou.',
      );
      final provider = await buildWithSavedProfile(authProvider: authProvider);

      final success = await provider.selectProfile('profile_1');

      expect(success, isFalse);
      expect(provider.errorFor('profile_1'), 'Sua assinatura expirou.');
      expect(provider.errorCodeFor('profile_1'), 'expirado');
      expect(provider.profiles, hasLength(1), reason: 'perfil não deve ser removido automaticamente');
    });

    test('id desconhecido: não faz nada e não lança exceção', () async {
      final authProvider = _buildAuthProvider();
      final provider = ProfilesProvider(authProvider: authProvider, storageService: _buildStorageService());
      await provider.loadProfiles();

      final success = await provider.selectProfile('id_que_nao_existe');

      expect(success, isFalse);
    });

    test('acesso ao servidor salvo foi removido pelo admin: mensagem própria, perfil não é apagado', () async {
      final authProvider = _buildAuthProvider(serversForDevice: const [
        {
          'nome': 'Outro Servidor',
          'dns': 'http://outro-servidor.com:8080',
          'username': 'u',
          'password': 'p',
        },
      ]);
      final provider = await buildWithSavedProfile(authProvider: authProvider);

      final success = await provider.selectProfile('profile_1');

      expect(success, isFalse);
      expect(provider.errorFor('profile_1'), 'Acesso a este servidor foi removido.');
      expect(provider.profiles, hasLength(1), reason: 'perfil não deve ser removido automaticamente');
    });
  });

  group('removeProfile / renameProfile', () {
    test('removeProfile remove da lista e persiste', () async {
      final authProvider = _buildAuthProvider();
      final storageService = _buildStorageService();
      await storageService.addProfile(const SavedProfile(
        id: 'p1',
        nomeExibicao: 'Servidor',
        xtreamUsername: 'u',
        xtreamPassword: 'p',
        dns: 'd',
      ));

      final provider = ProfilesProvider(authProvider: authProvider, storageService: storageService);
      await provider.loadProfiles();
      expect(provider.profiles, hasLength(1));

      await provider.removeProfile('p1');

      expect(provider.profiles, isEmpty);
      expect(await storageService.getSavedProfiles(), isEmpty);
    });

    test('renameProfile atualiza o nome de exibição', () async {
      final authProvider = _buildAuthProvider();
      final storageService = _buildStorageService();
      await storageService.addProfile(const SavedProfile(
        id: 'p1',
        nomeExibicao: 'Nome Antigo',
        xtreamUsername: 'u',
        xtreamPassword: 'p',
        dns: 'd',
      ));

      final provider = ProfilesProvider(authProvider: authProvider, storageService: storageService);
      await provider.loadProfiles();

      await provider.renameProfile('p1', 'Nome Novo');

      expect(provider.profiles.single.nomeExibicao, 'Nome Novo');
    });

    test('renameProfile com nome em branco não faz nada', () async {
      final authProvider = _buildAuthProvider();
      final storageService = _buildStorageService();
      await storageService.addProfile(const SavedProfile(
        id: 'p1',
        nomeExibicao: 'Nome Original',
        xtreamUsername: 'u',
        xtreamPassword: 'p',
        dns: 'd',
      ));

      final provider = ProfilesProvider(authProvider: authProvider, storageService: storageService);
      await provider.loadProfiles();

      await provider.renameProfile('p1', '   ');

      expect(provider.profiles.single.nomeExibicao, 'Nome Original');
    });
  });
}
