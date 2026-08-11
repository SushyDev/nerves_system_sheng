################################################################################
#
# ufs_boot_lun
#
################################################################################

UFS_BOOT_LUN_SITE = $(BR2_EXTERNAL_NERVES_PATH)/package/ufs_boot_lun/src
UFS_BOOT_LUN_SITE_METHOD = local
UFS_BOOT_LUN_LICENSE = Apache-2.0
UFS_BOOT_LUN_DEPENDENCIES = host-zig

define UFS_BOOT_LUN_BUILD_CMDS
	$(HOST_DIR)/bin/zig build-exe \
		-target aarch64-linux-gnu -lc -O ReleaseSafe \
		--cache-dir $(@D)/.zig-cache --global-cache-dir $(@D)/.zig-cache \
		-femit-bin=$(@D)/ufs_boot_lun \
		$(@D)/main.zig
endef

define UFS_BOOT_LUN_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/ufs_boot_lun $(TARGET_DIR)/usr/bin/ufs_boot_lun
endef

$(eval $(generic-package))
