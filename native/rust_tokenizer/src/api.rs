//! The bridge API: `init_tokenizer` and `tokenize`.
//!
//! `flutter_rust_bridge_codegen` turns each `pub fn` here into a Dart function
//! under `lib/bridge/`. The output carries ids, an attention mask, and character
//! offsets, so one call serves both the embedder (ids + mask) and the chunker
//! (offsets) — spec FR6, FR8.

use std::str::FromStr;
use std::sync::RwLock;

use tokenizers::Tokenizer;

static TOKENIZER: RwLock<Option<Tokenizer>> = RwLock::new(None);

/// The tokenizer's output for one string.
pub struct TokenizedOutput {
    /// Model token ids, including the special `[CLS]`/`[SEP]` tokens.
    pub input_ids: Vec<i64>,
    /// A same-length mask, `1` for real tokens.
    pub attention_mask: Vec<i64>,
    /// `(start, end)` character offsets per token, for chunk boundaries.
    pub offsets: Vec<u32>,
}

/// Loads and installs the tokenizer from a `tokenizer.json`'s contents.
pub fn init_tokenizer(json_content: String) -> Result<(), String> {
    let tokenizer =
        Tokenizer::from_str(&json_content).map_err(|e| format!("tokenizer: {e}"))?;
    let mut guard = TOKENIZER.write().map_err(|e| format!("lock: {e}"))?;
    *guard = Some(tokenizer);
    Ok(())
}

/// Tokenizes `text` with the installed tokenizer.
pub fn tokenize(text: String) -> Result<TokenizedOutput, String> {
    let guard = TOKENIZER.read().map_err(|e| format!("lock: {e}"))?;
    let tokenizer = guard.as_ref().ok_or("tokenizer not initialized")?;

    let encoding = tokenizer
        .encode(text, true)
        .map_err(|e| format!("encode: {e}"))?;

    let mut offsets = Vec::with_capacity(encoding.len() * 2);
    for (start, end) in encoding.get_offsets() {
        offsets.push(*start as u32);
        offsets.push(*end as u32);
    }

    Ok(TokenizedOutput {
        input_ids: encoding.get_ids().iter().map(|&id| id as i64).collect(),
        attention_mask: encoding
            .get_attention_mask()
            .iter()
            .map(|&m| m as i64)
            .collect(),
        offsets,
    })
}
