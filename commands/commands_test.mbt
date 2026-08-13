///|
fn mk_ctx() -> @commands.Ctx {
  let store = @store.Store::new()
  let hub = @commands.Hub::new()
  @commands.Ctx::new(store, hub, 1)
}

///|
test "set and get through execute" {
  let ctx = mk_ctx()
  let r1 = @commands.execute(ctx, [
    @utf8.encode("SET"),
    @utf8.encode("k"),
    @utf8.encode("v"),
  ])
  match r1 {
    @resp.SimpleString(s) => assert_eq(s, "OK")
    _ => fail("expected OK")
  }
  let r2 = @commands.execute(ctx, [@utf8.encode("GET"), @utf8.encode("k")])
  match r2 {
    @resp.BulkString(b) => assert_eq(@utf8.decode_lossy(b), "v")
    _ => fail("expected bulk")
  }
}

///|
test "multi exec queues and runs" {
  let ctx = mk_ctx()
  let _ = @commands.execute(ctx, [@utf8.encode("MULTI")])
  let queued = @commands.execute(ctx, [
    @utf8.encode("SET"),
    @utf8.encode("a"),
    @utf8.encode("1"),
  ])
  match queued {
    @resp.SimpleString(s) => assert_eq(s, "QUEUED")
    _ => fail("expected QUEUED")
  }
  let r = @commands.execute(ctx, [@utf8.encode("EXEC")])
  match r {
    @resp.Array(items) => assert_eq(items.length(), 1)
    _ => fail("expected array")
  }
  let get = @commands.execute(ctx, [@utf8.encode("GET"), @utf8.encode("a")])
  match get {
    @resp.BulkString(b) => assert_eq(@utf8.decode_lossy(b), "1")
    _ => fail("expected bulk after exec")
  }
}

///|
test "wrong type returns WRONGTYPE" {
  let ctx = mk_ctx()
  let _ = @commands.execute(ctx, [
    @utf8.encode("LPUSH"),
    @utf8.encode("k"),
    @utf8.encode("x"),
  ])
  let r = @commands.execute(ctx, [@utf8.encode("GET"), @utf8.encode("k")])
  match r {
    @resp.Error(e) => assert_eq(e.has_prefix("WRONGTYPE"), true)
    _ => fail("expected error")
  }
}

///|
test "publish reaches subscribers" {
  let store = @store.Store::new()
  let hub = @commands.Hub::new()
  let sub = @commands.Ctx::new(store, hub, 1)
  let publisher = @commands.Ctx::new(store, hub, 2)
  let _ = @commands.execute(sub, [
    @utf8.encode("SUBSCRIBE"),
    @utf8.encode("news"),
  ])
  let n = hub.publish("news")
  assert_eq(n.length(), 1)
  let r = @commands.execute(publisher, [
    @utf8.encode("PUBLISH"),
    @utf8.encode("news"),
    @utf8.encode("hi"),
  ])
  match r {
    @resp.Integer(v) => assert_eq(v, 1L)
    _ => fail("expected integer")
  }
}
