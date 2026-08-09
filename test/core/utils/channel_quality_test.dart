import 'package:flutter_test/flutter_test.dart';

import 'package:iptv_app/core/utils/channel_quality.dart';

void main() {
  group('parseChannelQuality', () {
    test('reconhece FHD no fim do nome', () {
      expect(parseChannelQuality('Globo FHD'), ChannelQuality.fhd);
    });

    test('reconhece HD no fim do nome', () {
      expect(parseChannelQuality('SporTV HD'), ChannelQuality.hd);
    });

    test('reconhece SD no fim do nome', () {
      expect(parseChannelQuality('Record SD'), ChannelQuality.sd);
    });

    test('é insensível a caixa', () {
      expect(parseChannelQuality('Globo fhd'), ChannelQuality.fhd);
    });

    test('"FHD" nunca é confundido com "HD" (sem fronteira de palavra entre F e H)', () {
      expect(parseChannelQuality('Globo FHD'), ChannelQuality.fhd);
    });

    test('null quando o nome não tem nenhuma tag reconhecida', () {
      expect(parseChannelQuality('Globo'), isNull);
      expect(parseChannelQuality('Canal Qualquer'), isNull);
      expect(parseChannelQuality(''), isNull);
    });

    test('não confunde "HD" dentro de outra palavra, ex: "HDTV" (sem fronteira de palavra depois do D)', () {
      expect(parseChannelQuality('Canal HDTV'), isNull);
    });
  });
}
