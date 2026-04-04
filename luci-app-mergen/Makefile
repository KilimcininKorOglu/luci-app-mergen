include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI interface for Mergen ASN/IP policy routing
LUCI_DEPENDS:=+mergen +luci-base
LUCI_DESCRIPTION:=Web interface for managing Mergen ASN/IP based policy routing rules, \
 provider configuration and system status monitoring.
LUCI_PKGARCH:=all

PKG_LICENSE:=MIT

include ../../luci.mk

# call BuildPackage - OpenWrt buildroot
$(eval $(call BuildPackage,luci-app-mergen))
