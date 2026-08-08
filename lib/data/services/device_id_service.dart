import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Gera e persiste o identificador único desta INSTALAÇÃO do app, usado
/// pelo backend (Master Login) para o vínculo de dispositivo (device
/// locking): a mesma conta só pode estar ativa em um [DeviceIdService.
/// getDeviceId] por vez.
///
/// LIMITAÇÃO REAL, documentada de propósito: este ID identifica a
/// INSTALAÇÃO, não o hardware. Reinstalar o app ou limpar os dados do app
/// gera um ID novo — diferente de um identificador físico de verdade (ex:
/// endereço MAC), que não está mais acessível para apps comuns em Android
/// moderno: desde o Android 10, por restrição de privacidade do próprio
/// sistema operacional, apps sem privilégio de sistema recebem um MAC
/// aleatório/ofuscado tanto ao consultar a interface de rede quanto no
/// próprio tráfego Wi-Fi. Não existe hoje, em Android "normal", um jeito
/// de identificar o hardware físico de forma estável sem depender de um ID
/// por instalação como este.
class DeviceIdService {
  static const _keyDeviceId = 'device_id';

  final FlutterSecureStorage _storage;
  final Uuid _uuid;

  DeviceIdService({FlutterSecureStorage? storage, Uuid? uuid})
      : _storage = storage ?? const FlutterSecureStorage(),
        _uuid = uuid ?? const Uuid();

  /// Idempotente: reaproveita o ID já gerado em chamadas anteriores; só
  /// gera (e persiste) um novo na primeiríssima vez.
  Future<String> getDeviceId() async {
    final existing = await _storage.read(key: _keyDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;

    final generated = _uuid.v4();
    await _storage.write(key: _keyDeviceId, value: generated);
    return generated;
  }
}
