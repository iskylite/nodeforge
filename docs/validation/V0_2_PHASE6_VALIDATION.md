# NodeForge v0.2 Phase 6 验证记录（diskless initrd/agent 启动链 + QEMU 烟测）

> 验证日期：2026-07-23（Asia/Shanghai）。
> 验证机：`root@r97n0`，Rocky Linux 9.7 aarch64，`192.168.27.128`。
> 本地构建机：macOS arm64，Zig 0.16.0；交叉编译 `aarch64-linux-gnu ReleaseSafe`。
> 烟测虚拟化：r97n0 上 QEMU 10.1.0（`/usr/libexec/qemu-kvm`，TCG `-cpu max`，direct-kernel boot）。

## 1. 范围

v0.2 Phase 6 = diskless 启动链（initrd PID-1 编排 + 切根后 agent pre-init）的编译通过与
端到端烟测，对应 `V0_2_DESIGN.md` §4.3 boot-time 序列：

- `src/initrd.zig`：dracut initrd 的 PID 1，编排 mount→network→拉 BootConfig v2→下载校验
  rootfs→overlay 合并→写 handoff→`switch_root` 执行 agent。
- `src/agent.zig`：切根后 `--pre-init`，读 handoff→拉校验 AgentPlan v1 与 payload→node-apply
  写运行根差量（hostname/machine-id/hosts）→`exec /sbin/init`。
- 在 r97n0 用 dracut 构建含 `nodeforge-initrd`+`nodeforge-agent`+内核模块的 initramfs，
  配合 mock BootConfig/rootfs/AgentPlan server，QEMU direct-kernel boot 烟测完整链路。

## 2. Zig 0.16.0 API 对齐（编译修复）

`initrd.zig`/`agent.zig` 原按旧 API 编写，在 Zig 0.16.0 下逐项对齐（全部已编译通过）：

- `main(init: std.process.Init)`：用 `init.io`（`std.Io`）与 `init.arena.allocator()`；
  旧 `std.heap.GeneralPurposeAllocator` 在 0.16.0 不存在。
- 子进程：`std.process.Child.init`/`spawnAndWait` → `std.process.run(allocator, io, .{ .argv })`
  返回 `RunResult{ .term, .stdout, .stderr }`，按 `.exited` 码判定。
- 文件 I/O：`std.fs.cwd()` 在 0.16.0 不存在 → `std.Io.Dir.cwd().readFileAlloc(io, path,
  allocator, .limited(n))` / `.createFile` / `.writeFile` / `.createDirPath`。
- 命令行参数：`std.process.argsAlloc` 不存在 → `init.minimal.args.iterate()` + `next()`。
- `execInit`：spawn 子进程会挂起（systemd 不退出）→ `std.process.replace`（execve）。
- `machineId`：原 `Sha256.hash` 写入 16 字节缓冲（类型/越界）→ 用 32 字节缓冲取前 16 字节。
- `var out`→`const out`（未变更变量）。

## 3. 烟测中发现并修复的启动链缺陷

通过 QEMU 串口逐步定位，修复了 5 个会阻断 diskless 启动的真实缺陷：

1. **handoff 写入旧根**：`writeHandoff` 写 `/run/nodeforge/boot.json`（initramfs 旧根），
   `switch_root` 会删除旧根 → agent 读不到。改为写新根 `/merged/run/nodeforge/boot.json`。
2. **squashfs 挂载缺 loop**：直接 `mount -t squashfs -o ro <file>` 不挂 loop 设备，且
   `losetup -f` 结果未用 → 改 `-o ro,loop`。
3. **overlay upper/work 跨文件系统**：`upperdir=/upper`、`workdir=/work` 分属不同 tmpfs，
   overlay 要求同 fs → 统一挂一个 tmpfs 于 `/rw`，`upper`/`work` 置其下。
4. **procfs 读取返回空**：`readFileAlloc`（Io Threaded reader）读 `/proc/cmdline` 得 0 字节
   （对 procfs 不可靠），导致 `config_url=null`→`MissingConfigUrl`。改用 `cat /proc/cmdline`
   子进程（`captureRun`）读取。
5. **switch_root 非 PID-1 执行**：原 `mustRun`（spawn 子进程）调 `switch_root`，但
   `switch_root` 必须 by PID 1 才能删除旧 rootfs 并 exec 新 init → 改用
   `std.process.replace`（execve）以 PID 1 接管。

烟测侧（非 v0.2 代码，环境层）：initramfs `/init` 包装脚本加载 `loop/squashfs/overlay/
virtio_net` 模块（el9 为 `=m` 非内建）并配置 QEMU user-net 静态网络（生产 diskless 由
nodeforged DHCP 提供；烟测用 `10.0.2.15/24`，host `10.0.2.2`）。

## 4. 烟测构成（r97n0）

- **kernel**：`/boot/vmlinuz-5.14.0-611.5.1.el9_7.aarch64`。
- **initramfs**：dracut `--no-hostonly --filesystems "squashfs overlay" --add-drivers
  "loop squashfs overlay" --install "curl dhclient sha512sum losetup switch_root ip ..."`，
  后处理注入 `/init` 包装脚本、`/sbin/nodeforge-initrd`、`/capsule/config-token`、
  `libpthread.so.0` stub（glibc 2.34 合并 pthread，交叉编译 NEEDED 仍列它）。
- **rootfs squashfs**：`dnf --installroot`（bash/coreutils/curl/util-linux）+ `nodeforge-agent`
  于 `/sbin/nodeforge-agent` + 烟测 `/sbin/init` 脚本 → `mksquashfs -comp xz`（82MB）。
- **mock server**：Python `http.server` 于 `0.0.0.0:8090`，提供 `/bootconfig`（BootConfig v2，
  含 rootfs url+sha512、agent_plan url+sha256 digest、access tokens）、`/rootfs.squashfs`、
  `/agent-plan/<digest>`（AgentPlan v1，空 payload）。digest 与 sha512 均按服务字节实算并核对。
- **QEMU**：`-machine virt -accel tcg -cpu max -m 2048 -smp 2 -kernel … -initrd … -append
  "console=ttyAMA0 nodeforge.config_url=… nodeforge.node=smoke01 nodeforge.session=sess1"
  -netdev user -device virtio-net-pci -nographic -no-reboot`。

## 5. 验证结果

QEMU 串口输出（`boot_final.log`）端到端成功：

```
[    1.948089] Run /init as init process
[ … loop/squashfs/overlay/virtio_net 模块加载 … ]
=== NODEFORGE SMOKE BOOT: reached real init (PID 1) ===
hostname: smoke01
machine-id: ef98ecbb54a375670d4074aab76a3115
=== SMOKE BOOT SUCCESS ===
```

完整链路逐段验证通过：

1. initrd PID-1：mount proc/sys/dev → 读 `/proc/cmdline`（config_url/node/session）→
   network up → 读 capsule config-token → curl 拉 BootConfig v2 → 下载 rootfs.squashfs →
   **SHA-512 校验通过** → squashfs loop 挂载（lower）+ tmpfs（rw upper/work）+ overlay 合并 →
   写 handoff 至新根 `/merged/run/nodeforge/boot.json`。
2. `switch_root`（execve as PID 1）→ `/sbin/nodeforge-agent --pre-init`。
3. agent：读 handoff → curl 拉 AgentPlan v1 → **SHA-256 digest 校验通过**（空 payload）→
   node-apply 写 `/etc/hostname=smoke01`、`/etc/machine-id`、`/etc/hosts` → `exec /sbin/init`。
4. 真正 init：打印成功并展示 agent 写入的 hostname/machine-id。

`node=smoke01` 经 cmdline → initrd → handoff → agent node-apply 写入 `/etc/hostname`，
证明 Node 运行根差量在切根后于 overlay upper 生效。machine-id 为 node 派生 hash（设计一致）。

> 烟测后 kernel panic（exit 127）仅因烟测 rootfs 的 `/sbin/init` 脚本里 `poweroff -f` 在
> 最小 rootfs 不可用；启动链本身已完整成功，非 v0.2 缺陷。

## 6. 构建与测试状态

- 本地 `zig build`：4 个产物（`nodeforge`/`nodeforged`/`nodeforge-initrd`/`nodeforge-agent`）全绿。
- 交叉编译 `-Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe`：ELF aarch64，glibc 兼容，
  r97n0 `ldd` 解析正常、运行正常。
- r97n0 `zig build test`：**310/310 单测通过**（含 cli.sh/http.sh Linux 全量）；生产
  `nodeforged` 已停起恢复（UDP 67/69 烟测前停、后启）。
- 工作树未提交（按要求不 git commit）。
