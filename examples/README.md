# 示例

## quickstart.py

不依赖第三方 Redis 客户端，直接用 TCP + RESP 与 moonredis 通信：

```bash
# 终端 1：启动服务器
moon run cmd/server --target native -- --port 6399

# 终端 2：运行示例
python examples/quickstart.py
```

示例会依次执行 PING、SET/GET、List、Hash、Sorted Set、INCR、KEYS，并打印回复。

## redis-cli

如果本机装有 `redis-cli`，也可以直接连接：

```bash
redis-cli -p 6399 SET hello world
redis-cli -p 6399 GET hello
redis-cli -p 6399 RPUSH todos write-paper submit
redis-cli -p 6399 LRANGE todos 0 -1
```

## 自带 CLI

```bash
moon run cmd/cli --target native -- --port 6399 SET name moonbit
moon run cmd/cli --target native -- --port 6399 GET name
```
