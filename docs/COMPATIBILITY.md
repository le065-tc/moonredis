# moonredis 兼容性说明

本文档记录 moonredis 与 Redis 协议的兼容范围、设计取舍和后续路线，方便评审与使用者快速判断适用边界。

## 协议覆盖

### RESP2（完整）

| 类型 | 编码 | 支持 |
| --- | --- | --- |
| Simple String | `+...` | ✅ |
| Error | `-...` | ✅ |
| Integer | `:...` | ✅ |
| Bulk String | `$N...`（含 `$-1`） | ✅ |
| Array | `*N...`（含 `*-1`） | ✅ |

### RESP3（子集）

| 类型 | 编码 | 支持 |
| --- | --- | --- |
| Null | `_` | ✅ |
| Boolean | `#t/#f` | ✅ |
| Double | `,...` | ✅ |
| Push | `>N...`（Pub/Sub 消息） | ✅ |
| Map / Set | `%` / `~` | 解析为扁平数组（文档化简化） |

## 命令覆盖

- 连接与服务器：`PING` `ECHO` `HELLO` `COMMAND` `QUIT` `SELECT` `AUTH` `INFO` `CONFIG GET/SET` `CLIENT ID/SETNAME/GETNAME/LIST` `SAVE` `SHUTDOWN`
- 键：`DEL` `EXISTS` `KEYS` `TYPE` `EXPIRE` `PEXPIRE` `TTL` `PTTL` `PERSIST` `DBSIZE` `FLUSHDB` `FLUSHALL`
- String：`SET` `SETNX` `SETRANGE` `GET` `GETRANGE` `GETDEL` `MGET` `MSET` `MSETNX` `APPEND` `STRLEN` `INCR` `DECR` `INCRBY` `DECRBY`
- List：`LPUSH` `RPUSH` `LPOP` `RPOP` `LLEN` `LRANGE` `LINDEX` `LSET` `LTRIM`
- Hash：`HSET` `HMSET` `HSETNX` `HGET` `HGETALL` `HDEL` `HEXISTS` `HLEN` `HSTRLEN` `HKEYS` `HVALS`
- Set：`SADD` `SREM` `SMEMBERS` `SISMEMBER` `SCARD` `SPOP`
- Sorted Set：`ZADD` `ZRANGE [WITHSCORES]` `ZSCORE` `ZRANK` `ZREVRANK` `ZREM` `ZCARD` `ZINCRBY`
- 事务：`MULTI` `EXEC` `DISCARD`
- 发布订阅：`SUBSCRIBE` `UNSUBSCRIBE` `PUBLISH`

## 设计取舍

- **单线程事件循环**：面向本地开发、教学、嵌入式演示与中小规模缓存场景；没有多线程与锁竞争。
- **键为 UTF-8 字符串**，值为二进制安全字节串。
- **RESP3 Map/Set 以扁平数组返回**：保证 RESP2 客户端可用。
- **AOF 追加模式**：不包含 RDB、主从复制与集群。
- **过期策略**：访问时惰性过期 + 周期主动清扫。
- **网络层**：仓库内 C shim（Windows Winsock / POSIX socket），不依赖第三方网络库；核心协议与存储为纯 MoonBit。

## 质量保障

- 单元测试：RESP 编解码、数据结构、命令语义、事务、Pub/Sub、AOF 往返（含 Unicode 路径）。
- 端到端冒烟测试：`python scripts/smoke_test.py` 自动启动服务器并断言核心行为。
- CI：`moon build --target native` + `moon test --target native` + 冒烟测试（Ubuntu）。

## 路线图（非承诺）

- 更多命令：`SETEX`、`GETEX`、`LPOS`、`SINTER`、`ZRANGEBYSCORE`、`SCAN` 等
- RESP3 Map/Set 原生编码
- AOF 定期重写与 fsync 策略
- 基础主从/复制（演示级）
