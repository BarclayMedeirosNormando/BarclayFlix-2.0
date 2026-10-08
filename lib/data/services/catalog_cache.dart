import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Corpo de resposta guardado em disco + quando foi gravado.
class CachedBody {
  final String body;
  final DateTime savedAt;

  const CachedBody({required this.body, required this.savedAt});

  bool isFresh(Duration ttl, DateTime now) => now.difference(savedAt) < ttl;
}

/// Cache em disco das listas pesadas do catálogo Xtream (categorias e
/// streams de Live/Filmes/Séries): guarda o corpo JSON BRUTO da resposta,
/// um arquivo por chamada, na pasta de cache do app.
///
/// Nunca lança: qualquer falha (plugin indisponível, disco cheio, arquivo
/// corrompido) vira "sem cache" -- o app só volta a depender da rede.
/// A chave (`servidor|usuário|ação|categoria`) vira só um hash no nome do
/// arquivo, então nem a URL nem a credencial aparecem no disco.
class CatalogCache {
  final Future<Directory> Function() _directoryProvider;
  final Duration ttl;
  final DateTime Function() _now;

  Directory? _directory;

  CatalogCache({
    Future<Directory> Function()? directoryProvider,
    this.ttl = const Duration(hours: 6),
    DateTime Function()? now,
  })  : _directoryProvider = directoryProvider ?? _defaultDirectory,
        _now = now ?? DateTime.now;

  DateTime get now => _now();

  static Future<Directory> _defaultDirectory() async {
    final base = await getApplicationCacheDirectory();
    return Directory('${base.path}${Platform.pathSeparator}catalog_cache');
  }

  Future<File> _fileFor(String key) async {
    var dir = _directory;
    if (dir == null) {
      dir = await _directoryProvider();
      await dir.create(recursive: true);
      _directory = dir;
    }
    final name = sha256.convert(utf8.encode(key)).toString();
    return File('${dir.path}${Platform.pathSeparator}$name.json');
  }

  Future<CachedBody?> read(String key) async {
    try {
      final file = await _fileFor(key);
      if (!await file.exists()) return null;
      final savedAt = (await file.stat()).modified;
      final body = await file.readAsString();
      if (body.isEmpty) return null;
      return CachedBody(body: body, savedAt: savedAt);
    } catch (_) {
      return null;
    }
  }

  /// Grava de forma atômica (arquivo temporário + rename): um fechamento do
  /// app no meio da escrita nunca deixa um JSON pela metade como "cache".
  Future<void> write(String key, String body) async {
    try {
      final file = await _fileFor(key);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(body, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Sem cache nesta chamada; nada a fazer.
    }
  }
}
