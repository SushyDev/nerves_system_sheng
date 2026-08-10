################################################################################
#
# ab_ops
#
################################################################################

AB_OPS_SITE = $(BR2_EXTERNAL_NERVES_PATH)/package/ab_ops/src
AB_OPS_SITE_METHOD = local
AB_OPS_LICENSE = Apache-2.0

define AB_OPS_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -o $(@D)/ab_ops $(@D)/ab_ops.c
endef

define AB_OPS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/ab_ops $(TARGET_DIR)/usr/bin/ab_ops
endef

$(eval $(generic-package))
