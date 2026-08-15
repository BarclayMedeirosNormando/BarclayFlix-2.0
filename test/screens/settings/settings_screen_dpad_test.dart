import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iptv_app/data/services/storage_service.dart';
import 'package:iptv_app/providers/settings_provider.dart';
import 'package:iptv_app/screens/settings/settings_screen.dart';

/// Mesmo padrão de player_screen_dpad_test.dart: [Focus.of] busca o
/// FocusNode do ANCESTRAL mais próximo a partir do contexto informado.
bool isFocused(WidgetTester tester, Finder finder) {
  return Focus.of(tester.element(finder)).hasFocus;
}

Future<void> pumpSettingsScreen(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
  final provider = SettingsProvider(storageService: StorageService(storage: const FlutterSecureStorage()));
  await provider.load();

  await tester.pumpWidget(
    ChangeNotifierProvider<SettingsProvider>.value(
      value: provider,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tela já abre com "Definir PIN" focado, e a seta pra baixo alcança o switch de compatibilidade',
      (tester) async {
    await pumpSettingsScreen(tester);

    // find.text (não find.widgetWithText(ElevatedButton, ...)) de propósito
    // -- mesmo cuidado documentado em player_screen_dpad_test.dart: o Text
    // interno é um DESCENDENTE do Focus que o próprio ElevatedButton cria
    // ao se construir, então Focus.of a partir dele resolve pro FocusNode
    // real do botão. Testar o ElevatedButton por fora resolveria pro
    // ANCESTRAL (o antigo wrapper vazio, sempre "focado" independente de
    // qualquer seta) e mascararia o bug.
    expect(
      isFocused(tester, find.text('Definir PIN')),
      isTrue,
      reason: 'botão "Definir PIN" deveria ter autofoco assim que a tela abre',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    // find.text (não find.byType(Switch)) pelo mesmo motivo do comentário
    // acima: o próprio `Switch` cria um FocusNode interno SEU, mais fundo
    // que o do `SwitchListTile` (onde o FocusNode real desta tela foi
    // plugado) -- testar o Switch diretamente resolveria pra esse nó
    // interno, nunca focado (achado empírico: `FocusManager.instance.
    // primaryFocus` batia com o FocusNode correto mesmo com esta asserção
    // falhando, testado plugando um listener temporário).
    expect(
      isFocused(tester, find.text('Modo compatibilidade de vídeo')),
      isTrue,
      reason: 'seta pra baixo a partir de "Definir PIN" deveria focar o switch "Modo compatibilidade de vídeo"',
    );
  });
}
