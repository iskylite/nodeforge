# Rocky Linux 9.7 diskless CLI 构建记录

本文记录在 `r97n0` 上，基于已经导入的 Rocky Linux 9.7 ISO，仅使用 NodeForge CLI 构建 diskless 共用材料的完整步骤。

本流程不直接编辑配置文件或 Catalog，也不创建 Node。MAC 地址、节点 IP、主机名和是否启用部署属于具体节点配置，不属于共用 diskless 材料。

## 1. 确认服务和配置有效

```sh
nodeforge --version
nodeforge status --output json
nodeforge config validate --output json
nodeforge catalog validate --output json
```

`r97n0` 当前使用的 Rocky Linux 9.7 安装源是：

```text
rocky-9.7-aarch64-minimal
```

## 2. 查看已经导入的安装源

```sh
nodeforge assets install-source list --output json
nodeforge assets install-source show rocky-9.7-aarch64-minimal --output json
```

安装源应包含以下关键引用：

```text
installer_kernel = rocky-9.7-aarch64-minimal-kernel
installer_initrd = rocky-9.7-aarch64-minimal-installer-initrd
arch = aarch64
version = 9.7
```

确认内核资产和构建机内核 release：

```sh
uname -r
nodeforge assets show rocky-9.7-aarch64-minimal-kernel --output json
```

本次实际使用的 kernel release 是：

```text
5.14.0-611.5.1.el9_7.aarch64
```

## 3. 构建 NodeForge diskless initrd

```sh
nodeforge assets initrd build rocky-9.7-aarch64-minimal-nodeforge-initrd \
  --from-install-source rocky-9.7-aarch64-minimal \
  --kernel-release 5.14.0-611.5.1.el9_7.aarch64 \
  --output json
```

检查已经注册的 initrd 资产：

```sh
nodeforge assets show rocky-9.7-aarch64-minimal-nodeforge-initrd --output json
```

该命令将 ISO installer initrd 作为逐字节不变前缀，并追加 `nodeforge-initrd`、
`nodeforge-agent`、DHCP hooks 和 diskless 启动入口。启动时由 ISO 自带的 udev 规则按
modalias 自动选择网卡驱动；不要额外注入或写死 `vmxnet3`、`virtio_net`、`e1000e`。

## 4. 创建 BootBundle

```sh
nodeforge assets boot-bundle create rocky-9.7-aarch64-minimal-diskless \
  --kernel rocky-9.7-aarch64-minimal-kernel \
  --initrd rocky-9.7-aarch64-minimal-nodeforge-initrd \
  --distro rocky \
  --version 9.7 \
  --arch aarch64 \
  --kernel-release 5.14.0-611.5.1.el9_7.aarch64 \
  --output json
```

查看 BootBundle：

```sh
nodeforge assets boot-bundle show rocky-9.7-aarch64-minimal-diskless --output json
```

## 5. 创建 diskless Profile

```sh
nodeforge profile create rocky-9.7-aarch64-minimal-diskless \
  rocky-9.7-aarch64-minimal \
  --kind diskless \
  --boot-bundle rocky-9.7-aarch64-minimal-diskless \
  --output json
```

检查 Profile：

```sh
nodeforge profile show rocky-9.7-aarch64-minimal-diskless --output json
```

## 6. 生成 rootfs 构建计划

```sh
nodeforge profile rootfs plan rocky-9.7-aarch64-minimal-diskless --output json
```

命令返回的 `rootfs_input_digest` 是本次构建的精确输入摘要。BootBundle 或 initrd
revision 变化后必须重新 plan，不能复用旧摘要：

```text
<rootfs_input_digest>
```

## 7. 构建 squashfs rootfs

```sh
nodeforge profile rootfs build rocky-9.7-aarch64-minimal-diskless \
  --if-input-digest <rootfs_input_digest> \
  --output json
```

检查 rootfs 状态：

```sh
nodeforge profile rootfs status rocky-9.7-aarch64-minimal-diskless --output json
```

构建结果至少应满足：

```text
state = ready
rootfs_input_digest = <rootfs_input_digest>
file = <rootfs_input_digest>.squashfs
content_sha512 = <sha512>
```

## 8. 最终检查

```sh
nodeforge status --output json
nodeforge config validate --output json
nodeforge catalog validate --output json
nodeforge assets boot-bundle show rocky-9.7-aarch64-minimal-diskless --output json
nodeforge profile show rocky-9.7-aarch64-minimal-diskless --output json
nodeforge profile rootfs status rocky-9.7-aarch64-minimal-diskless --output json
nodeforge node readiness <node_id> --output json
```

至此，共用 diskless 材料已经齐全：安装源、安装器 kernel、NodeForge initrd、BootBundle、diskless Profile 和 squashfs rootfs。

节点首次添加时保持 `deploy=false`。需要启动或失败后重试时执行：

```sh
nodeforge node retry <node_id> --output json
nodeforge node show <node_id>
```

`retry` 会设置 `deploy=true` 并 rearm generation，但不会远程重启节点。操作员仍需手动启动或重启目标机器。
