# M0–M4.1 implementation audit (2026-07-13)

This review separates code evidence from the target design; a documented target is
not treated as delivered merely because it appears in `DETAILED_DESIGN.md`.

| Milestone | Confirmed baseline | Gaps / acceptance gates |
| --- | --- | --- |
| M0 | Config/catalog load, validate and atomic store; single HTTP listener; local-only management API; CLI help contracts and service preflight are present and covered by `zig build test`. | Keep the default-path and localhost-only boundary under regression whenever HTTP routing changes. |
| M1 | TFTP packet/session/server and virtual GRUB path are implemented; TFTP error/TID/options remain a cross-cutting regression gate. | Hardware firmware variants beyond current UEFI fixtures remain M6 work. |
| M2 / M2.5 | DHCP allocation, reservation, ICMP conflict probe, persistent lease/status projections, Event v2 and boot-session correlation are implemented. | DHCP T1/T2 and clock rollback must be re-run whenever long installer validation changes lease behaviour. |
| M3 | Authenticated PXE HTTP routes, range/static assets, ISO import/publish and installer event transport are implemented. | ISO ENOSPC/orphan recovery and live media schema validation remain mandatory regression cases. |
| M4 | Ubuntu NoCloud and Rocky Kickstart adapters, storage and constrained install-post path exist. | The old answers still lacked crypt-correct password handling, shared target-system facts, target static network, root/sshd/firewall/SELinux finalization, installer-context lifecycle hooks and repeat-install prevention. |

## M4.1 changes made in this worktree

- Added the strongly typed, defaulted `profile.system` policy and
  `node.overrides.network` model.  The default remains local-only, DHCP,
  OpenSSH/root password authentication enabled, firewall disabled and Rocky
  SELinux disabled.
- Added M4 compatibility normalization for legacy `install.users` and
  `install.packages`; ambiguous old/new combinations fail rather than merging
  silently.
- Added a pure Zig, fixture-tested SHA-512 crypt implementation.  It derives
  `$6$` values only while rendering answers, uses a session/account-derived
  salt for retry-stable answers, and leaves password fields as plaintext config
  facts.
- Switched the authenticated answer route and `install render` preview to M4.1
  adapters.  Ubuntu now renders locale/timezone/keyboard, local-only apt
  controls, Netplan DHCP/static targeting, account data, sshd policy and UFW
  finalization.  Rocky renders rootpw/user hashes with `--iscrypted`, SSH,
  static networking, firewalld masking and `selinux --disabled`.
- Added value validation for target locale/timezone/keyboard, target users,
  keys, static IPv4/MAC/address matching and time-sync requirements.
- Added durable `deployment-control.json`: install nodes receive one initial
  generation, `install.started` consumes it, the DHCP resolver suppresses PXE
  for consumed generations, and `nodeforge install retry <node>` explicitly
  rearms the next generation through the localhost-only management API.
- Added installer-context lifecycle hooks: Ubuntu uses early/error commands;
  Rocky uses `%pre`/`%onerror`. Both emit `installer_started`, `started`,
  `post`, and failure events through the authenticated node event API.
- Added bootstrap admin-key resolution: an explicit server key wins, then root
  RSA/Ed25519 public keys, then a persistent OpenSSH-generated Ed25519 key.
  Its public half is merged (deduplicated) into root and every declared user;
  its private half remains in `/opt/nodeforge/assets/keys` only.

## Remaining boundary acceptance

Rocky 9.7 and Ubuntu 22.04 have completed the positive M4/M4.1 real-install,
login and lifecycle path. The remaining items below are negative or portability
boundaries; they do not revert those two completed system validations. The
former claim that Ubuntu action-based storage was absent is also no longer
correct: `renderStorageM41` emits a disk-pinned `layout: direct` plan or a
curtin action graph for explicit partitions.

1. Package availability is syntax- and duplicate-validated. Because the current
   catalog does not persist package indexes, `install render` now reports
   `package_availability=installer-media`; repository-index preflight becomes
   mandatory when that metadata is added rather than pretending availability
   can currently be proven.
2. The local-only answer text is covered, but an isolated-VLAN packet capture
   (or equivalent egress-deny counter) is still required to prove no installer
   path reaches the public Internet.
3. Full Rocky 8.10 aarch64 installation on this VMware/Apple-Silicon lab is
   blocked by the media kernel itself: its EFI stub requires a 64 KiB page
   granule that the VM CPU does not provide. This must be repeated on compatible
   ARM hardware or with a supported Rocky 8 x86_64 VM; it is not valid to mark
   installer lifecycle or post-login as passed from the GRUB handoff alone. The
   observed console error is `EFI stub: ERROR: This 64 KB granular kernel is not supported by your CPU`.

## Validation evidence

- `zig build test` passes locally and on `r97n0` (unit tests plus the CLI and
  HTTP integration suites), including the SHA-512 crypt/OpenSSL vector and new
  Ubuntu/Rocky M4.1 answer fixtures.
- `zig build` passes.
- VMware Fusion/Computer Use real installs on `r97n1` completed Rocky 9.7 and
  Ubuntu 22.04 with bootstrap-key and `nodeforge` password SSH login. Both
  produced `installer_started → started → post → completed`; Ubuntu also
  verified its static `192.168.27.210/24` target network.
- Rocky 8.10 aarch64 DVD was imported through the daemon after its tuple was
  declared. Catalog ISO/kernel/initrd SHA-256 values match their published
  files, both BaseOS and AppStream `repomd.xml` files exist, and the generated
  answer passes `ksvalidator -v RHEL8` and `-v RHEL9` with static
  `--netmask=255.255.255.0` syntax. r97n1 completed DHCP, TFTP GRUB, kernel
  and initrd transfer in a fresh Computer Use run, then stopped at the
  documented 64 KiB-granule EFI error. The current session and byte-level
  provenance are recorded in `docs/ROCKY_8_10_VALIDATION.md`.
- ISO-import publication/copy failures now roll back only files owned by that
  invocation, catalog-publication failures clean all unpublished outputs, and
  read-only DVD work trees use a safe removal fallback so successful imports do
  not leak multi-gigabyte staging directories.
- Sendfile-backed HTTP requests now preserve the request path before handing
  ownership to facil.io, preventing large ISO/repository audit events from
  recording released request memory as NUL-filled paths. A deployed GET of the
  Rocky 8.10 BaseOS `repomd.xml` records the complete route, status 200 and the
  exact 3973-byte object size.
