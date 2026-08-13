///|
/// RESP (REdis Serialization Protocol) value types, parser and encoder.
///
/// Supports the RESP2 types used by common Redis clients plus a few RESP3
/// types (Boolean, Double, Push) so that `HELLO 3` works.
pub(all) enum Value {
  SimpleString(String)
  Error(String)
  Integer(Int64)
  BulkString(Bytes)
  NullBulk
  Array(Array[Value])
  Null
  Boolean(Bool)
  Double(Double)
  Push(Array[Value])
}

///|
/// Parse result: a complete value and consumed byte count, an incomplete
/// message, or a protocol error.
pub(all) enum ParseResult {
  Complete(Value, Int)
  Incomplete
  Invalid(String)
}

///|
/// Tries to parse one RESP value (or one inline command) from the beginning
/// of `buf`. The `Int` in `Complete` is the number of consumed bytes.
pub fn parse(buf : Bytes) -> ParseResult {
  parse_at(buf, 0)
}

///|
fn parse_at(buf : Bytes, pos : Int) -> ParseResult {
  if pos >= buf.length() {
    return Incomplete
  }
  let first = buf[pos]
  if first == b'*' {
    parse_array(buf, pos)
  } else if first == b'$' {
    parse_bulk(buf, pos)
  } else if first == b'+' {
    parse_simple(buf, pos)
  } else if first == b'-' {
    parse_error(buf, pos)
  } else if first == b':' {
    parse_integer(buf, pos)
  } else if first == b'_' {
    if buf.length() < pos + 3 {
      Incomplete
    } else if buf[pos + 1] == b'\r' && buf[pos + 2] == b'\n' {
      Complete(Null, pos + 3)
    } else {
      Invalid("bad null")
    }
  } else if first == b'#' {
    parse_boolean(buf, pos)
  } else if first == b',' {
    parse_double(buf, pos)
  } else if first == b'>' {
    parse_push(buf, pos)
  } else if first == b'%' || first == b'~' {
    // RESP3 map / set are represented as flat arrays (documented subset).
    parse_array(buf, pos)
  } else {
    parse_inline(buf, pos)
  }
}

///|
fn parse_array(buf : Bytes, pos : Int) -> ParseResult {
  match parse_len_header(buf, pos, b'*') {
    None => Incomplete
    Some((count, next)) => {
      if count < 0 {
        return Complete(Null, next)
      }
      let items : Array[Value] = []
      let mut p = next
      for _ in 0..<count {
        let r = parse_at(buf, p)
        match r {
          Complete(v, consumed) => {
            items.push(v)
            p = consumed
          }
          Incomplete => return Incomplete
          Invalid(msg) => return Invalid(msg)
        }
      }
      Complete(Array(items), p)
    }
  }
}

///|
fn parse_bulk(buf : Bytes, pos : Int) -> ParseResult {
  match parse_len_header(buf, pos, b'$') {
    None => Incomplete
    Some((len, next)) => {
      if len < 0 {
        return Complete(NullBulk, next)
      }
      if next + len + 2 > buf.length() {
        return Incomplete
      }
      let data = bytes_slice(buf, next, len)
      if buf[next + len] != b'\r' || buf[next + len + 1] != b'\n' {
        return Invalid("bad bulk terminator")
      }
      Complete(BulkString(data), next + len + 2)
    }
  }
}

///|
fn parse_simple(buf : Bytes, pos : Int) -> ParseResult {
  match read_line(buf, pos + 1) {
    None => Incomplete
    Some((line, next)) => Complete(SimpleString(bytes_to_string(line)), next)
  }
}

///|
fn parse_error(buf : Bytes, pos : Int) -> ParseResult {
  match read_line(buf, pos + 1) {
    None => Incomplete
    Some((line, next)) => Complete(Error(bytes_to_string(line)), next)
  }
}

///|
fn parse_integer(buf : Bytes, pos : Int) -> ParseResult {
  match read_line(buf, pos + 1) {
    None => Incomplete
    Some((line, next)) =>
      match parse_int64(line) {
        Some(v) => Complete(Integer(v), next)
        None => Invalid("bad integer")
      }
  }
}

///|
fn parse_boolean(buf : Bytes, pos : Int) -> ParseResult {
  if buf.length() < pos + 4 {
    return Incomplete
  }
  if buf[pos + 1] == b't' && buf[pos + 2] == b'\r' && buf[pos + 3] == b'\n' {
    return Complete(Boolean(true), pos + 4)
  }
  if buf[pos + 1] == b'f' && buf[pos + 2] == b'\r' && buf[pos + 3] == b'\n' {
    return Complete(Boolean(false), pos + 4)
  }
  Invalid("bad boolean")
}

///|
fn parse_double(buf : Bytes, pos : Int) -> ParseResult {
  match read_line(buf, pos + 1) {
    None => Incomplete
    Some((line, next)) =>
      match parse_double_bytes(line) {
        Some(v) => Complete(Double(v), next)
        None => Invalid("bad double")
      }
  }
}

///|
fn parse_push(buf : Bytes, pos : Int) -> ParseResult {
  match parse_len_header(buf, pos, b'>') {
    None => Incomplete
    Some((count, next)) => {
      let items : Array[Value] = []
      let mut p = next
      for _ in 0..<count {
        let r = parse_at(buf, p)
        match r {
          Complete(v, consumed) => {
            items.push(v)
            p = consumed
          }
          Incomplete => return Incomplete
          Invalid(msg) => return Invalid(msg)
        }
      }
      Complete(Push(items), p)
    }
  }
}

///|
/// Inline commands such as `PING\r\n` or `SET a 1\r\n`.
fn parse_inline(buf : Bytes, pos : Int) -> ParseResult {
  match read_line(buf, pos) {
    None => Incomplete
    Some((line, next)) => {
      let text = bytes_to_string(line).trim()
      if text.is_empty() {
        return Complete(Array([]), next)
      }
      let parts = text.split(" ")
      let items : Array[Value] = []
      for part in parts {
        if !part.is_empty() {
          items.push(BulkString(@utf8.encode(part)))
        }
      }
      Complete(Array(items), next)
    }
  }
}

///|
/// Parses `*<count>\r\n`, `$<len>\r\n` or `><count>\r\n` headers.
fn parse_len_header(buf : Bytes, pos : Int, marker : Byte) -> (Int, Int)? {
  if buf.length() <= pos || buf[pos] != marker {
    return None
  }
  match read_line(buf, pos + 1) {
    None => None
    Some((line, next)) =>
      match parse_int64(line) {
        Some(v) => Some((v.to_int(), next))
        None => None
      }
  }
}

///|
/// Reads a CRLF-terminated line starting at `pos` (excluding CRLF).
fn read_line(buf : Bytes, pos : Int) -> (Bytes, Int)? {
  let mut i = pos
  while i + 1 < buf.length() {
    if buf[i] == b'\r' && buf[i + 1] == b'\n' {
      return Some((bytes_slice(buf, pos, i - pos), i + 2))
    }
    i = i + 1
  }
  None
}

///|
fn parse_int64(b : Bytes) -> Int64? {
  if b.length() == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if b[0] == b'-' {
    neg = true
    i = 1
  } else if b[0] == b'+' {
    i = 1
  }
  if i >= b.length() {
    return None
  }
  let mut v : Int64 = 0
  while i < b.length() {
    let c = b[i]
    if c < b'0' || c > b'9' {
      return None
    }
    v = v * 10L + (c.to_int64() - b'0'.to_int64())
    i = i + 1
  }
  if neg {
    Some(-v)
  } else {
    Some(v)
  }
}

///|
pub fn parse_double_bytes(b : Bytes) -> Double? {
  let s = bytes_to_string(b).trim()
  if s == "inf" || s == "+inf" {
    return Some(@double.infinity)
  }
  if s == "-inf" {
    return Some(@double.neg_infinity)
  }
  if s.is_empty() {
    return None
  }
  let bytes = @utf8.encode(s)
  let mut i = 0
  let mut neg = false
  if bytes[0] == b'-' {
    neg = true
    i = 1
  } else if bytes[0] == b'+' {
    i = 1
  }
  if i >= bytes.length() {
    return None
  }
  let mut value = 0.0
  let mut frac = 0.0
  let mut frac_div = 10.0
  let mut in_frac = false
  let mut has_digit = false
  let mut exp : Int = 0
  let mut exp_neg = false
  let mut in_exp = false
  while i < bytes.length() {
    let c = bytes[i]
    if c >= b'0' && c <= b'9' {
      has_digit = true
      let d = (c - b'0').to_int().to_double()
      if in_exp {
        exp = exp * 10 + (c - b'0').to_int()
      } else if in_frac {
        frac = frac + d / frac_div
        frac_div = frac_div * 10.0
      } else {
        value = value * 10.0 + d
      }
    } else if c == b'.' && !in_frac && !in_exp {
      in_frac = true
    } else if (c == b'e' || c == b'E') && !in_exp {
      in_exp = true
      if i + 1 < bytes.length() && bytes[i + 1] == b'-' {
        exp_neg = true
        i = i + 1
      } else if i + 1 < bytes.length() && bytes[i + 1] == b'+' {
        i = i + 1
      }
    } else {
      return None
    }
    i = i + 1
  }
  if !has_digit {
    return None
  }
  value = value + frac
  if exp != 0 {
    let mut factor = 1.0
    for _ in 0..<exp {
      factor = factor * 10.0
    }
    if exp_neg {
      value = value / factor
    } else {
      value = value * factor
    }
  }
  if neg {
    Some(-value)
  } else {
    Some(value)
  }
}

///|
fn bytes_slice(b : Bytes, start : Int, len : Int) -> Bytes {
  let out = Buffer()
  for i = 0; i < len; i = i + 1 {
    out.write_byte(b[start + i])
  }
  out.to_bytes()
}

///|
fn bytes_to_string(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}

///|
/// Encodes a value using RESP2 wire format.
pub fn encode(v : Value) -> Bytes {
  let out = Buffer()
  encode_into(out, v)
  out.to_bytes()
}

///|
fn encode_into(out : @buffer.Buffer, v : Value) -> Unit {
  match v {
    SimpleString(s) => {
      out.write_string_utf8("+")
      out.write_string_utf8(s)
      out.write_string_utf8("\r\n")
    }
    Error(s) => {
      out.write_string_utf8("-")
      out.write_string_utf8(s)
      out.write_string_utf8("\r\n")
    }
    Integer(n) => {
      out.write_string_utf8(":")
      out.write_string_utf8(n.to_string())
      out.write_string_utf8("\r\n")
    }
    BulkString(b) => {
      out.write_string_utf8("$")
      out.write_string_utf8(b.length().to_string())
      out.write_string_utf8("\r\n")
      out.write_bytes(b)
      out.write_string_utf8("\r\n")
    }
    NullBulk => out.write_string_utf8("$-1\r\n")
    Array(items) => {
      out.write_string_utf8("*")
      out.write_string_utf8(items.length().to_string())
      out.write_string_utf8("\r\n")
      for item in items {
        encode_into(out, item)
      }
    }
    Null => out.write_string_utf8("_\r\n")
    Boolean(b) =>
      if b {
        out.write_string_utf8("#t\r\n")
      } else {
        out.write_string_utf8("#f\r\n")
      }
    Double(f) => {
      out.write_string_utf8(",")
      out.write_string_utf8(f.to_string())
      out.write_string_utf8("\r\n")
    }
    Push(items) => {
      out.write_string_utf8(">")
      out.write_string_utf8(items.length().to_string())
      out.write_string_utf8("\r\n")
      for item in items {
        encode_into(out, item)
      }
    }
  }
}
