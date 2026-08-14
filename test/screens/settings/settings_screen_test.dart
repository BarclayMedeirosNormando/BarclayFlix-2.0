import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';

import 'package:iptv_app/data/services/storage_service.dart';
import 'package:iptv_app/providers/settings_provider.dart';
import 'package:iptv_app/screens/settings/settings_screen.dart';

Future<void> pumpSettingsScreen(WidgetTester tester, {SettingsProvider? settingsProvider}) async {
  SettingsProvider provider;
  if (settingsProvider != null) {
    // Já veio com seu próprio backend/estado prontos (ex: PIN já definido
    // via buildProviderWithPin abaixo) -- resetar o mock aqui apagaria isso.
    provider = settingsProvider;
  } else {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    provider = SettingsProvider(storageService: StorageService(storage: const FlutterSecureStorage()));
    await provider.load();
  }

  await tester.pumpWidget(
    ChangeNotifierProvider<SettingsProvider>.value(
      value: provider,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Sem PIN definido', () {
    testWidgets('mostra só "Definir PIN"', (tester) async {
      await pumpSettingsScreen(tester);

      expect(find.text('Definir PIN'), findsOneWidget);
      expect(find.text('Alterar PIN'), findsNothing);
      expect(find.text('Remover PIN'), findsNothing);
    });

    testWidgets('define um PIN válido: dois campos iguais salva e a tela vira "Alterar/Remover"', (tester) async {
      await pumpSettingsScreen(tester);

      await tester.tap(find.text('Definir PIN'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Novo PIN'), '1234');
      await tester.enterText(find.widgetWithText(TextField, 'Confirme o PIN'), '1234');
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();

      expect(find.text('Definir PIN'), findsNothing);
      expect(find.text('Alterar PIN'), findsOneWidget);
      expect(find.text('Remover PIN'), findsOneWidget);
    });

    testWidgets('PINs diferentes mostram erro e não fecham o diálogo', (tester) async {
      await pumpSettingsScreen(tester);

      await tester.tap(find.text('Definir PIN'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Novo PIN'), '1234');
      await tester.enterText(find.widgetWithText(TextField, 'Confirme o PIN'), '5678');
      await tester.tap(find.text('Salvar'));
      await tester.pump();

      expect(find.text('Os PINs não são iguais.'), findsOneWidget);
      // Diálogo continua aberto -- ainda dá pra achar o campo "Novo PIN".
      expect(find.widgetWithText(TextField, 'Novo PIN'), findsOneWidget);
    });

    testWidgets('PIN com menos de 4 dígitos mostra erro', (tester) async {
      await pumpSettingsScreen(tester);

      await tester.tap(find.text('Definir PIN'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Novo PIN'), '12');
      await tester.enterText(find.widgetWithText(TextField, 'Confirme o PIN'), '12');
      await tester.tap(find.text('Salvar'));
      await tester.pump();

      expect(find.text('O PIN precisa ter pelo menos 4 dígitos.'), findsOneWidget);
    });
  });

  group('Com PIN já definido', () {
    Future<SettingsProvider> buildProviderWithPin() async {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
      final provider = SettingsProvider(storageService: StorageService(storage: const FlutterSecureStorage()));
      await provider.setPin('1234');
      return provider;
    }

    testWidgets('remover com PIN errado mostra snackbar e mantém o PIN', (tester) async {
      final provider = await buildProviderWithPin();
      await pumpSettingsScreen(tester, settingsProvider: provider);

      await tester.tap(find.text('Remover PIN'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'PIN'), '9999');
      await tester.tap(find.text('Confirmar'));
      await tester.pumpAndSettle();

      expect(find.text('PIN incorreto.'), findsOneWidget);
      expect(find.text('Alterar PIN'), findsOneWidget, reason: 'PIN errado não deve remover nada');
    });

    testWidgets('remover com PIN correto volta a tela pra "Definir PIN"', (tester) async {
      final provider = await buildProviderWithPin();
      await pumpSettingsScreen(tester, settingsProvider: provider);

      await tester.tap(find.text('Remover PIN'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'PIN'), '1234');
      await tester.tap(find.text('Confirmar'));
      await tester.pumpAndSettle();

      expect(find.text('Definir PIN'), findsOneWidget);
      expect(find.text('Alterar PIN'), findsNothing);
    });

    testWidgets('alterar PIN sobrescreve o anterior', (tester) async {
      final provider = await buildProviderWithPin();
      await pumpSettingsScreen(tester, settingsProvider: provider);

      await tester.tap(find.text('Alterar PIN'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Novo PIN'), '5678');
      await tester.enterText(find.widgetWithText(TextField, 'Confirme o PIN'), '5678');
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();

      expect(await provider.verifyPin('5678'), isTrue);
      expect(await provider.verifyPin('1234'), isFalse);
    });
  });
}
