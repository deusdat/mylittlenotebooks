import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/embedding/wordpiece_tokenizer.dart';

/// The pure-Dart WordPiece tokenizer (spec FR6, FR8), tested against a tiny
/// hand-written vocabulary so no model or `tokenizer.json` is needed.
void main() {
  final tokenizer = WordPieceTokenizer(
    vocab: const {
      '[PAD]': 0,
      '[UNK]': 1,
      '[CLS]': 2,
      '[SEP]': 3,
      'hello': 4,
      'world': 5,
      '##s': 6,
      '!': 7,
      'cafe': 8,
    },
    lowercase: true,
    stripAccents: true,
  );

  test('tokenize returns word-level character spans', () {
    final spans = tokenizer.tokenize('hello worlds!');
    expect(spans.map((s) => 'hello worlds!'.substring(s.start, s.end)).toList(),
        ['hello', 'worlds', '!']);
  });

  test('encode wraps ids in [CLS]/[SEP] and splits subwords', () {
    // hello -> [4]; worlds -> world + ##s -> [5, 6]; ! -> [7]
    expect(tokenizer.encode('hello worlds!').inputIds, [2, 4, 5, 6, 7, 3]);
  });

  test('encode lowercases by default', () {
    expect(tokenizer.encode('HELLO').inputIds, [2, 4, 3]);
  });

  test('an unknown word becomes a single UNK', () {
    expect(tokenizer.encode('hello ☃').inputIds, [2, 4, 1, 3]);
  });

  test('the attention mask matches the ids and is all ones', () {
    final encoded = tokenizer.encode('hello worlds');
    expect(encoded.attentionMask.length, encoded.inputIds.length);
    expect(encoded.attentionMask.every((m) => m == 1), isTrue);
  });

  test('equal input yields equal output', () {
    expect(tokenizer.encode('hello').inputIds,
        tokenizer.encode('hello').inputIds);
  });

  group('against the bundled tokenizer.json (HF reference)', () {
    final file = File('assets/tokenizers/tokenizer.json');

    test('the bundled tokenizer asset exists', () {
      expect(file.existsSync(), isTrue,
          reason: 'the model and tokenizer must be bundled (pubspec assets)');
    });

    test('produces the same ids as the Hugging Face tokenizer', () {
      final json =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final real = WordPieceTokenizer.fromJson(json);

      // Reference ids captured from HF `tokenizers` for the same strings.
      expect(real.encode('hello worlds!').inputIds, [101, 7592, 8484, 999, 102]);
      expect(real.encode('HELLO').inputIds, [101, 7592, 102]);
      expect(
        real
            .encode('search_document: The mitochondria is the powerhouse of '
                'the cell.')
            .inputIds,
        [101, 3945, 1035, 6254, 1024, 1996, 10210, 11663, 15422, 4360, 2003,
          1996, 24006, 1997, 1996, 3526, 1012, 102],
      );
    });
  });
}
