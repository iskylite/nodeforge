# CLI HTTP 诊断与响应缓冲设计

## 1. 目标

NodeForge CLI 的 management client 只连接本机 daemon。过去各命令分别声明
8 KiB～256 KiB 的栈响应数组，并把连接失败、HTTP 非 2xx、响应过大和 JSON
解码失败压缩成 `null` 或两个布尔值。结果是同类接口因命令不同而具有不同容量，
同时 `--debug` 无法解释失败发生在哪一层。

本设计建立以下长期约束：

1. 常规 management JSON 响应使用统一、有界的堆缓冲；
2. 已知大型资源可使用独立上限，但必须在代码旁用中文说明数据规模依据；
3. `--debug` 必须覆盖请求、连接、HTTP 响应、容量和 JSON 解码边界；
4. 普通输出保持稳定，诊断只写 stderr，不污染 JSON/JSONL stdout；
5. 诊断默认不得泄漏 token、认证 header 或完整业务正文。

## 2. 响应容量

常规 CLI 查询使用 `managementResponseCapacity = 2 MiB`，由命令 allocator 在堆上
分配并在 handler 返回前释放。这个上限覆盖节点、Profile、DHCP、TFTP、会话和常规
catalog 集合，消除了旧实现按命令散落的 8/16/64/128/256 KiB 上限。

软件能力索引属于明确的大对象：Rocky DVD package 索引可超过 1 MiB，因此保留
8 MiB 专用上限。后续若新增大型响应，禁止直接增加栈数组；应说明数据规模、使用
调用方 allocator、提供可操作错误，并补充超过旧上限的回归测试。

`doctor` 仅验证端点是否可用，三个查询顺序复用一块 2 MiB 缓冲，不同时保留正文。

## 3. 诊断通道

`management_client.configureDiagnostics` 为当前 CLI 线程设置 stderr writer。
`loadConfig` 是 daemon 命令共享的配置入口，负责根据 `--debug` 启用或清空该通道。
诊断状态为 threadlocal，避免测试和未来并发调用互相串线。

```text
debug: http request method=GET path=/api/v1/management/nodes address=127.0.0.1:18080
debug: http response method=GET path=/api/v1/management/nodes status=200 bytes=1234
debug: http connect_failed address=127.0.0.1:18080 cause=ConnectionRefused
debug: http response_too_large content_length=3145728 capacity=2097152
debug: http json_decode_failed type=NodeListPage cause=UnexpectedToken ...
```

普通模式不产生上述记录。

## 4. 安全边界

默认诊断可以输出 method、path、端口、status、长度、错误枚举和 request ID，但：

- 不输出请求正文；
- 不输出 `Authorization`、cookie、幂等键及其他认证类 header；
- 成功响应不输出正文；
- 非 2xx 错误正文和 JSON 解码失败输入最多预览 1024 字节；
- 预览使用 JSON 字符串转义，控制字符不能制造伪造日志行。

如果未来需要完整 wire trace，应增加独立且更明确的高风险选项，不能扩大
`--debug` 的默认数据暴露范围。

## 5. 后续开发约束

新增 CLI HTTP 功能必须遵循：

1. 不以 `null` 同时表示参数错误、连接失败和 HTTP 拒绝；
2. 新代码优先保留 HTTP status、daemon 错误信封和底层 Zig error；
3. JSON 解码失败通过统一诊断入口报告类型、错误和受限预览；
4. 大于小型协议 scratch buffer 的数组不得无说明地放在栈上；
5. 关键所有权、容量和安全决策使用中文注释；
6. 设计行为变化同步更新本文件及相关 CLI 文档。

现有 `!?[]const u8` 包装函数仍保留兼容性，但新增 API 不应继续扩散这种把非 2xx
压缩为 `null` 的模型。后续演进方向是返回包含 status/body/location 的结构化响应，
由 CLI 映射稳定用户错误，并由诊断层补充底层上下文。
