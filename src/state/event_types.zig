//! Event v2 稳定事件类型注册表，由 daemon 生产者和 CLI 发现共用。
//! 所有事件类型名称和描述在此集中定义，确保 daemon 和 CLI 使用一致的事件词汇表。

const model = @import("../model.zig");

/// 单个事件类型的元数据定义。
pub const EventDefinition = struct {
    /// 稳定事件名称（如 `dhcp.ack`），写入 events.jsonl 的 `type` 字段。
    name: []const u8,
    /// 事件描述，供 CLI 展示和文档引用。
    description: []const u8,
    /// 默认日志等级；错误类事件默认为 err。
    default_level: model.LogLevel = .info,
};

pub const EventType = enum {
    service_started,
    service_stopped,
    config_loaded,
    config_updated,
    boot_session_terminated,
    dhcp_discover,
    dhcp_offer,
    dhcp_request,
    dhcp_ack,
    dhcp_nak,
    dhcp_release,
    dhcp_decline,
    dhcp_abandoned,
    tftp_rrq,
    tftp_transfer_complete,
    tftp_transfer_error,
    http_request,
    boot_config_fetched,
    install_installer_started,
    install_config_fetched,
    install_started,
    install_partitioning,
    install_packages,
    install_bootloader,
    install_post,
    install_rebooting,
    install_completed,
    install_failed,
    install_retry_requested,
    install_configuration_drifted,
    boot_install_not_armed,
    diskless_initrd_started,
    diskless_rootfs_download_started,
    diskless_rootfs_verified,
    diskless_rootfs_mounted,
    diskless_switch_root,
    diskless_running,
    diskless_failed,
    provision_step_started,
    provision_step_succeeded,
    provision_step_warned,
    provision_step_failed,

    pub fn definition(self: EventType) EventDefinition {
        return definitions[@intFromEnum(self)];
    }
};

pub const definitions = [_]EventDefinition{
    .{ .name = "service.started", .description = "all listeners ready" },
    .{ .name = "service.stopped", .description = "orderly shutdown complete" },
    .{ .name = "config.loaded", .description = "validated configuration loaded" },
    .{ .name = "config.updated", .description = "configuration atomically updated" },
    .{ .name = "boot.session.terminated", .description = "active boot session terminated" },
    .{ .name = "dhcp.discover", .description = "DHCP DISCOVER received" },
    .{ .name = "dhcp.offer", .description = "DHCP OFFER sent" },
    .{ .name = "dhcp.request", .description = "DHCP REQUEST received" },
    .{ .name = "dhcp.ack", .description = "DHCP ACK sent" },
    .{ .name = "dhcp.nak", .description = "DHCP NAK sent" },
    .{ .name = "dhcp.release", .description = "lease released" },
    .{ .name = "dhcp.decline", .description = "address declined" },
    .{ .name = "dhcp.abandoned", .description = "probe found conflict" },
    .{ .name = "tftp.rrq", .description = "TFTP read requested" },
    .{ .name = "tftp.transfer.complete", .description = "TFTP transfer completed" },
    .{ .name = "tftp.transfer.error", .description = "TFTP transfer failed", .default_level = .err },
    .{ .name = "http.request", .description = "HTTP request completed" },
    .{ .name = "boot.config.fetched", .description = "authenticated boot config issued" },
    .{ .name = "install.installer_started", .description = "installer started" },
    .{ .name = "install.config_fetched", .description = "install config fetched" },
    .{ .name = "install.started", .description = "installation started" },
    .{ .name = "install.partitioning", .description = "partitioning in progress" },
    .{ .name = "install.packages", .description = "package installation in progress" },
    .{ .name = "install.bootloader", .description = "bootloader installation in progress" },
    .{ .name = "install.post", .description = "post-install phase in progress" },
    .{ .name = "install.rebooting", .description = "installer rebooting" },
    .{ .name = "install.completed", .description = "installation completed" },
    .{ .name = "install.failed", .description = "installation failed", .default_level = .err },
    .{ .name = "install.retry.requested", .description = "install generation rearmed" },
    .{ .name = "install.configuration_drifted", .description = "desired install configuration differs from the applied revision", .default_level = .warn },
    .{ .name = "boot.install_not_armed", .description = "install PXE denied because no generation is armed" },
    .{ .name = "diskless.initrd_started", .description = "diskless initrd started" },
    .{ .name = "diskless.rootfs_download_started", .description = "rootfs download started" },
    .{ .name = "diskless.rootfs_verified", .description = "rootfs verified" },
    .{ .name = "diskless.rootfs_mounted", .description = "rootfs mounted" },
    .{ .name = "diskless.switch_root", .description = "switch_root started" },
    .{ .name = "diskless.running", .description = "diskless system running" },
    .{ .name = "diskless.failed", .description = "diskless boot failed", .default_level = .err },
    .{ .name = "provision.step.started", .description = "provisioning step started" },
    .{ .name = "provision.step.succeeded", .description = "provisioning step succeeded" },
    .{ .name = "provision.step.warned", .description = "optional provisioning step warned", .default_level = .warn },
    .{ .name = "provision.step.failed", .description = "required provisioning step failed", .default_level = .err },
};

pub fn fromName(name: []const u8) ?EventType {
    inline for (@typeInfo(EventType).@"enum".fields) |field| {
        const value: EventType = @enumFromInt(field.value);
        if (@import("std").mem.eql(u8, value.definition().name, name)) return value;
    }
    return null;
}

test "every event enum has one stable definition" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, @typeInfo(EventType).@"enum".fields.len), definitions.len);
    try std.testing.expect(fromName("dhcp.ack") == .dhcp_ack);
}
