import 'dart:math' as math;

/// A token's character span in the source text, from the model's tokenizer
/// (spec FR6).
class TokenSpan {
  final int start; // inclusive character offset
  final int end; // exclusive character offset

  const TokenSpan(this.start, this.end);
}

/// The model's token ids and attention mask for one string (spec FR8).
class TokenizedInput {
  final List<int> inputIds;
  final List<int> attentionMask;

  const TokenizedInput({required this.inputIds, required this.attentionMask});
}

/// Tokenizes the way the active model's tokenizer does (spec FR6, FR8).
///
/// Two capabilities: [tokenize] returns character spans for the chunker, and
/// [encode] returns the ids + attention mask the embedder feeds to ONNX.
abstract interface class Tokenizer {
  /// Token character spans, in order, for chunk boundaries.
  List<TokenSpan> tokenize(String text);

  /// The model input for [text]: ids plus a same-length attention mask.
  TokenizedInput encode(String text);
}

/// One chunk of a note body (spec FR6).
class TextChunk {
  /// 0-based and contiguous across the whole body.
  final int index;
  final String content;
  final int tokenCount;

  const TextChunk({
    required this.index,
    required this.content,
    required this.tokenCount,
  });
}

/// Turns a note body into ordered text chunks (spec FR6).
abstract interface class TextChunker {
  /// Deterministic. Returns an empty list for an empty or whitespace-only body.
  /// Indices are contiguous from 0.
  List<TextChunk> chunk(String body);
}

/// The default chunker: **heading-aware sections with a token-window fallback**
/// (spec D24).
///
/// Markdown ATX headings (`^#{1,6}\s`) start a new section and are never merged
/// across. Any section whose token count exceeds [maxTokens] is split by a
/// sliding token window with [overlap]; smaller sections are one chunk.
class HeadingAwareTextChunker implements TextChunker {
  /// Derived from the blueprint's 400-word / 50-overlap window at ~1.3
  /// tokens/word (spec D24). Constants, not configuration.
  static const int defaultMaxTokens = 512;
  static const int defaultOverlap = 64;

  HeadingAwareTextChunker({
    required this.tokenizer,
    this.maxTokens = defaultMaxTokens,
    this.overlap = defaultOverlap,
  }) {
    if (overlap >= maxTokens) {
      throw ArgumentError('overlap ($overlap) must be less than maxTokens '
          '($maxTokens)');
    }
  }

  final Tokenizer tokenizer;
  final int maxTokens;
  final int overlap;

  static final RegExp _heading = RegExp(r'^#{1,6}\s.*$', multiLine: true);

  @override
  List<TextChunk> chunk(String body) {
    if (body.trim().isEmpty) return const [];

    final chunks = <TextChunk>[];

    // Section boundaries: the body is cut at each heading start, with any
    // leading text before the first heading as its own section.
    final starts = _heading.allMatches(body).map((m) => m.start).toList();
    final boundaries = <int>[0, ...starts.where((s) => s > 0), body.length];

    for (var b = 0; b < boundaries.length - 1; b++) {
      final sectionStart = boundaries[b];
      final sectionEnd = boundaries[b + 1];
      if (sectionEnd <= sectionStart) continue;

      final sectionText = body.substring(sectionStart, sectionEnd);
      final spans = tokenizer.tokenize(sectionText);
      if (spans.isEmpty) continue;

      var i = 0;
      while (i < spans.length) {
        final end = math.min(i + maxTokens, spans.length);
        final content = sectionText.substring(spans[i].start, spans[end - 1].end);
        chunks.add(TextChunk(
          index: chunks.length,
          content: content,
          tokenCount: end - i,
        ));
        if (end == spans.length) break;
        i += maxTokens - overlap;
      }
    }

    return chunks;
  }
}

/// A whitespace tokenizer for tests and the pre-M6 default (spec FR6).
///
/// One token per non-whitespace run, with character offsets. The real tokenizer
/// (M6) replaces this behind the same [Tokenizer] interface.
class WhitespaceTokenizer implements Tokenizer {
  static final RegExp _token = RegExp(r'\S+');

  @override
  List<TokenSpan> tokenize(String text) =>
      [for (final m in _token.allMatches(text)) TokenSpan(m.start, m.end)];

  /// A placeholder encoding: one synthetic id per word, wrapped in `0`
  /// sentinels. Only used where a tokenizer is required but a real model is not
  /// (the deterministic embedder never calls this).
  @override
  TokenizedInput encode(String text) {
    final spans = tokenize(text);
    final ids = [for (var i = 0; i < spans.length; i++) i + 1];
    return TokenizedInput(
      inputIds: [0, ...ids, 0],
      attentionMask: [1, ...List.filled(ids.length, 1), 1],
    );
  }
}
