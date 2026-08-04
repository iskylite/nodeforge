# Historical validation fixtures

These scripts preserve v0.2/v0.2.1 evidence and intentionally exercise APIs and
credential layouts removed from v0.4. They are not current tests, are not wired
into `zig build test`, and must not be used to validate or deploy current
NodeForge binaries.

Current diskless/rootfs validation lives under `tests/` and obtains every ready
squashfs through the nodeforged `profile rootfs build` operation.
