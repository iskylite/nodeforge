# Rocky 9.7 ARM M0 Validation

Validation target:

- Host: `r97n0`
- Login: `root@r97n0`
- Address: `192.168.26.128`
- OS: Rocky Linux 9.7, `aarch64`
- Validation time: 2026-07-10 14:00 CST on the VM

## Deployed files

- `/opt/nodeforge/bin/nodeforged`
- `/opt/nodeforge/bin/nodeforge`
- `/opt/nodeforge/systemd/nodeforged.service`
- `/opt/nodeforge/config/config.json`
- `/opt/nodeforge/catalog/catalog.json`
- `/etc/systemd/system/nodeforged.service -> /opt/nodeforge/systemd/nodeforged.service`
- `/usr/bin/nodeforge -> /opt/nodeforge/bin/nodeforge`
- `/usr/bin/nodeforged -> /opt/nodeforge/bin/nodeforged`

`nodeforged` 正常启动时自动使用 `/opt/nodeforge/config/config.json` 和
`/opt/nodeforge/catalog/catalog.json`，systemd unit 不再传长路径参数；`--config`
和 `--catalog` 仅作为开发/测试/排障覆盖入口。

The active `/opt/nodeforge` directory is grouped by function:

```text
/opt/nodeforge/
  bin/
  systemd/
  config/
  catalog/
  state/
  logs/
  assets/
  repos/
  tftp/
  initrd/
  rootfs/
  bundles/
  provisioned/
  run/
  work/
```

Old pre-flat `/opt/nodeforge` test content was moved aside to a timestamped
`/opt/nodeforge.pre-flat-*` directory. Old pre-`/opt` test binaries under
`/usr/local/sbin/` were previously renamed to `*.pre-opt-layout` so the normal
shell `PATH` resolves `nodeforge` and `nodeforged` through `/usr/bin`.

The deployed config uses:

- `server.server_ip = "192.168.26.128"`
- `server.bind_interface = null` for M0 validation
- `server.http_port = 8080`
- `http.asset_root = "/opt/nodeforge/assets"`
- `http.repository_root = "/opt/nodeforge/repos"`
- `logging.level = "info"` in the current example configuration; `nodeforged -d` overrides it for one diagnostic start

## M0 validation result

Passed:

- `nodeforged --check-config`
- `nodeforged --check` before service startup
- `systemctl restart nodeforged`
- systemd uses short default-path commands: `ExecStart=/opt/nodeforge/bin/nodeforged` and `ExecStartPre=/opt/nodeforge/bin/nodeforged --check`
- repeated fast `systemctl restart nodeforged`
- systemd unit symlink through `/etc/systemd/system`
- system command symlinks through `/usr/bin`
- `nodeforge --version` and `nodeforged --version`
- zli-generated top-level, resource-level, and action-level CLI help
- command-local zli flags on nested commands, for example `nodeforge config validate --config ... --catalog ... --output json`
- local CLI `status` through `127.0.0.1:8080`
- local CLI `check` prints a concise health result and uses the exit code for automation
- duplicate `server status/check` CLI entry removed
- VM-local `/healthz`
- VM-local management route
- host-to-VM `/healthz`
- host-to-VM management route returns 200; routes accept every client that can reach the listener
- systemd journal contains HTTP request summaries

Observed expected results:

```text
nodeforge status --output json
{"process":true,"http":true,"management":true,"config":true}
```

```text
nodeforge status
NodeForge status
  Process     OK reachable
  HTTP        OK healthy http://192.168.26.128:8080
  Management  OK route http://127.0.0.1:8080
  Config API  OK config valid

nodeforge check
OK nodeforge checks passed
```

```text
nodeforge server status
Unknown command: 'server'

Run: 'nodeforge --help'
exit=2
```

```text
command -v nodeforge
/usr/bin/nodeforge
```

```text
readlink -f /etc/systemd/system/nodeforged.service
/opt/nodeforge/systemd/nodeforged.service
```

```text
systemctl --no-pager --full status nodeforged
Process: ... ExecStartPre=/opt/nodeforge/bin/nodeforged --check (code=exited, status=0/SUCCESS)
CGroup: /system.slice/nodeforged.service
        └─... /opt/nodeforge/bin/nodeforged
```

```text
nodeforge --version
nodeforge 0.0.0

nodeforged --version
nodeforged 0.0.0
```

```text
curl http://192.168.26.128:8080/healthz
HTTP/1.1 200 OK
{"ok":true,"service":"nodeforge"}
```

```text
curl http://192.168.26.128:8080/api/v1/management/server/status
HTTP/1.1 200 OK
{"ok":true,"result":{"service":"running"}}
```

```text
nodeforge config validate --config /opt/nodeforge/config/config.json --catalog /opt/nodeforge/catalog/catalog.json --output json
{"ok":true,"config":"/opt/nodeforge/config/config.json","catalog":"/opt/nodeforge/catalog/catalog.json"}
```

Historical output from the 2026-07-10 deployment:

```text
journalctl -u nodeforged -n 30
info: HTTP GET /healthz -> 200
info: HTTP GET /api/v1/management/server/status -> 200
```

## Design corrections confirmed by validation

- M0 uses exactly one HTTP listener.
- The listener binds `0.0.0.0:<http_port>`.
- `server.server_ip` is the advertised PXE service address for generated URLs and future DHCP/TFTP advertisement; it is not the M0 HTTP bind address.
- CLI management access is fixed to `127.0.0.1:<http_port>`.
- The CLI has no remote endpoint option and therefore only manages `nodeforged` on the same host.
- M0 does not define a separate `management_port`; management routes share `server.http_port`, currently `8080`.
- Management routes accept every IPv4 client that can reach the listener and do not check peer source.
- M0 management routes have no authentication or TLS, so validation and deployment must use a trusted network.
- CLI parsing and generated help use vendored `zli v5.1.2`; command-local flags are verified through nested `config validate`.
- HTTP request summaries are logged at info level to stderr/systemd journal.
- The listener and preflight use `SO_REUSEADDR` so normal systemd fast restarts do not fail on a just-released socket.
- The M0 systemd unit does not request DHCP/TFTP-oriented capabilities.
- `nodeforged` auto-discovers default config/catalog paths under `/opt/nodeforge`; explicit `--config`/`--catalog` remain override-only.

## Current-code follow-up

The current workspace adds `logging.level`, daemon `-d/--debug`, command-local CLI `-d/--debug`, short flags,
and Makefile cross-compilation targets after the historical VM deployment above. Before treating these as VM-verified,
rebuild with `make arm64`, deploy the two binaries, then verify:

- `nodeforge config export -c ./missing.json` prints one concise `error:` line; adding `-d` prints the cause line.
- `nodeforged -d` emits `debug: http: accepted connection` for an HTTP request; `logging.level = "debug"` does the same without `-d`.
- `nodeforge config validate -c ... -C ... -o json` and daemon `-K -c ... -C ...` succeed.
