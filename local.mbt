// この PC の中からの発言。Claude Code の回答が終わったときに、Stop フックから送る

///|
const CLAUDE_COLOR : String = "#D97757" // Claude のオレンジ

///|
/// 常駐しているほうが待つソケット
fn socket_path() -> String {
  let uid = c_getuid()
  if c_exists(cstr("/run/user/\{uid}")) {
    "/run/user/\{uid}/f1discord.sock"
  } else {
    "/tmp/f1discord-\{uid}.sock"
  }
}

///|
/// ソケットに届いた発言 {"author", "text", "channel", "number", "color"} を queue に入れる
fn Inbox::receive_local(self : Inbox) -> Unit {
  while true {
    let data = c_local_recv()
    if data.length() == 0 {
      break
    }
    guard parse_json(text_of(data)) is Ok(m) &&
      field(m, "author") is Some(String(author)) &&
      field(m, "text") is Some(String(text)) else {
      eprint("local: 発言が読めない\n")
      continue
    }
    fn str(key : String) -> String? {
      match field(m, key) {
        Some(String(s)) if s != "" => Some(s)
        _ => None
      }
    }

    eprint("local \{author}: \{text}\n")
    self.queue.push({
      author,
      text,
      channel: str("channel"),
      number: str("number"),
      color: str("color").bind(parse_color),
    })
  }
}

///|
/// モデルの id の番号。claude-opus-5-5 は 5.5、claude-fable-5-2 は 5.2 (末尾の日付は数えない)
fn model_number(model : String) -> String {
  let parts : Array[String] = []
  for part in model.split("-") {
    if part.length() > 0 &&
      part.length() <= 2 &&
      part.iter().all(c => c >= '0' && c <= '9') {
      parts.push(part.to_owned())
    }
  }
  parts.join(".")
}

///|
/// Claude Code の Stop フック。標準入力のフックの JSON から最後の回答とモデルを読み、常駐しているほうに送る
fn claude_hook() -> Unit {
  guard parse_json(text_of(c_read_stdin())) is Ok(input) else { return }
  fn str(j : Json, key : String) -> String {
    match field(j, key) {
      Some(String(s)) => s
      _ => ""
    }
  }

  let mut text = str(input, "last_assistant_message")
  let mut model = ""
  // モデル (と、フックの JSON に回答が無ければ回答) は、会話の記録の最後のほうの assistant の行から読む
  let path = str(input, "transcript_path")
  if path != "" && c_exists(cstr(path)) {
    let lines = text_of(c_read_file(cstr(path))).split("\n").collect()
    let oldest = Int::max(lines.length() - 400, 0)
    for i = lines.length() - 1
        i >= oldest && (model == "" || text == "")
        i = i - 1 {
      guard parse_json(lines[i]) is Ok(entry) &&
        str(entry, "type") == "assistant" &&
        field(entry, "message") is Some(message) else {
        continue
      }
      if model == "" && str(message, "model").has_prefix("claude") {
        model = str(message, "model")
      }
      if text == "" && field(message, "content") is Some(Array(parts)) {
        for part in parts {
          if str(part, "type") == "text" {
            text = text + str(part, "text")
          }
        }
      }
    }
  }
  // Markdown の強調とコードの印は、そのまま出ると読みにくいので落とす
  let text = text.replace_all(old="**", new="").replace_all(old="`", new="")
  // 長い回答は頭だけ (どのみち MAX_LINES 行までしか出ない)
  let chars = text.to_array()
  let text = if chars.length() > 300 {
    String::from_array(chars[:300]) + "…"
  } else {
    text
  }
  let cwd = str(input, "cwd").trim_end(chars="/").to_owned()
  let channel = match cwd.rev_find("/") {
    Some(slash) => cwd[slash + 1:].to_owned()
    None => cwd
  }
  let msg : Map[String, String] = {
    "author": "Claude",
    "text": text,
    "channel": channel,
    "number": model_number(model),
    "color": CLAUDE_COLOR,
  }
  // 常駐しているほうが動いていなければ、何もしない
  c_local_send(cstr(socket_path()), @utf8.encode(msg.to_json().stringify()))
  |> ignore
}
