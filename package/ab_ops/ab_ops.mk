################################################################################
#
# ab_ops
#
################################################################################

AB_OPS_SITE = $(BR2_EXTERNAL_NERVES_PATH)/package/ab_ops/src
AB_OPS_SITE_METHOD = local
AB_OPS_LICENSE = Apache-2.0
AB_OPS_DEPENDENCIES = host-zig

define AB_OPS_BUILD_CMDS
	$(HOST_DIR)/bin/zig build-exe \
		-target aarch64-linux-gnu -lc -O ReleaseSafe \
		--cache-dir $(@D)/.zig-cache --global-cache-dir $(@D)/.zig-cache \
		-femit-bin=$(@D)/ab_ops \
		$(@D)/main.zig
endef

define AB_OPS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/ab_ops $(TARGET_DIR)/usr/bin/ab_ops
endef

$(eval $(generic-package))
