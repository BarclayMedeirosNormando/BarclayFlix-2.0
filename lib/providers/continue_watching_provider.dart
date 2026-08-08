import 'package:flutter/foundation.dart';

import '../data/models/watch_progress.dart';
import '../data/services/storage_service.dart';

/// Expõe a lista de progresso salvo ("Continuar Assistindo") pra HomeScreen.
///
/// Sem chamada de rede nenhuma aqui — só leitura local via [StorageService].
/// [load] é chamado tanto na primeira montagem da HomeScreen quanto sempre
/// que se volta a ela depois de um push pra Player/SeriesDetails (ver
/// HomeScreen), já que assistir mais conteúdo muda o progresso salvo sem
/// nenhum outro provider ficar sabendo disso sozinho.
class ContinueWatchingProvider extends ChangeNotifier {
  final StorageService _storageService;

  ContinueWatchingProvider({StorageService? storageService})
      : _storageService = storageService ?? StorageService();

  List<WatchProgress> _items = const [];
  List<WatchProgress> get items => _items;

  Future<void> load() async {
    _items = await _storageService.getAllProgress();
    notifyListeners();
  }
}
