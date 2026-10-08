import 'package:http/http.dart' as http;

import '../../core/constants/app_constants.dart';

const _maxRedirectHops = 5;

/// POST de um corpo JSON num Web App do Google Apps Script, seguindo o
/// redirecionamento normal dele: toda URL `/exec` responde 302 (corpo vazio)
/// para `script.googleusercontent.com`, onde mora o resultado já pronto,
/// buscado via GET. Não é falha de rede. Limite de saltos finito pra nunca
/// entrar em loop.
Future<http.Response> postJsonFollowingRedirects(http.Client client, Uri uri, String body) async {
  var response = await client
      .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
      .timeout(AppConstants.networkTimeout);
  var current = uri;
  var hops = _maxRedirectHops;
  while (response.statusCode >= 300 && response.statusCode < 400 && hops > 0) {
    final location = response.headers['location'];
    if (location == null || location.isEmpty) break;
    current = current.resolve(location);
    response = await client.get(current).timeout(AppConstants.networkTimeout);
    hops--;
  }
  return response;
}
