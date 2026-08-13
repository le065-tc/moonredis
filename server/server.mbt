///|
/// Single-threaded TCP server implementing the moonredis protocol.
struct Client {
  id : Int
  fd : UInt64
  read_buf : @ref.Ref[Bytes]
  write_buf : @ref.Ref[Bytes]
  ctx : @ref.Ref[@commands.Ctx]
  closed : @ref.Ref[Bool]
}

///|
pub struct Server {
  store : @store.Store
  hub : @commands.Hub
  clients : @hashmap.HashMap[Int, Client]
  mut next_id : Int
  aof_path : String
  aof_enabled : Bool
  mut running : Bool
  mut tick : Int
}

///|
pub fn Server::new(
  aof_path? : String = "",
  aof_enabled? : Bool = false,
) -> Server {
  let store = @store.Store::new(now=@native.now_ms)
  let server = {
    store,
    hub: @commands.Hub::new(),
    clients: @hashmap.HashMap::new(),
    next_id: 1,
    aof_path,
    aof_enabled,
    running: false,
    tick: 0,
  }
  if aof_enabled && !aof_path.is_empty() {
    replay_aof(server)
  }
  server
}

///|
pub fn Server::start(self : Server, port : Int) -> Unit {
  let fd = @native.tcp_listen_ffi(port)
  if fd == 0 {
    println("moonredis: failed to listen on port \{port}")
    return
  }
  let _ = @native.tcp_set_nonblock_ffi(fd)
  self.running = true
  println("moonredis: listening on 127.0.0.1:\{port} (aof=\{self.aof_enabled})")
  while self.running {
    // Accept new connections.
    if @native.tcp_wait_read_ffi(fd, 100) == 1 {
      while true {
        let c = @native.tcp_accept_ffi(fd)
        if c == 0 {
          break
        }
        let _ = @native.tcp_set_nonblock_ffi(c)
        let id = self.next_id
        self.next_id = self.next_id + 1
        let client = {
          id,
          fd: c,
          read_buf: @ref.Ref::new(Bytes::make(0, 0)),
          write_buf: @ref.Ref::new(Bytes::make(0, 0)),
          ctx: @ref.Ref::new(@commands.Ctx::new(self.store, self.hub, id)),
          closed: @ref.Ref::new(false),
        }
        self.clients.set(id, client)
      }
    }
    // Serve existing clients.
    let ids = self.clients.keys().to_array()
    for id in ids {
      match self.clients.get(id) {
        None => ()
        Some(client) => {
          self.service_client(client)
          if client.closed.val {
            let _ = @native.tcp_close_ffi(client.fd)
            self.hub.unsubscribe_all(id)
            self.clients.remove(id)
          }
        }
      }
    }
    self.tick = self.tick + 1
    if self.tick % 5000 == 0 {
      // Active expiry sweep.
      let _ = self.store.keys()
    }
  }
  let _ = @native.tcp_close_ffi(fd)
  println("moonredis: shutdown")
}

///|
fn Server::service_client(self : Server, client : Client) -> Unit {
  if @native.tcp_wait_read_ffi(client.fd, 0) == 1 {
    let chunk = Bytes::make(4096, 0)
    let n = @native.tcp_read_ffi(client.fd, chunk, chunk.length())
    if n <= 0 {
      client.closed.val = true
      return
    }
    client.read_buf.val = bytes_concat(
      client.read_buf.val,
      bytes_slice(chunk, 0, n),
    )
    self.process_input(client)
  }
  self.flush_client(client)
  if client.ctx.val.shutdown {
    client.closed.val = true
    self.running = false
  }
}

///|
fn Server::process_input(self : Server, client : Client) -> Unit {
  while true {
    match @resp.parse(client.read_buf.val) {
      @resp.Incomplete => break
      @resp.Invalid(msg) => {
        client.write_buf.val = bytes_concat(
          client.write_buf.val,
          @resp.encode(@resp.Error(msg)),
        )
        client.closed.val = true
        break
      }
      @resp.Complete(value, consumed) => {
        client.read_buf.val = bytes_slice(
          client.read_buf.val,
          consumed,
          client.read_buf.val.length() - consumed,
        )
        match value_to_args(value) {
          None =>
            client.write_buf.val = bytes_concat(
              client.write_buf.val,
              @resp.encode(
                @resp.Error("ERR Protocol error: invalid command format"),
              ),
            )
          Some(args) => {
            let name = upper(
              @utf8.decode_lossy(if args.is_empty() { b"" } else { args[0] }),
            )
            let reply = self.run_command(client, args)
            client.write_buf.val = bytes_concat(
              client.write_buf.val,
              @resp.encode(reply),
            )
            if name == "PUBLISH" && args.length() == 3 {
              self.deliver(@utf8.decode_lossy(args[1]), args[2])
            }
            if @commands.is_write_command(name) && self.aof_enabled {
              let _ = @native.file_append(self.aof_path, encode_command(args))
            }
            if client.ctx.val.shutdown {
              client.closed.val = true
              self.running = false
            }
          }
        }
      }
    }
  }
}

///|
fn Server::run_command(
  self : Server,
  client : Client,
  args : Array[Bytes],
) -> @resp.Value {
  let c = client.ctx.val
  let reply = @commands.execute(c, args)
  client.ctx.val = c
  reply
}

///|
fn Server::deliver(self : Server, channel : String, message : Bytes) -> Unit {
  let ids = self.hub.publish(channel)
  for id in ids {
    match self.clients.get(id) {
      None => ()
      Some(client) =>
        if !client.closed.val {
          let push = @resp.Push([
            @resp.BulkString(@utf8.encode("message")),
            @resp.BulkString(@utf8.encode(channel)),
            @resp.BulkString(message),
          ])
          client.write_buf.val = bytes_concat(
            client.write_buf.val,
            @resp.encode(push),
          )
          self.flush_client(client)
        }
    }
  }
}

///|
fn Server::flush_client(self : Server, client : Client) -> Unit {
  while client.write_buf.val.length() > 0 && !client.closed.val {
    let n = @native.tcp_write_ffi(
      client.fd,
      client.write_buf.val,
      client.write_buf.val.length(),
    )
    if n <= 0 {
      break
    }
    client.write_buf.val = bytes_slice(
      client.write_buf.val,
      n,
      client.write_buf.val.length() - n,
    )
  }
}

///|
fn value_to_args(v : @resp.Value) -> Array[Bytes]? {
  match v {
    @resp.Array(items) => {
      let out : Array[Bytes] = []
      for item in items {
        match item {
          @resp.BulkString(b) => out.push(b)
          @resp.SimpleString(s) => out.push(@utf8.encode(s))
          _ => return None
        }
      }
      Some(out)
    }
    _ => None
  }
}

///|
fn encode_command(args : Array[Bytes]) -> Bytes {
  let items : Array[@resp.Value] = []
  for b in args {
    items.push(@resp.BulkString(b))
  }
  @resp.encode(@resp.Array(items))
}

///|
fn replay_aof(server : Server) -> Unit {
  let data = @native.file_read_all(server.aof_path)
  if data.length() == 0 {
    return
  }
  let mut buf = data
  while true {
    match @resp.parse(buf) {
      @resp.Incomplete => break
      @resp.Invalid(_) => break
      @resp.Complete(value, consumed) => {
        buf = bytes_slice(buf, consumed, buf.length() - consumed)
        match value_to_args(value) {
          None => ()
          Some(args) => {
            let ctx = @commands.Ctx::new(server.store, server.hub, -1)
            let _ = @commands.execute(ctx, args)
          }
        }
      }
    }
  }
  println("moonredis: replayed AOF from \{server.aof_path}")
}

///|
fn bytes_concat(a : Bytes, b : Bytes) -> Bytes {
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
fn bytes_slice(b : Bytes, start : Int, len : Int) -> Bytes {
  if len <= 0 {
    return Bytes::make(0, 0)
  }
  let out = Buffer()
  for i = 0; i < len; i = i + 1 {
    out.write_byte(b[start + i])
  }
  out.to_bytes()
}

///|
fn upper(s : String) -> String {
  let b = @utf8.encode(s)
  let out = Buffer()
  for i = 0; i < b.length(); i = i + 1 {
    let c = b[i]
    if c >= b'a' && c <= b'z' {
      out.write_byte(c - (b'a' - b'A'))
    } else {
      out.write_byte(c)
    }
  }
  @utf8.decode_lossy(out.to_bytes())
}
