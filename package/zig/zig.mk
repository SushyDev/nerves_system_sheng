################################################################################
#
# zig (host)
#
################################################################################

HOST_ZIG_VERSION = 0.16.0
HOST_ZIG_SITE = https://ziglang.org/download/$(HOST_ZIG_VERSION)

# Zig ships prebuilt per host arch; no build step, just unpack + install.
ifeq ($(HOSTARCH),x86_64)
HOST_ZIG_SOURCE = zig-x86_64-linux-$(HOST_ZIG_VERSION).tar.xz
else ifeq ($(HOSTARCH),aarch64)
HOST_ZIG_SOURCE = zig-aarch64-linux-$(HOST_ZIG_VERSION).tar.xz
else
$(error host-zig: unsupported HOSTARCH '$(HOSTARCH)')
endif

define HOST_ZIG_INSTALL_CMDS
	$(INSTALL) -D -m 0755 $(@D)/zig $(HOST_DIR)/bin/zig
	rm -rf $(HOST_DIR)/lib/zig
	cp -a $(@D)/lib $(HOST_DIR)/lib/zig
endef

$(eval $(host-generic-package))
