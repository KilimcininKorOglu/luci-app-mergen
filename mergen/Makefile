include $(TOPDIR)/rules.mk

PKG_NAME:=mergen
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=KilimcininKorOglu
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/mergen
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Routing and Redirection
  TITLE:=ASN/IP based policy routing daemon
  DEPENDS:=+ip-full +curl +jsonfilter
  PKGARCH:=all
endef

define Package/mergen/description
  Mergen is a policy routing daemon for OpenWrt that automatically resolves
  ASN prefix lists and creates ip rule/route entries. Supports nftables sets
  for performant packet matching with ipset fallback for older systems.
endef

define Package/mergen/conffiles
/etc/config/mergen
endef

define Package/mergen/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/mergen $(1)/etc/config/mergen

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/mergen $(1)/etc/init.d/mergen

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DATA) ./files/etc/hotplug.d/iface/50-mergen $(1)/etc/hotplug.d/iface/50-mergen

	$(INSTALL_DIR) $(1)/etc/mergen/providers
	$(INSTALL_DIR) $(1)/etc/mergen/rules.d

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/mergen $(1)/usr/bin/mergen

	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/mergen-watchdog $(1)/usr/sbin/mergen-watchdog

	$(INSTALL_DIR) $(1)/usr/lib/mergen
	$(INSTALL_DATA) ./files/usr/lib/mergen/core.sh $(1)/usr/lib/mergen/core.sh
	$(INSTALL_DATA) ./files/usr/lib/mergen/resolver.sh $(1)/usr/lib/mergen/resolver.sh
	$(INSTALL_DATA) ./files/usr/lib/mergen/engine.sh $(1)/usr/lib/mergen/engine.sh
	$(INSTALL_DATA) ./files/usr/lib/mergen/route.sh $(1)/usr/lib/mergen/route.sh
	$(INSTALL_DATA) ./files/usr/lib/mergen/utils.sh $(1)/usr/lib/mergen/utils.sh
endef

$(eval $(call BuildPackage,mergen))
