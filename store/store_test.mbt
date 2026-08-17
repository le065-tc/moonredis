///|
test "string get set" {
  let s = @store.Store::new()
  s.set_string("k", @utf8.encode("v1"))
  assert_eq(@utf8.decode_lossy(s.get_string("k").unwrap_or(b"")), "v1")
  assert_eq(s.type_of("k").unwrap_or(""), "string")
}

///|
test "list push pop" {
  let s = @store.Store::new()
  let _ = s.rpush("l", [@utf8.encode("a"), @utf8.encode("b")])
  assert_eq(s.llen("l").unwrap_or(-1), 2)
  assert_eq(@utf8.decode_lossy(s.lpop("l").unwrap_or(b"")), "a")
  assert_eq(@utf8.decode_lossy(s.rpop("l").unwrap_or(b"")), "b")
  assert_eq(s.exists("l"), false)
}

///|
test "hash operations" {
  let s = @store.Store::new()
  let _ = s.hset("h", "f1", @utf8.encode("x"))
  let _ = s.hset("h", "f2", @utf8.encode("y"))
  assert_eq(s.hlen("h").unwrap_or(-1), 2)
  assert_eq(@utf8.decode_lossy(s.hget("h", "f1").unwrap_or(b"")), "x")
  assert_eq(s.hdel("h", ["f1"]), 1)
  assert_eq(s.hexists("h", "f2"), true)
}

///|
test "set operations" {
  let s = @store.Store::new()
  let _ = s.sadd("set", ["a", "b", "a"])
  assert_eq(s.scard("set").unwrap_or(-1), 2)
  assert_eq(s.sismember("set", "a"), true)
  assert_eq(s.srem("set", ["a"]), 1)
  assert_eq(s.sismember("set", "a"), false)
}

///|
test "sorted set range" {
  let s = @store.Store::new()
  let _ = s.zadd("z", [("a", 1.0), ("b", 2.0), ("c", 0.5)])
  let r = s.zrange("z", 0, -1)
  assert_eq(r.unwrap_or([]).length(), 3)
  assert_eq(r.unwrap_or([])[0].0, "c")
  assert_eq(r.unwrap_or([])[2].0, "b")
}

///|
test "expire with injected clock" {
  let mut t : Int64 = 0L
  let s = @store.Store::new(now=fn() { t })
  s.set_string("k", @utf8.encode("v"))
  assert_eq(s.expire("k", 100L), true)
  assert_eq(s.ttl_ms("k").unwrap_or(-2L), 100L)
  t = 101L
  assert_eq(s.exists("k"), false)
}

///|
test "parse integer bytes" {
  assert_eq(@store.parse_integer_bytes(@utf8.encode("42")), Some(42L))
  assert_eq(@store.parse_integer_bytes(@utf8.encode("-7")), Some(-7L))
  assert_eq(@store.parse_integer_bytes(@utf8.encode("abc")), None)
}
