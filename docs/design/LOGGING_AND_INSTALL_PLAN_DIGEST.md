# 日志与安装计划摘要约定

本文定义 NodeForge 当前服务日志、HTTP 错误诊断和 install plan digest 安全边界。
目标是让操作员从一条拒绝日志中直接知道“哪里失败、为什么失败、如何关联”，同时
避免把无法证明的内部不一致描述成用户配置“过时”。

## 1. 日志等级与 setup 覆盖

`nodeforge setup --log-level <level>` 支持 `debug`、`info`、`warn`、`err`。

覆盖顺序固定如下：

| 场景 | 未指定 `--log-level` | 显式指定 |
|---|---|---|
| fresh setup | 开发阶段默认 `debug` | 使用指定值 |
| reconfigure | 保留当前 config | 覆盖并持久化 |
| import-config | 保留导入值 | 覆盖导入值并持久化 |
| `nodeforged --debug` | 不适用 | 仅本次进程强制 debug，不改 config |

systemd unit 只固定日志目的地为文件；实际过滤等级由
`config.logging.level` 决定。这样交互式与非交互式 setup、导入配置及 systemd
启动读取同一个持久事实。

## 2. HTTP 错误日志契约

所有非 2xx JSON 响应至少记录：

```text
method path status error_code reason request_id client
```

响应仍包含相同 `error.code`、`error.message` 和 `request_id`，因此客户端看到的
错误可以与服务端日志一一关联。日志不得包含 Authorization、capability、password、
请求体或完整敏感响应。

HTTP access 摘要与拒绝原因是两种记录：前者用于流量统计，后者用于问题诊断。
不能只输出 `409`、`404` 或 `500` 而省略稳定错误码与原因。

## 3. Install plan digest 的语义

摘要绑定一次破坏性安装的有效输入，包括节点/profile 合并配置、磁盘与网络策略、
install source、kernel/initrd、repository、软件、后处理和实际交付密钥。它用于防止
客户端已经下载一部分旧启动输入后，又取得由新输入生成的 kickstart。

“摘要不一致”必须按 revision 分为两类：

| 条件 | 含义 | 诊断 |
|---|---|---|
| `session_revision != desired_revision` | PXE 授权后模型确实变化 | 提示重新武装 generation |
| revision 相同但 digest 不同 | runtime 输入或 snapshot 不一致 | 标记内部不变式异常 |

第二类不能称为“配置过时”，因为现有证据不能证明用户修改了配置。日志必须同时记录：

```text
node request_id session_revision desired_revision same_revision
session_digest_prefix desired_digest_prefix
```

只记录摘要前缀用于关联，不记录参与摘要的密钥或配置正文。

## 4. 为什么仍然拒绝

摘要不一致当前保持 fail closed。原因不是“摘要比安装重要”，而是服务端无法证明
客户端持有的 kernel/initrd、repository 入口与即将生成的 kickstart 属于同一个计划。
直接警告后放行可能把旧安装器与新磁盘布局混合，风险包括格式化错误磁盘或生成不可启动系统。

后续若要安全降级为警告并继续，前提必须是 boot session 已保存并能完整重放 immutable
install plan，而不是在请求 kickstart 时用当前模型重新编译。未满足此前提时不得静默放行。

## 5. 完整 InstallPlan 与容量上限

Repository 的 `software_index.capabilities` 必须完整保留，不能为了满足固定消息大小
而清空。slice 本身是动态长度；默认不施加 NodeForge 人为上限，由 allocator 和系统
可用内存约束。

默认配置为：

```json
{
  "capacity": {
    "managed_entries": null,
    "install_plan_max_bytes": null
  }
}
```

`null` 表示不限制。setup 默认显式生成该值，不提供命令行参数，也不在交互流程询问；
已有 `config.json` 缺少该字段时由 schema 默认值补齐。站点确实需要保护阈值时，只能
通过显式 config import 设置正整数，并在 `nodeforged --check-config` 校验后重启生效。

ISO 文件大小与软件索引大小不是一一对应关系：30 GiB ISO 不表示需要 30 GiB
InstallPlan。决定容量的是 repository 数量、package/group/task 条目数以及名称和描述
长度。r97n0 的 Rocky 10.2 ISO 为 9,659,678,720 bytes；旧完整计划约
1,556,962 bytes，其中两个 repository index 约 1,552,478 bytes、5630 个
capability。这证明旧 1 MiB 常量错误，也证明计划大小不按 ISO 容量等比例增长。

## 6. Repository index 内容寻址复用

ISO 导入阶段已经能够确定完整 SoftwareIndex，因此此时发布：

```text
assets/repository-indexes/<sha256>.json
```

最终 InstallPlan 不能在 ISO 导入时生成，因为 profile、node、storage/network
override、交付密钥和 install generation 尚未确定。PXE session 建立时生成的小计划
只保存 repository 交付字段及 `software_index_blob.digest/bytes` 引用；完整 capability
仍在共享 blob 中，不丢失功能。

相同 index 内容得到相同 SHA-256 路径，可跨 profile、node、session 复用；旧 catalog
在首次生成计划时自动补建 blob。这样 immutable session 不依赖“当前 catalog”，catalog
更新后旧 digest 指向的内容仍可重放。后续 GC 只能删除没有任何 catalog/session 引用的
blob。

日志分别记录 `plan_bytes`、`shared_index_bytes`、blob digest 前缀和 capability 数。
配置了显式上限且超限时返回 `install.plan_too_large`；无效输入、
`InstallPlanChanged`、OOM/持久化失败必须使用不同错误码，不得统一误报为计划变化。

## 7. 操作员排障

遇到 `install.plan_digest_mismatch`：

1. 用响应中的 `request_id` 定位服务日志。
2. 检查 `same_revision`。
3. `false` 表示模型变化，停止目标机后重新 retry。
4. `true` 表示内部输入不一致，保存对应日志并检查 HTTP/DHCP 使用的 model snapshot、
   bootstrap key 与 additional keys；不要把它归因于用户配置过时。
