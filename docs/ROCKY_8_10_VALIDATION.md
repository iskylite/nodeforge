# Rocky Linux 8.10 aarch64 VMware PXE validation

Validation date: 2026-07-13 (Asia/Shanghai).

## Environment

- PXE server: `r97n0`, Rocky Linux 9.7 aarch64, `192.168.27.128`.
- PXE target: VMware Fusion guest `r97n1`, MAC `00:50:56:2A:23:DB`.
- NodeForge node/profile: `pxe-test-node` / `rocky-8.10-install`.
- Reserved target address: `192.168.27.210`.
- Install source: `rocky-8.10-aarch64-iso`.
- A powered-off snapshot was created before the destructive test.

## Computer Use execution

VMware Fusion was operated directly through Computer Use:

1. Shut down the existing Ubuntu guest.
2. Select `Network Adapter Custom` as the startup disk.
3. Start `r97n1` after explicit destructive-action confirmation.
4. Observe the NodeForge GRUB entry
   `NodeForge - pxe-test-node:192.168.27.210 - rocky-8.10-install`.
5. Boot the selected entry and observe the EFI result.

The guest reproduced the terminal error:

```text
EFI stub: ERROR: This 64 KB granular kernel is not supported by your CPU
```

The guest was then shut down to stop the repeated PXE loop. The pre-test
snapshot remains available.

## NodeForge evidence

The current boot session is
`1f1cbd249f3f8cf6c2d7642d044aa5bf`. Its Event v2 records prove:

- DHCP DISCOVER/OFFER/REQUEST/ACK completed for `192.168.27.210`.
- `efi/grubaa64.efi` transferred successfully (2,693,464 bytes).
- The per-node GRUB configuration transferred successfully (350 bytes).
- `/install/rocky-8.10-aarch64-iso/vmlinuz` transferred successfully
  (10,623,316 bytes).
- `/install/rocky-8.10-aarch64-iso/initrd.img` transferred successfully
  (82,777,312 bytes).
- No `install.installer_started`, `install.started`, or later installer event
  exists for this session.
- Deployment generation 8 remains armed, so NodeForge did not consume the
  destructive generation and Anaconda did not begin writing the disk.

## Kernel provenance

The imported ISO is
`iso/c35d58c525865c5fb82e07ed-Rocky-8.10-aarch64-dvd1.iso`, SHA-256:

```text
4e3c2339f61510a293b631495571e72d1df852b1f2b765100defad193433467f
```

NodeForge imports the Rocky installer kernel from
`images/pxeboot/vmlinuz`. The file inside the read-only mounted ISO and the
published TFTP file are byte-identical and both have SHA-256:

```text
ca166105dd9d041a4921ad0ddce606be36154812a8e0cb7dc0732c9df2d28d69
```

The decompressed ARM64 Image contains the observed EFI error string. Its image
header has flags `0x000000000000000e`; `(flags >> 1) & 3 == 3`, which encodes a
64 KiB base page requirement. NodeForge did not replace, patch, recompress, or
otherwise transform this kernel.

## Conclusion

The failure is between the Rocky 8.10 aarch64 installer kernel's 64 KiB
translation-granule requirement and the CPU capabilities exposed to `r97n1` by
VMware Fusion. DHCP, TFTP, GRUB selection, kernel delivery, and initrd delivery
all completed before the EFI stub rejected the guest CPU. This environment
cannot be used to claim a completed Rocky 8.10 aarch64 installation.

The console error proves only that the guest-visible CPU does not advertise the
required 64 KiB translation granule. It does not by itself prove whether the
physical Apple CPU lacks the capability or VMware chose not to expose it.

ARM64 Linux base page size is a kernel build choice; it is not generally
switched at runtime. The fact that the existing Rocky 9.7 installer boots only
proves that its particular installer kernel is compatible with this VM. It
must not be explained as generic runtime switching through `CONFIG_ARM64_E0PD`.

## Supported next steps

1. Validate the same ISO on real ARM64 hardware or a hypervisor/CPU combination
   that exposes the 64 KiB translation granule.
2. Validate Rocky 8.10 x86_64 when the target architecture may change.
3. Use a vendor-supported Rocky 8 aarch64 installer kernel built for a
   compatible base page size, together with its matching initrd, modules, and
   repository. Do not mix a CentOS/Alma kernel into Rocky media and treat that
   as Rocky acceptance evidence.
4. In a future support-matrix milestone, NodeForge may parse the ARM64 Image
   header during import and record the required base page size. That can produce
   an early compatibility warning, but NodeForge still cannot infer an unknown
   target CPU's granule support or safely substitute another kernel.
