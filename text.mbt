// 字の扱い。切ったり測ったりしやすいように、文字列は字 (Char) の配列で持つ

///|
/// Python の str.isspace と同じ範囲
fn is_space(c : Char) -> Bool {
  let o = c.to_int()
  (o >= 0x09 && o <= 0x0D) ||
  (o >= 0x1C && o <= 0x20) ||
  o == 0x85 ||
  o == 0xA0 ||
  o == 0x1680 ||
  (o >= 0x2000 && o <= 0x200A) ||
  o == 0x2028 ||
  o == 0x2029 ||
  o == 0x202F ||
  o == 0x205F ||
  o == 0x3000
}

///|
/// フォントに無くて豆腐になる字 (絵文字、文字の向きの区切り) を落とし、空白をまとめる
fn clean(text : String) -> Array[Char] {
  let out : Array[Char] = []
  for c in text {
    let o = c.to_int()
    if (o >= 0x1F000 && o <= 0x1FAFF) ||
      (o >= 0x2600 && o <= 0x27BF) ||
      (o >= 0xFE00 && o <= 0xFE0F) ||
      (o >= 0xE0000 && o <= 0xE0FFF) ||
      o == 0x200B ||
      o == 0x200D ||
      o == 0x200E ||
      o == 0x200F ||
      (o >= 0x2066 && o <= 0x2069) {
      continue
    }
    if is_space(c) {
      // 続く空白は 1 つに、先頭の空白は捨てる
      if out.length() > 0 && out[out.length() - 1] != ' ' {
        out.push(' ')
      }
    } else {
      out.push(c)
    }
  }
  rstrip(out)
}

///|
fn upper(text : Array[Char]) -> Array[Char] {
  text.map(c => c_towupper(c.to_int()).unsafe_to_char())
}

///|
/// 末尾の空白を落としたもの
fn rstrip(text : Array[Char]) -> Array[Char] {
  let mut n = text.length()
  while n > 0 && text[n - 1] == ' ' {
    n -= 1
  }
  text[:n].to_owned()
}

///|
fn is_blank(text : Array[Char]) -> Bool {
  text.iter().all(c => c == ' ')
}

///|
fn codepoints(text : ArrayView[Char]) -> FixedArray[Int] {
  FixedArray::makei(text.length(), i => text[i].to_int())
}

///|
/// size の大きさのフォントで描いたときの幅
fn text_width(text : ArrayView[Char], size : Int) -> Double {
  c_text_width(size, codepoints(text), text.length())
}

///|
/// width に収まる、size 以下でいちばん大きいフォントの大きさ
fn fit_font(
  text : Array[Char],
  size : Int,
  width : Double,
  smallest : Int,
) -> Int {
  let mut size = size
  while size > smallest && text_width(text, size) > width {
    size -= 1
  }
  size
}

///|
fn ellipsize(text : Array[Char], size : Int, width : Double) -> Array[Char] {
  if text_width(text, size) <= width {
    return text
  }
  let text = text.copy()
  while text.length() > 0 && text_width([..text, '…'], size) > width {
    text.pop() |> ignore
  }
  text.push('…')
  text
}

///|
/// width に収まるように行に分ける。英数字の語は途中で切らず、日本語は 1 字ずつ切れる
fn wrap(text : Array[Char], size : Int, width : Double) -> Array[Array[Char]] {
  fn is_word(c : Char) -> Bool {
    c >= '!' && c <= '~'
  }

  let mut lines : Array[Array[Char]] = []
  let mut line : Array[Char] = []
  let mut i = 0
  while i < text.length() {
    // 次のひとかたまり: 英数字と記号の並び、空白の並び、それ以外は 1 字
    let start = i
    if is_word(text[i]) {
      while i < text.length() && is_word(text[i]) {
        i += 1
      }
    } else if is_space(text[i]) {
      while i < text.length() && is_space(text[i]) {
        i += 1
      }
      if line.length() > 0 {
        line.push(' ')
      }
      continue
    } else {
      i += 1
    }
    let mut tok = text[start:i]
    while text_width(tok, size) > width { // 1 語が 1 行より長い (URL など)
      if !is_blank(line) {
        lines.push(rstrip(line))
      }
      line = []
      let mut n = tok.length()
      while n > 1 && text_width(tok[:n], size) > width {
        n -= 1
      }
      lines.push(tok[:n].to_owned())
      tok = tok[n:]
    }
    if line.length() > 0 && text_width([..line, ..tok], size) > width {
      lines.push(rstrip(line))
      line = []
    }
    line.append(tok)
  }
  if !is_blank(line) {
    lines.push(rstrip(line))
  }
  if lines.length() > MAX_LINES {
    lines = lines[:MAX_LINES].to_owned()
    let last = lines[MAX_LINES - 1]
    lines[MAX_LINES - 1] = ellipsize([..last, '…'], size, width)
  }
  lines
}
