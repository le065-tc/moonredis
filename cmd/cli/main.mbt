///|
fn main {
  let args = @native.get_cli_args()
  let mut port = 6379
  let mut cmd_start = 1
  if args.length() >= 3 && args[1] == "--port" {
    match parse_int(args[2]) {
      Some(v) => port = v
      None => ()
    }
    cmd_start = 3
  }
  let fd = @native.tcp_connect_ffi(port)
  if fd == 0 {
    println("moonredis-cli: cannot connect to 127.0.0.1:\{port}")
    return
  }
  if cmd_start >= args.length() {
    println("moonredis-cli: usage: moonredis-cli [--port N] COMMAND [ARGS...]")
    let _ = @native.tcp_close_ffi(fd)
    return
  }
  let cmd : Array[Bytes] = []
  for i = cmd_start; i < args.length(); i = i + 1 {
    cmd.push(@utf8.encode(args[i]))
  }
  let items : Array[@resp.Value] = []
  for b in cmd {
    items.push(@resp.BulkString(b))
  }
  let payload = @resp.encode(@resp.Array(items))
  let _ = @native.tcp_write_ffi(fd, payload, payload.length())

  let mut buf = Bytes::make(0, 0)
  let mut reply : @resp.Value? = None
  while reply is None {
    let chunk = Bytes::make(4096, 0)
    let n = @native.tcp_read_ffi(fd, chunk, chunk.length())
    if n <= 0 {
      break
    }
    buf = concat(buf, slice(chunk, 0, n))
    match @resp.parse(buf) {
      @resp.Complete(v, _) => reply = Some(v)
      _ => ()
    }
  }
  match reply {
    None => println("moonredis-cli: no reply")
    Some(v) => print_value(v, 0)
  }
  let _ = @native.tcp_close_ffi(fd)
}

///|
fn print_value(v : @resp.Value, depth : Int) -> Unit {
  println(format_value(v))
}

///|
fn format_value(v : @resp.Value) -> String {
  match v {
    @resp.SimpleString(s) => s
    @resp.Error(s) => "(error) \{s}"
    @resp.Integer(n) => n.to_string()
    @resp.BulkString(b) => @utf8.decode_lossy(b)
    @resp.NullBulk => "(nil)"
    @resp.Null => "(nil)"
    @resp.Boolean(b) => if b { "true" } else { "false" }
    @resp.Double(d) => d.to_string()
    @resp.Array(items) | @resp.Push(items) => {
      if items.is_empty() {
        return "(empty array)"
      }
      let out = Buffer()
      for i = 0; i < items.length(); i = i + 1 {
        let prefix = if i == items.length() - 1 { "`-" } else { "|-" }
        out.write_string_utf8("  \{prefix} ")
        out.write_string_utf8(format_value(items[i]))
        if i < items.length() - 1 {
          out.write_string_utf8("\n")
        }
      }
      out.to_string()
    }
  }
}

///|
fn parse_int(s : String) -> Int? {
  let b = @utf8.encode(s)
  if b.length() == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if b[0] == b'-' {
    neg = true
    i = 1
  }
  if i >= b.length() {
    return None
  }
  let mut v = 0
  while i < b.length() {
    let c = b[i]
    if c < b'0' || c > b'9' {
      return None
    }
    v = v * 10 + (c - b'0').to_int()
    i = i + 1
  }
  if neg {
    Some(-v)
  } else {
    Some(v)
  }
}

///|
fn concat(a : Bytes, b : Bytes) -> Bytes {
  if a.length() == 0 {
    return b
  }
  if b.length() == 0 {
    return a
  }
  let out = Buffer()
  out.write_bytes(a)
  out.write_bytes(b)
  out.to_bytes()
}

///|
fn slice(b : Bytes, start : Int, len : Int) -> Bytes {
  if len <= 0 {
    return Bytes::make(0, 0)
  }
  let out = Buffer()
  for i = 0; i < len; i = i + 1 {
    out.write_byte(b[start + i])
  }
  out.to_bytes()
}
