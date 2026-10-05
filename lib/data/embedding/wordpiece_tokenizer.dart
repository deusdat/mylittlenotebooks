import 'text_chunker.dart';

/// A pure-Dart BERT WordPiece tokenizer (spec FR6, FR8).
///
/// Loads a Hugging Face `tokenizer.json` and produces both the character spans
/// the chunker needs and the `input_ids`/`attention_mask` the embedder needs.
///
/// The pinned fast path is the Rust `tokenizers` bridge (spec D17). This Dart
/// implementation is the shipped default so the embedding stack runs with no
/// native tokenizer build; the [Tokenizer] seam is identical, so swapping in
/// the bridge later is a constructor change.
class WordPieceTokenizer implements Tokenizer {
  WordPieceTokenizer({
    required Map<String, int> vocab,
    String continuingSubwordPrefix = '##',
    String unkToken = '[UNK]',
    String clsToken = '[CLS]',
    String sepToken = '[SEP]',
    int maxInputCharsPerWord = 100,
    this.lowercase = true,
    this.stripAccents = true,
  })  : _vocab = vocab,
        _continuing = continuingSubwordPrefix,
        _unkId = vocab[unkToken] ?? 1,
        _clsId = vocab[clsToken] ?? 101,
        _sepId = vocab[sepToken] ?? 102,
        _maxChars = maxInputCharsPerWord;

  /// Parses the subset of a Hugging Face `tokenizer.json` this tokenizer needs.
  factory WordPieceTokenizer.fromJson(Map<String, dynamic> json) {
    final model = (json['model'] as Map).cast<String, dynamic>();
    final rawVocab = (model['vocab'] as Map).cast<String, dynamic>();
    final vocab = <String, int>{
      for (final e in rawVocab.entries) e.key: e.value as int,
    };

    var lowercase = true;
    var stripAccents = true;
    final normalizer = json['normalizer'];
    if (normalizer is Map) {
      final n = normalizer.cast<String, dynamic>();
      lowercase = (n['lowercase'] as bool?) ?? true;
      stripAccents = (n['strip_accents'] as bool?) ?? lowercase;
    }

    return WordPieceTokenizer(
      vocab: vocab,
      continuingSubwordPrefix:
          (model['continuing_subword_prefix'] as String?) ?? '##',
      unkToken: (model['unk_token'] as String?) ?? '[UNK]',
      clsToken: '[CLS]',
      sepToken: '[SEP]',
      maxInputCharsPerWord: (model['max_input_chars_per_word'] as int?) ?? 100,
      lowercase: lowercase,
      stripAccents: stripAccents,
    );
  }

  final Map<String, int> _vocab;
  final String _continuing;
  final int _unkId;
  final int _clsId;
  final int _sepId;
  final int _maxChars;
  final bool lowercase;
  final bool stripAccents;

  /// BertPreTokenizer's rule: runs of letters/digits, and every non-alphanumeric
  /// (punctuation, including `_`) split out on its own. Unicode-aware so accented
  /// letters and non-Latin scripts are not shattered.
  static final RegExp _preToken =
      RegExp(r'[\p{L}\p{N}]+|[^\s\p{L}\p{N}]', unicode: true);

  @override
  List<TokenSpan> tokenize(String text) {
    // Word-level spans: one span per pre-token, so chunk boundaries align to
    // words rather than subwords (spec FR6).
    return [
      for (final match in _preToken.allMatches(text))
        TokenSpan(match.start, match.end),
    ];
  }

  @override
  TokenizedInput encode(String text) {
    final ids = <int>[_clsId];
    for (final match in _preToken.allMatches(text)) {
      final word = _normalize(match.group(0)!);
      for (final id in _wordPiece(word)) {
        ids.add(id);
      }
    }
    ids.add(_sepId);
    return TokenizedInput(
      inputIds: ids,
      attentionMask: List<int>.filled(ids.length, 1),
    );
  }

  List<int> _wordPiece(String word) {
    if (word.length > _maxChars) return [_unkId];

    var start = 0;
    final ids = <int>[];
    while (start < word.length) {
      var end = word.length;
      int? matched;
      while (start < end) {
        final piece = word.substring(start, end);
        final candidate = start == 0 ? piece : '$_continuing$piece';
        final id = _vocab[candidate];
        if (id != null) {
          matched = id;
          break;
        }
        end--;
      }
      if (matched == null) {
        // The whole word is unknown; emit a single UNK (BERT's behaviour for
        // greedily unmatched words).
        return [_unkId];
      }
      ids.add(matched);
      start = end;
    }
    return ids;
  }

  String _normalize(String word) {
    var result = lowercase ? word.toLowerCase() : word;
    if (stripAccents) result = _stripAccentsFrom(result);
    return result;
  }

  /// Strips the common Latin accents BERT's normalizer removes. Not a full NFD;
  /// sufficient for the English uncased vocabulary nomic-embed uses.
  static const Map<String, String> _accentMap = {
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
    'ç': 'c', 'ñ': 'n', 'ý': 'y', 'ÿ': 'y',
  };

  static String _stripAccentsFrom(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      buffer.write(_accentMap[ch] ?? ch);
    }
    return buffer.toString();
  }
}
