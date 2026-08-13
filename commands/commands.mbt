/// Command dispatch and implementations for moonredis.

///|
/// Pub/Sub hub keyed by channel name; subscribers are identified by their
/// connection id so the server can deliver messages to the right client.
pub struct Hub {
  channels : @hashmap.HashMap[String, @hashset.HashSet[Int]]
}

///|
pub fn Hub::new() -> Hub {
  { channels: @hashmap.HashMap::new() }
}

///|
pub fn Hub::subscribe(self : Hub, channel : String, id : Int) -> Unit {
  let set = self.channels.get_or_init(channel, fn() { @hashset.HashSet::new() })
  set.add(id)
}

///|
pub fn Hub::unsubscribe(self : Hub, channel : String, id : Int) -> Unit {
  match self.channels.get(channel) {
    None => ()
    Some(set) => {
      set.remove(id)
      if set.is_empty() {
        self.channels.remove(channel)
      }
    }
  }
}

///|
pub fn Hub::unsubscribe_all(self : Hub, id : Int) -> Unit {
  let to_remove : Array[String] = []
  for channel in self.channels.keys() {
    match self.channels.get(channel) {
      None => ()
      Some(set) => {
        set.remove(id)
        if set.is_empty() {
          to_remove.push(channel)
        }
      }
    }
  }
  for channel in to_remove {
    self.channels.remove(channel)
  }
}

///|
pub fn Hub::publish(self : Hub, channel : String) -> Array[Int] {
  match self.channels.get(channel) {
    None => []
    Some(set) => set.to_array()
  }
}

///|
pub fn Hub::subscriber_count(self : Hub) -> Int {
  let mut n = 0
  for set in self.channels.values() {
    n = n + set.length()
  }
  n
}

///|
/// Per-connection execution context.
pub struct Ctx {
  store : @store.Store
  hub : Hub
  client_id : Int
  mut queue : Array[Array[Bytes]]
  mut in_multi : Bool
  mut subscribed : Array[String]
  mut in_subscribe_mode : Bool
  config : @hashmap.HashMap[String, String]
  mut shutdown : Bool
}

///|
pub fn Ctx::new(store : @store.Store, hub : Hub, client_id : Int) -> Ctx {
  {
    store,
    hub,
    client_id,
    queue: [],
    in_multi: false,
    subscribed: [],
    in_subscribe_mode: false,
    config: @hashmap.HashMap::new(),
    shutdown: false,
  }
}

///|
pub fn Ctx::config_get(self : Ctx, key : String) -> String? {
  self.config.get(key)
}

///|
pub fn Ctx::config_set(self : Ctx, key : String, value : String) -> Unit {
  self.config.set(key, value)
}

///|
pub fn Ctx::is_subscribed(self : Ctx) -> Bool {
  self.in_subscribe_mode
}

///|
/// Commands that mutate state and therefore must be appended to the AOF.
pub fn is_write_command(name : String) -> Bool {
  match name {
    "SET"
    | "SETNX"
    | "SETRANGE"
    | "MSET"
    | "APPEND"
    | "INCR"
    | "DECR"
    | "INCRBY"
    | "DECRBY"
    | "DEL"
    | "EXPIRE"
    | "PEXPIRE"
    | "PERSIST"
    | "HSET"
    | "HMSET"
    | "HSETNX"
    | "HDEL"
    | "GETDEL"
    | "MSETNX"
    | "LPUSH"
    | "RPUSH"
    | "LPOP"
    | "RPOP"
    | "LSET"
    | "LTRIM"
    | "SADD"
    | "SREM"
    | "SPOP"
    | "ZADD"
    | "ZREM"
    | "ZINCRBY"
    | "FLUSHDB"
    | "FLUSHALL" => true
    _ => false
  }
}

///|
/// Executes one command and returns the RESP reply.
pub fn execute(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.is_empty() {
    return err("ERR empty command")
  }
  let name = upper(@utf8.decode_lossy(args[0]))

  // Subscribed mode restricts the allowed commands.
  if ctx.in_subscribe_mode &&
    !(name == "SUBSCRIBE" ||
    name == "UNSUBSCRIBE" ||
    name == "PING" ||
    name == "QUIT") {
    return err(
      "ERR only (P|S)SUBSCRIBE / UNSUBSCRIBE / PING / QUIT allowed in this context",
    )
  }

  // MULTI queueing: remember the command and answer QUEUED.
  if ctx.in_multi &&
    !(name == "MULTI" || name == "EXEC" || name == "DISCARD" || name == "QUIT") {
    ctx.queue.push(args)
    return @resp.SimpleString("QUEUED")
  }

  match name {
    "PING" => cmd_ping(ctx, args)
    "ECHO" => cmd_echo(args)
    "HELLO" => cmd_hello(args)
    "COMMAND" => cmd_command(args)
    "QUIT" => {
      ctx.shutdown = true
      @resp.SimpleString("OK")
    }
    "SELECT" => cmd_select(args)
    "DBSIZE" => @resp.Integer(ctx.store.size().to_int64())
    "FLUSHDB" | "FLUSHALL" => {
      ctx.store.flush()
      @resp.SimpleString("OK")
    }
    "KEYS" => cmd_keys(ctx, args)
    "TYPE" => cmd_type(ctx, args)
    "EXISTS" => cmd_exists(ctx, args)
    "DEL" => cmd_del(ctx, args)
    "EXPIRE" => cmd_expire(ctx, args, 1000L)
    "PEXPIRE" => cmd_expire(ctx, args, 1L)
    "TTL" => cmd_ttl(ctx, args, 1000L)
    "PTTL" => cmd_ttl(ctx, args, 1L)
    "PERSIST" => cmd_persist(ctx, args)
    "GET" => cmd_get(ctx, args)
    "GETRANGE" => cmd_getrange(ctx, args)
    "SET" => cmd_set(ctx, args)
    "SETRANGE" => cmd_setrange(ctx, args)
    "SETNX" => cmd_setnx(ctx, args)
    "GETDEL" => cmd_getdel(ctx, args)
    "MGET" => cmd_mget(ctx, args)
    "MSET" => cmd_mset(ctx, args)
    "MSETNX" => cmd_msetnx(ctx, args)
    "APPEND" => cmd_append(ctx, args)
    "STRLEN" => cmd_strlen(ctx, args)
    "INCR" => cmd_incr(ctx, args, 1L)
    "DECR" => cmd_incr(ctx, args, -1L)
    "INCRBY" => cmd_incrby(ctx, args)
    "DECRBY" => cmd_decrby(ctx, args)
    "HSET" => cmd_hset(ctx, args)
    "HMSET" => cmd_hmset(ctx, args)
    "HSETNX" => cmd_hsetnx(ctx, args)
    "HGET" => cmd_hget(ctx, args)
    "HGETALL" => cmd_hgetall(ctx, args)
    "HDEL" => cmd_hdel(ctx, args)
    "HEXISTS" => cmd_hexists(ctx, args)
    "HLEN" => cmd_hlen(ctx, args)
    "HSTRLEN" => cmd_hstrlen(ctx, args)
    "HKEYS" => cmd_hkeys(ctx, args)
    "HVALS" => cmd_hvals(ctx, args)
    "LPUSH" => cmd_lpush(ctx, args, true)
    "RPUSH" => cmd_lpush(ctx, args, false)
    "LPOP" => cmd_lpop(ctx, args, true)
    "RPOP" => cmd_lpop(ctx, args, false)
    "LLEN" => cmd_llen(ctx, args)
    "LRANGE" => cmd_lrange(ctx, args)
    "LINDEX" => cmd_lindex(ctx, args)
    "LSET" => cmd_lset(ctx, args)
    "LTRIM" => cmd_ltrim(ctx, args)
    "SADD" => cmd_sadd(ctx, args)
    "SREM" => cmd_srem(ctx, args)
    "SMEMBERS" => cmd_smembers(ctx, args)
    "SISMEMBER" => cmd_sismember(ctx, args)
    "SCARD" => cmd_scard(ctx, args)
    "SPOP" => cmd_spop(ctx, args)
    "ZADD" => cmd_zadd(ctx, args)
    "ZRANGE" => cmd_zrange(ctx, args)
    "ZSCORE" => cmd_zscore(ctx, args)
    "ZRANK" => cmd_zrank(ctx, args)
    "ZREVRANK" => cmd_zrevrank(ctx, args)
    "ZREM" => cmd_zrem(ctx, args)
    "ZCARD" => cmd_zcard(ctx, args)
    "ZINCRBY" => cmd_zincrby(ctx, args)
    "SUBSCRIBE" => cmd_subscribe(ctx, args)
    "UNSUBSCRIBE" => cmd_unsubscribe(ctx, args)
    "PUBLISH" => cmd_publish(ctx, args)
    "MULTI" => cmd_multi(ctx)
    "EXEC" => cmd_exec(ctx)
    "DISCARD" => cmd_discard(ctx)
    "CONFIG" => cmd_config(ctx, args)
    "INFO" => cmd_info(ctx, args)
    "CLIENT" => cmd_client(ctx, args)
    "SAVE" => @resp.SimpleString("OK")
    "AUTH" => @resp.SimpleString("OK")
    "SHUTDOWN" => {
      ctx.shutdown = true
      @resp.SimpleString("OK")
    }
    _ => unknown_command(name)
  }
}

///|
fn err(msg : String) -> @resp.Value {
  @resp.Error(msg)
}

///|
fn wrong_arity(name : String) -> @resp.Value {
  err("ERR wrong number of arguments for '\{name}' command")
}

///|
fn unknown_command(name : String) -> @resp.Value {
  err("ERR unknown command '\{name}'")
}

///|
fn wrong_type() -> @resp.Value {
  err("WRONGTYPE Operation against a key holding the wrong kind of value")
}

///|
fn not_integer() -> @resp.Value {
  err("ERR value is not an integer or out of range")
}

///|
fn not_float() -> @resp.Value {
  err("ERR value is not a valid float")
}

///|
fn syntax_error() -> @resp.Value {
  err("ERR syntax error")
}

///|
fn arg(args : Array[Bytes], i : Int) -> Bytes? {
  if i < args.length() {
    Some(args[i])
  } else {
    None
  }
}

///|
fn arg_str(args : Array[Bytes], i : Int) -> String {
  @utf8.decode_lossy(args[i])
}

///|
fn cmd_ping(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  match arg(args, 1) {
    None => @resp.SimpleString("PONG")
    Some(b) => @resp.BulkString(b)
  }
}

///|
fn cmd_echo(args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("echo")
  }
  @resp.BulkString(args[1])
}

///|
fn cmd_hello(args : Array[Bytes]) -> @resp.Value {
  let fields : Array[@resp.Value] = [
    @resp.BulkString(@utf8.encode("server")),
    @resp.BulkString(@utf8.encode("moonredis")),
    @resp.BulkString(@utf8.encode("version")),
    @resp.BulkString(@utf8.encode("0.1.0")),
    @resp.BulkString(@utf8.encode("proto")),
    @resp.Integer(2L),
    @resp.BulkString(@utf8.encode("id")),
    @resp.Integer(0L),
    @resp.BulkString(@utf8.encode("mode")),
    @resp.BulkString(@utf8.encode("standalone")),
    @resp.BulkString(@utf8.encode("role")),
    @resp.BulkString(@utf8.encode("master")),
    @resp.BulkString(@utf8.encode("modules")),
    @resp.Array([]),
  ]
  @resp.Array(fields)
}

///|
fn cmd_command(args : Array[Bytes]) -> @resp.Value {
  let names = [
    "PING", "ECHO", "HELLO", "COMMAND", "QUIT", "SELECT", "DBSIZE", "FLUSHDB", "FLUSHALL",
    "KEYS", "TYPE", "EXISTS", "DEL", "EXPIRE", "PEXPIRE", "TTL", "PTTL", "PERSIST",
    "GET", "GETRANGE", "SET", "SETRANGE", "SETNX", "GETDEL", "MGET", "MSET", "MSETNX",
    "APPEND", "STRLEN", "INCR", "DECR", "INCRBY", "DECRBY", "HSET", "HMSET", "HSETNX",
    "HGET", "HGETALL", "HDEL", "HEXISTS", "HLEN", "HSTRLEN", "HKEYS", "HVALS", "LPUSH",
    "RPUSH", "LPOP", "RPOP", "LLEN", "LRANGE", "LINDEX", "LSET", "LTRIM", "SADD",
    "SREM", "SMEMBERS", "SISMEMBER", "SCARD", "SPOP", "ZADD", "ZRANGE", "ZSCORE",
    "ZRANK", "ZREVRANK", "ZREM", "ZCARD", "ZINCRBY", "SUBSCRIBE", "UNSUBSCRIBE",
    "PUBLISH", "MULTI", "EXEC", "DISCARD", "CONFIG", "INFO", "CLIENT", "SAVE", "AUTH",
    "SHUTDOWN",
  ]
  let items : Array[@resp.Value] = []
  for n in names {
    items.push(@resp.BulkString(@utf8.encode(n)))
  }
  @resp.Array(items)
}

///|
fn cmd_select(args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("select")
  }
  match @store.parse_integer_bytes(args[1]) {
    Some(_) => @resp.SimpleString("OK")
    None => err("ERR invalid DB index")
  }
}

///|
fn cmd_keys(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("keys")
  }
  let pattern = args[1]
  let out : Array[@resp.Value] = []
  for key in ctx.store.keys() {
    if glob_match(pattern, @utf8.encode(key)) {
      out.push(@resp.BulkString(@utf8.encode(key)))
    }
  }
  @resp.Array(out)
}

///|
fn cmd_type(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("type")
  }
  let t = ctx.store.type_of(arg_str(args, 1))
  @resp.SimpleString(t.or("none"))
}

///|
fn cmd_exists(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 2 {
    return wrong_arity("exists")
  }
  let mut n = 0
  for i = 1; i < args.length(); i = i + 1 {
    if ctx.store.exists(arg_str(args, i)) {
      n = n + 1
    }
  }
  @resp.Integer(n.to_int64())
}

///|
fn cmd_del(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 2 {
    return wrong_arity("del")
  }
  let mut n = 0
  for i = 1; i < args.length(); i = i + 1 {
    if ctx.store.del(arg_str(args, i)) {
      n = n + 1
    }
  }
  @resp.Integer(n.to_int64())
}

///|
fn cmd_expire(ctx : Ctx, args : Array[Bytes], factor : Int64) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("expire")
  }
  match @store.parse_integer_bytes(args[2]) {
    None => not_integer()
    Some(v) =>
      @resp.Integer(
        if ctx.store.expire(arg_str(args, 1), v * factor) {
          1L
        } else {
          0L
        },
      )
  }
}

///|
fn cmd_ttl(ctx : Ctx, args : Array[Bytes], factor : Int64) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("ttl")
  }
  match ctx.store.ttl_ms(arg_str(args, 1)) {
    None => @resp.Integer(-2L)
    Some(v) => @resp.Integer(if v < 0L { -1L } else { v / factor })
  }
}

///|
fn cmd_persist(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("persist")
  }
  @resp.Integer(if ctx.store.persist(arg_str(args, 1)) { 1L } else { 0L })
}

///|
fn cmd_get(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("get")
  }
  let key = arg_str(args, 1)
  match ctx.store.get(key) {
    None => @resp.NullBulk
    Some(@store.Str(b)) => @resp.BulkString(b)
    Some(_) => wrong_type()
  }
}

///|
fn cmd_getrange(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 4 {
    return wrong_arity("getrange")
  }
  let start = @store.parse_integer_bytes(args[2])
  let stop = @store.parse_integer_bytes(args[3])
  match (start, stop) {
    (Some(s), Some(e)) =>
      @resp.BulkString(
        ctx.store.getrange(arg_str(args, 1), s.to_int(), e.to_int()),
      )
    _ => not_integer()
  }
}

///|
fn cmd_set(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 3 {
    return wrong_arity("set")
  }
  let key = arg_str(args, 1)
  let value = args[2]
  let mut nx = false
  let mut xx = false
  let mut ttl : Int64? = None
  let mut i = 3
  while i < args.length() {
    let opt = upper(arg_str(args, i))
    if opt == "NX" {
      nx = true
      i = i + 1
    } else if opt == "XX" {
      xx = true
      i = i + 1
    } else if opt == "EX" || opt == "PX" {
      if i + 1 >= args.length() {
        return syntax_error()
      }
      match @store.parse_integer_bytes(args[i + 1]) {
        None => return not_integer()
        Some(v) => {
          ttl = Some(if opt == "EX" { v * 1000L } else { v })
          i = i + 2
        }
      }
    } else {
      return syntax_error()
    }
  }
  let exists = ctx.store.exists(key)
  if nx && exists {
    return @resp.NullBulk
  }
  if xx && !exists {
    return @resp.NullBulk
  }
  ctx.store.set_string(key, value)
  match ttl {
    None => ()
    Some(ms) => {
      let _ = ctx.store.expire(key, ms)
    }
  }
  @resp.SimpleString("OK")
}

///|
fn cmd_setrange(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 4 {
    return wrong_arity("setrange")
  }
  match @store.parse_integer_bytes(args[2]) {
    None => not_integer()
    Some(offset) => {
      if offset < 0L {
        return err("ERR offset is out of range")
      }
      match ctx.store.setrange(arg_str(args, 1), offset.to_int(), args[3]) {
        None => wrong_type()
        Some(n) => @resp.Integer(n.to_int64())
      }
    }
  }
}

///|
fn cmd_setnx(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("setnx")
  }
  let key = arg_str(args, 1)
  if ctx.store.exists(key) {
    return @resp.Integer(0L)
  }
  ctx.store.set_string(key, args[2])
  @resp.Integer(1L)
}

///|
fn cmd_getdel(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("getdel")
  }
  let key = arg_str(args, 1)
  match ctx.store.type_of(key) {
    None => @resp.NullBulk
    Some(t) => {
      if t != "string" {
        return wrong_type()
      }
      let value = ctx.store.get_string(key)
      let _ = ctx.store.del(key)
      match value {
        None => @resp.NullBulk
        Some(b) => @resp.BulkString(b)
      }
    }
  }
}

///|
fn cmd_mget(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 2 {
    return wrong_arity("mget")
  }
  let out : Array[@resp.Value] = []
  for i = 1; i < args.length(); i = i + 1 {
    match ctx.store.get_string(arg_str(args, i)) {
      None => out.push(@resp.NullBulk)
      Some(b) => out.push(@resp.BulkString(b))
    }
  }
  @resp.Array(out)
}

///|
fn cmd_mset(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 3 || args.length() % 2 == 0 {
    return wrong_arity("mset")
  }
  let mut i = 1
  while i + 1 < args.length() {
    ctx.store.set_string(arg_str(args, i), args[i + 1])
    i = i + 2
  }
  @resp.SimpleString("OK")
}

///|
fn cmd_msetnx(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 3 || args.length() % 2 == 0 {
    return wrong_arity("msetnx")
  }
  let pairs : Array[(String, Bytes)] = []
  let mut i = 1
  while i + 1 < args.length() {
    pairs.push((arg_str(args, i), args[i + 1]))
    i = i + 2
  }
  @resp.Integer(if ctx.store.msetnx(pairs) { 1L } else { 0L })
}

///|
fn cmd_append(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("append")
  }
  match ctx.store.append_string(arg_str(args, 1), args[2]) {
    None => wrong_type()
    Some(n) => @resp.Integer(n.to_int64())
  }
}

///|
fn cmd_strlen(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("strlen")
  }
  match ctx.store.get_string(arg_str(args, 1)) {
    None => @resp.Integer(0L)
    Some(b) => @resp.Integer(b.length().to_int64())
  }
}

///|
fn cmd_incr(ctx : Ctx, args : Array[Bytes], delta : Int64) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("incr")
  }
  incr_by(ctx, arg_str(args, 1), delta)
}

///|
fn cmd_incrby(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("incrby")
  }
  match @store.parse_integer_bytes(args[2]) {
    None => not_integer()
    Some(delta) => incr_by(ctx, arg_str(args, 1), delta)
  }
}

///|
fn cmd_decrby(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("decrby")
  }
  match @store.parse_integer_bytes(args[2]) {
    None => not_integer()
    Some(delta) => incr_by(ctx, arg_str(args, 1), -delta)
  }
}

///|
fn incr_by(ctx : Ctx, key : String, delta : Int64) -> @resp.Value {
  let current = match ctx.store.get_string(key) {
    None => 0L
    Some(b) =>
      match @store.parse_integer_bytes(b) {
        None => return not_integer()
        Some(v) => v
      }
  }
  let next = current + delta
  ctx.store.set_string(key, @utf8.encode(next.to_string()))
  @resp.Integer(next)
}

///|
fn cmd_hset(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 4 || args.length() % 2 == 1 {
    return wrong_arity("hset")
  }
  let mut added = 0
  let mut i = 2
  while i + 1 < args.length() {
    match ctx.store.hset(arg_str(args, 1), arg_str(args, i), args[i + 1]) {
      None => return wrong_type()
      Some(n) => added = added + n
    }
    i = i + 2
  }
  @resp.Integer(added.to_int64())
}

///|
fn cmd_hmset(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  let r = cmd_hset(ctx, args)
  match r {
    @resp.Integer(_) => @resp.SimpleString("OK")
    _ => r
  }
}

///|
fn cmd_hsetnx(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 4 {
    return wrong_arity("hsetnx")
  }
  match ctx.store.hsetnx(arg_str(args, 1), arg_str(args, 2), args[3]) {
    None => wrong_type()
    Some(n) => @resp.Integer(n.to_int64())
  }
}

///|
fn cmd_hget(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("hget")
  }
  match ctx.store.hget(arg_str(args, 1), arg_str(args, 2)) {
    None => @resp.NullBulk
    Some(b) => @resp.BulkString(b)
  }
}

///|
fn cmd_hgetall(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("hgetall")
  }
  match ctx.store.hgetall(arg_str(args, 1)) {
    None => @resp.Array([])
    Some(pairs) => {
      let out : Array[@resp.Value] = []
      for pair in pairs {
        let (f, v) = pair
        out.push(@resp.BulkString(@utf8.encode(f)))
        out.push(@resp.BulkString(v))
      }
      @resp.Array(out)
    }
  }
}

///|
fn cmd_hdel(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 3 {
    return wrong_arity("hdel")
  }
  let fields : Array[String] = []
  for i = 2; i < args.length(); i = i + 1 {
    fields.push(arg_str(args, i))
  }
  @resp.Integer(ctx.store.hdel(arg_str(args, 1), fields).to_int64())
}

///|
fn cmd_hexists(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("hexists")
  }
  @resp.Integer(
    if ctx.store.hexists(arg_str(args, 1), arg_str(args, 2)) {
      1L
    } else {
      0L
    },
  )
}

///|
fn cmd_hlen(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("hlen")
  }
  match ctx.store.hlen(arg_str(args, 1)) {
    None => @resp.Integer(0L)
    Some(n) => @resp.Integer(n.to_int64())
  }
}

///|
fn cmd_hstrlen(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("hstrlen")
  }
  match ctx.store.hget(arg_str(args, 1), arg_str(args, 2)) {
    None => @resp.Integer(0L)
    Some(b) => @resp.Integer(b.length().to_int64())
  }
}

///|
fn cmd_hkeys(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("hkeys")
  }
  match ctx.store.hgetall(arg_str(args, 1)) {
    None => @resp.Array([])
    Some(pairs) => {
      let out : Array[@resp.Value] = []
      for pair in pairs {
        let (f, _) = pair
        out.push(@resp.BulkString(@utf8.encode(f)))
      }
      @resp.Array(out)
    }
  }
}

///|
fn cmd_hvals(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("hvals")
  }
  match ctx.store.hgetall(arg_str(args, 1)) {
    None => @resp.Array([])
    Some(pairs) => {
      let out : Array[@resp.Value] = []
      for pair in pairs {
        let (_, v) = pair
        out.push(@resp.BulkString(v))
      }
      @resp.Array(out)
    }
  }
}

///|
fn cmd_lpush(ctx : Ctx, args : Array[Bytes], left : Bool) -> @resp.Value {
  if args.length() < 3 {
    return wrong_arity(if left { "lpush" } else { "rpush" })
  }
  let values : Array[Bytes] = []
  for i = 2; i < args.length(); i = i + 1 {
    values.push(args[i])
  }
  let r = if left {
    ctx.store.lpush(arg_str(args, 1), values)
  } else {
    ctx.store.rpush(arg_str(args, 1), values)
  }
  match r {
    None => wrong_type()
    Some(n) => @resp.Integer(n.to_int64())
  }
}

///|
fn cmd_lpop(ctx : Ctx, args : Array[Bytes], left : Bool) -> @resp.Value {
  if args.length() < 2 || args.length() > 3 {
    return wrong_arity(if left { "lpop" } else { "rpop" })
  }
  let key = arg_str(args, 1)
  match arg(args, 2) {
    None => {
      let v = if left { ctx.store.lpop(key) } else { ctx.store.rpop(key) }
      match v {
        None => @resp.NullBulk
        Some(b) => @resp.BulkString(b)
      }
    }
    Some(count_b) =>
      match @store.parse_integer_bytes(count_b) {
        None => not_integer()
        Some(n) => {
          let out : Array[@resp.Value] = []
          let mut i = 0L
          while i < n {
            let v = if left { ctx.store.lpop(key) } else { ctx.store.rpop(key) }
            match v {
              None => break
              Some(b) => out.push(@resp.BulkString(b))
            }
            i = i + 1L
          }
          @resp.Array(out)
        }
      }
  }
}

///|
fn cmd_llen(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("llen")
  }
  match ctx.store.llen(arg_str(args, 1)) {
    None => @resp.Integer(0L)
    Some(n) => @resp.Integer(n.to_int64())
  }
}

///|
fn cmd_lrange(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 4 {
    return wrong_arity("lrange")
  }
  match ctx.store.llen(arg_str(args, 1)) {
    None => @resp.Array([])
    Some(_) => {
      // Rebuild via repeated lindex is O(n^2); acceptable for a lightweight server.
      let key = arg_str(args, 1)
      let start = @store.parse_integer_bytes(args[2])
      let stop = @store.parse_integer_bytes(args[3])
      match (start, stop) {
        (Some(s), Some(e)) => {
          let len = ctx.store.llen(key).or(0)
          let from = normalize_index(s.to_int(), len)
          let to = normalize_index(e.to_int(), len)
          let out : Array[@resp.Value] = []
          if from <= to {
            let mut i = from
            while i <= to {
              out.push(lindex(ctx, key, i))
              i = i + 1
            }
          }
          @resp.Array(out)
        }
        _ => not_integer()
      }
    }
  }
}

///|
fn lindex(ctx : Ctx, key : String, index : Int) -> @resp.Value {
  match ctx.store.get(key) {
    Some(@store.List(a)) => {
      let i = normalize_index(index, a.length())
      if i < 0 || i >= a.length() {
        return @resp.NullBulk
      }
      @resp.BulkString(a[i])
    }
    _ => @resp.NullBulk
  }
}

///|
fn cmd_lindex(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("lindex")
  }
  match @store.parse_integer_bytes(args[2]) {
    None => not_integer()
    Some(i) => lindex(ctx, arg_str(args, 1), i.to_int())
  }
}

///|
fn cmd_lset(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 4 {
    return wrong_arity("lset")
  }
  match @store.parse_integer_bytes(args[2]) {
    None => not_integer()
    Some(i) => {
      let key = arg_str(args, 1)
      match ctx.store.get(key) {
        Some(@store.List(a)) => {
          let idx = normalize_index(i.to_int(), a.length())
          if idx < 0 || idx >= a.length() {
            return err("ERR index out of range")
          }
          a[idx] = args[3]
          @resp.SimpleString("OK")
        }
        _ => wrong_type()
      }
    }
  }
}

///|
fn cmd_ltrim(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 4 {
    return wrong_arity("ltrim")
  }
  let start = @store.parse_integer_bytes(args[2])
  let stop = @store.parse_integer_bytes(args[3])
  match (start, stop) {
    (Some(s), Some(e)) => {
      let _ = ctx.store.ltrim(arg_str(args, 1), s.to_int(), e.to_int())
      @resp.SimpleString("OK")
    }
    _ => not_integer()
  }
}

///|
fn cmd_sadd(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 3 {
    return wrong_arity("sadd")
  }
  let members : Array[String] = []
  for i = 2; i < args.length(); i = i + 1 {
    members.push(arg_str(args, i))
  }
  match ctx.store.sadd(arg_str(args, 1), members) {
    None => wrong_type()
    Some(n) => @resp.Integer(n.to_int64())
  }
}

///|
fn cmd_srem(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 3 {
    return wrong_arity("srem")
  }
  let members : Array[String] = []
  for i = 2; i < args.length(); i = i + 1 {
    members.push(arg_str(args, i))
  }
  @resp.Integer(ctx.store.srem(arg_str(args, 1), members).to_int64())
}

///|
fn cmd_smembers(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("smembers")
  }
  match ctx.store.smembers(arg_str(args, 1)) {
    None => @resp.Array([])
    Some(list) => {
      let out : Array[@resp.Value] = []
      for m in list {
        out.push(@resp.BulkString(@utf8.encode(m)))
      }
      @resp.Array(out)
    }
  }
}

///|
fn cmd_sismember(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("sismember")
  }
  @resp.Integer(
    if ctx.store.sismember(arg_str(args, 1), arg_str(args, 2)) {
      1L
    } else {
      0L
    },
  )
}

///|
fn cmd_scard(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("scard")
  }
  match ctx.store.scard(arg_str(args, 1)) {
    None => @resp.Integer(0L)
    Some(n) => @resp.Integer(n.to_int64())
  }
}

///|
fn cmd_spop(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 2 || args.length() > 3 {
    return wrong_arity("spop")
  }
  let key = arg_str(args, 1)
  match ctx.store.smembers(key) {
    None => @resp.NullBulk
    Some(list) => {
      if list.is_empty() {
        return @resp.NullBulk
      }
      let m = list[0]
      let _ = ctx.store.srem(key, [m])
      @resp.BulkString(@utf8.encode(m))
    }
  }
}

///|
fn cmd_zadd(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 4 || args.length() % 2 == 1 {
    return wrong_arity("zadd")
  }
  let pairs : Array[(String, Double)] = []
  let mut i = 2
  while i + 1 < args.length() {
    match @resp.parse_double_bytes(args[i]) {
      None => return not_float()
      Some(score) => pairs.push((arg_str(args, i + 1), score))
    }
    i = i + 2
  }
  match ctx.store.zadd(arg_str(args, 1), pairs) {
    None => wrong_type()
    Some(n) => @resp.Integer(n.to_int64())
  }
}

///|
fn cmd_zrange(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 4 && args.length() != 5 {
    return wrong_arity("zrange")
  }
  let mut with_scores = false
  if args.length() == 5 {
    let opt = upper(arg_str(args, 4))
    if opt == "WITHSCORES" {
      with_scores = true
    } else {
      return syntax_error()
    }
  }
  match
    (@store.parse_integer_bytes(args[2]), @store.parse_integer_bytes(args[3])) {
    (Some(start), Some(stop)) =>
      match
        ctx.store.zrange(
          arg_str(args, 1),
          start.to_int(),
          stop.to_int(),
          with_scores~,
        ) {
        None => @resp.Array([])
        Some(pairs) => {
          let out : Array[@resp.Value] = []
          for pair in pairs {
            let (m, score) = pair
            out.push(@resp.BulkString(@utf8.encode(m)))
            if with_scores {
              out.push(@resp.Double(score))
            }
          }
          @resp.Array(out)
        }
      }
    _ => not_integer()
  }
}

///|
fn cmd_zscore(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("zscore")
  }
  match ctx.store.zscore(arg_str(args, 1), arg_str(args, 2)) {
    None => @resp.NullBulk
    Some(s) => @resp.BulkString(@utf8.encode(format_double(s)))
  }
}

///|
fn cmd_zrank(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("zrank")
  }
  match ctx.store.zrank(arg_str(args, 1), arg_str(args, 2)) {
    None => @resp.NullBulk
    Some(r) => @resp.Integer(r.to_int64())
  }
}

///|
fn cmd_zrevrank(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("zrevrank")
  }
  match ctx.store.zrevrank(arg_str(args, 1), arg_str(args, 2)) {
    None => @resp.NullBulk
    Some(r) => @resp.Integer(r.to_int64())
  }
}

///|
fn cmd_zrem(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 3 {
    return wrong_arity("zrem")
  }
  let members : Array[String] = []
  for i = 2; i < args.length(); i = i + 1 {
    members.push(arg_str(args, i))
  }
  @resp.Integer(ctx.store.zrem(arg_str(args, 1), members).to_int64())
}

///|
fn cmd_zcard(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 2 {
    return wrong_arity("zcard")
  }
  match ctx.store.zcard(arg_str(args, 1)) {
    None => @resp.Integer(0L)
    Some(n) => @resp.Integer(n.to_int64())
  }
}

///|
fn cmd_zincrby(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 4 {
    return wrong_arity("zincrby")
  }
  match @resp.parse_double_bytes(args[2]) {
    None => not_float()
    Some(incr) => {
      let key = arg_str(args, 1)
      let m = arg_str(args, 3)
      let current = ctx.store.zscore(key, m).or(0.0)
      let next = current + incr
      match ctx.store.zadd(key, [(m, next)]) {
        None => wrong_type()
        Some(_) => @resp.BulkString(@utf8.encode(format_double(next)))
      }
    }
  }
}

///|
fn cmd_subscribe(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 2 {
    return wrong_arity("subscribe")
  }
  let out : Array[@resp.Value] = []
  for i = 1; i < args.length(); i = i + 1 {
    let channel = arg_str(args, i)
    ctx.hub.subscribe(channel, ctx.client_id)
    ctx.subscribed.push(channel)
    ctx.in_subscribe_mode = true
    out.push(
      @resp.Push([
        @resp.BulkString(@utf8.encode("subscribe")),
        @resp.BulkString(@utf8.encode(channel)),
        @resp.Integer(ctx.subscribed.length().to_int64()),
      ]),
    )
  }
  @resp.Array(out)
}

///|
fn cmd_unsubscribe(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  let channels = if args.length() == 1 {
    let copy = ctx.subscribed
    ctx.subscribed = []
    ctx.in_subscribe_mode = false
    copy
  } else {
    let list : Array[String] = []
    for i = 1; i < args.length(); i = i + 1 {
      list.push(arg_str(args, i))
    }
    for ch in list {
      ctx.hub.unsubscribe(ch, ctx.client_id)
      let kept : Array[String] = []
      for s in ctx.subscribed {
        if s != ch {
          kept.push(s)
        }
      }
      ctx.subscribed = kept
    }
    ctx.in_subscribe_mode = !ctx.subscribed.is_empty()
    list
  }
  let out : Array[@resp.Value] = []
  for channel in channels {
    out.push(
      @resp.Push([
        @resp.BulkString(@utf8.encode("unsubscribe")),
        @resp.BulkString(@utf8.encode(channel)),
        @resp.Integer(ctx.subscribed.length().to_int64()),
      ]),
    )
  }
  @resp.Array(out)
}

///|
fn cmd_publish(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() != 3 {
    return wrong_arity("publish")
  }
  let channel = arg_str(args, 1)
  let receivers = ctx.hub.publish(channel)
  @resp.Integer(receivers.length().to_int64())
}

///|
fn cmd_multi(ctx : Ctx) -> @resp.Value {
  if ctx.in_multi {
    return err("ERR MULTI calls can not be nested")
  }
  ctx.in_multi = true
  ctx.queue = []
  @resp.SimpleString("OK")
}

///|
fn cmd_exec(ctx : Ctx) -> @resp.Value {
  if !ctx.in_multi {
    return err("ERR EXEC without MULTI")
  }
  ctx.in_multi = false
  let queued = ctx.queue
  ctx.queue = []
  let out : Array[@resp.Value] = []
  for cmd in queued {
    out.push(execute(ctx, cmd))
  }
  @resp.Array(out)
}

///|
fn cmd_discard(ctx : Ctx) -> @resp.Value {
  if !ctx.in_multi {
    return err("ERR DISCARD without MULTI")
  }
  ctx.in_multi = false
  ctx.queue = []
  @resp.SimpleString("OK")
}

///|
fn cmd_config(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 2 {
    return wrong_arity("config")
  }
  let sub = upper(arg_str(args, 1))
  if sub == "GET" {
    if args.length() != 3 {
      return wrong_arity("config|get")
    }
    let param = arg_str(args, 2)
    let value = ctx.config_get(param).or("")
    return @resp.Array([
      @resp.BulkString(@utf8.encode(param)),
      @resp.BulkString(@utf8.encode(value)),
    ])
  }
  if sub == "SET" {
    if args.length() != 4 {
      return wrong_arity("config|set")
    }
    ctx.config_set(arg_str(args, 2), arg_str(args, 3))
    return @resp.SimpleString("OK")
  }
  err("ERR Unknown CONFIG subcommand or wrong number of arguments")
}

///|
fn cmd_info(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  let b = Buffer()
  b.write_string_utf8("# Server\r\n")
  b.write_string_utf8("redis_version:7.0.0-moonredis\r\n")
  b.write_string_utf8("moonredis_version:0.1.0\r\n")
  b.write_string_utf8("redis_mode:standalone\r\n")
  b.write_string_utf8("# Clients\r\n")
  b.write_string_utf8("connected_clients:1\r\n")
  b.write_string_utf8("# Keyspace\r\n")
  b.write_string_utf8("db0:keys=\{ctx.store.size()},expires=0,avg_ttl=0\r\n")
  @resp.BulkString(b.to_bytes())
}

///|
fn cmd_client(ctx : Ctx, args : Array[Bytes]) -> @resp.Value {
  if args.length() < 2 {
    return wrong_arity("client")
  }
  let sub = upper(arg_str(args, 1))
  if sub == "ID" {
    return @resp.Integer(ctx.client_id.to_int64())
  }
  if sub == "SETNAME" {
    return @resp.SimpleString("OK")
  }
  if sub == "GETNAME" {
    return @resp.BulkString(@utf8.encode(""))
  }
  if sub == "LIST" {
    return @resp.BulkString(
      @utf8.encode("id=\{ctx.client_id} addr=127.0.0.1:0 name= moonredis\r\n"),
    )
  }
  err("ERR Unknown CLIENT subcommand or wrong number of arguments")
}

///|
fn normalize_index(i : Int, len : Int) -> Int {
  if len == 0 {
    return -1
  }
  if i < 0 {
    let v = len + i
    if v < 0 {
      0
    } else {
      v
    }
  } else if i >= len {
    len - 1
  } else {
    i
  }
}

///|
fn format_double(v : Double) -> String {
  let s = v.to_string()
  if s.ends_with(".0") {
    s.substring(start=0, end=s.length() - 2)
  } else {
    s
  }
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

///|
/// Simple glob matcher supporting `*` and `?` (ASCII).
fn glob_match(pattern : Bytes, text : Bytes) -> Bool {
  glob_at(pattern, text, 0, 0)
}

///|
fn glob_at(p : Bytes, t : Bytes, pi : Int, ti : Int) -> Bool {
  if pi >= p.length() {
    return ti >= t.length()
  }
  let pc = p[pi]
  if pc == b'*' {
    // Collapse consecutive stars.
    let mut np = pi
    while np < p.length() && p[np] == b'*' {
      np = np + 1
    }
    if np >= p.length() {
      return true
    }
    let mut nt = ti
    while nt <= t.length() {
      if glob_at(p, t, np, nt) {
        return true
      }
      nt = nt + 1
    }
    return false
  }
  if ti >= t.length() {
    return false
  }
  if pc == b'?' || pc == t[ti] {
    return glob_at(p, t, pi + 1, ti + 1)
  }
  false
}
