///|
fn main {
  let args = @native.get_cli_args()
  let mut port = 6379
  let mut aof_path = ""
  let mut aof_enabled = false
  let mut i = 1
  while i < args.length() {
    let a = args[i]
    if a == "--port" {
      i = i + 1
      if i < args.length() {
        match parse_int(args[i]) {
          Some(v) => port = v
          None => println("moonredis: invalid --port value: \{args[i]}")
        }
      }
    } else if a == "--aof" {
      i = i + 1
      if i < args.length() {
        aof_path = args[i]
        aof_enabled = true
      }
    } else if a == "--appendonly" {
      i = i + 1
      if i < args.length() {
        let v = args[i]
        aof_enabled = v == "yes" || v == "true" || v == "1"
      }
    } else {
      println("moonredis: unknown argument: \{a}")
    }
    i = i + 1
  }
  println(
    "moonredis: starting (port=\{port}, aof=\{aof_enabled}, aof_path=\{aof_path})",
  )
  let server = @server.Server::new(aof_path~, aof_enabled~)
  server.start(port)
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
