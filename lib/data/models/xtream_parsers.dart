/// Helpers de parsing defensivo para respostas da API Xtream Codes.
///
/// Servidores Xtream são notoriamente inconsistentes: um campo numérico pode
/// vir como `int`, `double` ou `String` dependendo do painel/versão, e
/// campos opcionais às vezes vêm como `null`, string vazia, ou até `[]` no
/// lugar de `{}`/`null`. Estas funções nunca lançam exceção — sempre caem
/// para um valor padrão seguro.
library;

import 'dart:convert';

String asString(dynamic value, [String fallback = '']) {
  if (value == null) return fallback;
  final str = value.toString();
  return str == 'null' ? fallback : str;
}

String? asStringOrNull(dynamic value) {
  if (value == null) return null;
  final str = value.toString();
  if (str.isEmpty || str == 'null') return null;
  return str;
}

int asInt(dynamic value, [int fallback = 0]) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is double) return value.toInt();
  return int.tryParse(value.toString()) ?? fallback;
}

int? asIntOrNull(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) return value.toInt();
  return int.tryParse(value.toString());
}

double asDouble(dynamic value, [double fallback = 0.0]) {
  if (value == null) return fallback;
  if (value is double) return value;
  if (value is int) return value.toDouble();
  return double.tryParse(value.toString()) ?? fallback;
}

bool asBool(dynamic value, [bool fallback = false]) {
  if (value == null) return fallback;
  if (value is bool) return value;
  final normalized = value.toString().trim().toLowerCase();
  return normalized == '1' || normalized == 'true';
}

/// Converte um timestamp Unix (em segundos, geralmente vindo como String)
/// para `DateTime`. Retorna `null` para valores ausentes/zerados/inválidos.
DateTime? asUnixDate(dynamic value) {
  final seconds = asIntOrNull(value);
  if (seconds == null || seconds <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
}

/// Normaliza um valor que deveria ser um objeto JSON. Alguns servidores
/// Xtream retornam `[]` (lista vazia) no lugar de `{}`/`null` quando não há
/// dados (ex: campo `info` de um episódio sem metadados).
Map<String, dynamic> asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((key, v) => MapEntry(key.toString(), v));
  return const {};
}

/// Normaliza um valor que deveria ser uma lista de objetos JSON. Alguns
/// endpoints retornam `{}` (objeto vazio) no lugar de `[]` quando não há
/// resultados.
List<Map<String, dynamic>> asMapList(dynamic value) {
  if (value is List) {
    return value.whereType<Map>().map((e) {
      return e.map((key, v) => MapEntry(key.toString(), v));
    }).toList();
  }
  return const [];
}

/// `get_short_epg` (guia de programação) retorna `title`/`description` em
/// base64 -- especificação padrão da API Xtream Codes, ao contrário de
/// qualquer outro campo de texto usado no resto deste app. Alguns painéis
/// desrespeitam isso e mandam texto puro mesmo assim; se decodificar como
/// base64 válido não der um UTF-8 válido (ou não for base64 válido de
/// início), cai pro valor original sem decodificar, nunca lança exceção.
String asBase64String(dynamic value, [String fallback = '']) {
  final raw = asString(value, fallback);
  if (raw.isEmpty) return raw;
  try {
    return utf8.decode(base64.decode(raw));
  } catch (_) {
    return raw;
  }
}
