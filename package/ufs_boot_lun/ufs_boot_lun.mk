################################################################################
#
# ufs_boot_lun
#
################################################################################

UFS_BOOT_LUN_SITE = $(BR2_EXTERNAL_NERVES_PATH)/package/ufs_boot_lun/src
UFS_BOOT_LUN_SITE_METHOD = local
UFS_BOOT_LUN_LICENSE = Apache-2.0

define UFS_BOOT_LUN_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -o $(@D)/ufs_boot_lun $(@D)/ufs_boot_lun.c
endef

define UFS_BOOT_LUN_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/ufs_boot_lun $(TARGET_DIR)/usr/bin/ufs_boot_lun
endef

$(eval $(generic-package))
