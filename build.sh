#!/bin/bash
# Copyright 2026 KilimcininKorOglu
# https://github.com/KilimcininKorOglu/luci-app-mergen
# Licensed under the GPL-2.0-only License

# Mergen - IPK Package Builder
# Builds standalone IPK packages without OpenWrt SDK
# Produces: mergen (daemon) + luci-app-mergen (web UI)

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Cross-platform sed -i wrapper (GNU vs BSD)
sed_inplace() {
    if sed --version >/dev/null 2>&1; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# Cross-platform installed size calculation
get_installed_size() {
    local dir="$1"
    if du -sb /dev/null >/dev/null 2>&1; then
        du -sb "$dir" | cut -f1
    else
        # macOS: sum all file sizes
        find "$dir" -type f -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1}END{print s+0}'
    fi
}

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

# Self-check: fix line endings in build.sh itself if needed
if command -v dos2unix >/dev/null 2>&1; then
    if file "$0" 2>/dev/null | grep -q "CRLF"; then
        echo -e "${YELLOW}!${NC} Build script has Windows line endings, converting..."
        dos2unix "$0" 2>/dev/null
        echo -e "${GREEN}+${NC} Converted build.sh to Unix line endings"
        echo -e "${BLUE}i${NC} Please re-run the build script"
        exit 0
    fi
else
    if grep -q $'\r' "$0" 2>/dev/null; then
        echo -e "${YELLOW}!${NC} Build script has Windows line endings, converting..."
        sed_inplace 's/\r$//' "$0"
        echo -e "${GREEN}+${NC} Converted build.sh to Unix line endings"
        echo -e "${BLUE}i${NC} Please re-run the build script"
        exit 0
    fi
fi

# Package source directories
MERGEN_DIR="$PROJECT_DIR/mergen"
LUCI_DIR="$PROJECT_DIR/luci-app-mergen"
DIST_DIR="$PROJECT_DIR/dist"

# Extract metadata from Makefile (read-only, never modified)
PKG_VERSION=$(grep '^PKG_VERSION:=' "$MERGEN_DIR/Makefile" | cut -d'=' -f2)
PKG_MAINTAINER=$(grep '^PKG_MAINTAINER:=' "$MERGEN_DIR/Makefile" | cut -d'=' -f2)
PKG_LICENSE=$(grep '^PKG_LICENSE:=' "$MERGEN_DIR/Makefile" | cut -d'=' -f2)

if [ -z "$PKG_VERSION" ]; then
    echo -e "${RED}ERROR: Could not extract PKG_VERSION from $MERGEN_DIR/Makefile${NC}"
    exit 1
fi

# Build number from git commit count
BUILD_NUM=$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo "1")
FULL_VERSION="${PKG_VERSION}-${BUILD_NUM}"
PKG_ARCH="all"

# Reproducible tar flags
TAR_OWNER_FLAGS="--owner=0 --group=0 --numeric-owner"

# Temporary build directory with automatic cleanup
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mergen-build.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT

# IPK structure verification function
verify_ipk() {
    local ipk_file="$1"
    local pkg_label="$2"

    local contents
    contents=$(tar -tzf "$ipk_file" 2>/dev/null | head -3)
    local expected="debian-binary
control.tar.gz
data.tar.gz"

    if [ "$contents" != "$expected" ]; then
        echo -e "  ${RED}X${NC} $pkg_label: Incorrect IPK structure!"
        echo -e "  Expected: debian-binary, control.tar.gz, data.tar.gz"
        echo -e "  Got: $(echo "$contents" | tr '\n' ', ')"
        exit 1
    fi
    echo -e "  ${GREEN}+${NC} $pkg_label: IPK structure verified"
}

# Banner
echo ""
echo -e "${GREEN}=======================================================${NC}"
echo -e "${GREEN}   Mergen - IPK Package Builder${NC}"
echo -e "${GREEN}=======================================================${NC}"
echo ""
echo -e "${BLUE}Version:${NC}       $FULL_VERSION"
echo -e "${BLUE}Architecture:${NC}  $PKG_ARCH"
echo -e "${BLUE}Build:${NC}         #$BUILD_NUM (git commit count)"
echo -e "${BLUE}License:${NC}       $PKG_LICENSE"
echo ""

# =============================================================================
# [1/7] Clean previous build
# =============================================================================
echo -e "${YELLOW}[1/7]${NC} Cleaning previous build..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
echo -e "  ${GREEN}+${NC} dist/ directory ready"

# =============================================================================
# [2/7] Build mergen package
# =============================================================================
echo -e "${YELLOW}[2/7]${NC} Building mergen package..."

M_DATA="$BUILD_DIR/mergen/data"
M_CTRL="$BUILD_DIR/mergen/control"
M_PKG="$BUILD_DIR/mergen/pkg"
mkdir -p "$M_DATA" "$M_CTRL" "$M_PKG"

# Create directory structure
mkdir -p "$M_DATA/etc/config"
mkdir -p "$M_DATA/etc/init.d"
mkdir -p "$M_DATA/etc/hotplug.d/iface"
mkdir -p "$M_DATA/etc/mergen/providers"
mkdir -p "$M_DATA/etc/mergen/rules.d"
mkdir -p "$M_DATA/usr/bin"
mkdir -p "$M_DATA/usr/sbin"
mkdir -p "$M_DATA/usr/lib/mergen"

# Install files with correct permissions (matching Makefile INSTALL_BIN/INSTALL_DATA)
# 644: config file
install -m 644 "$MERGEN_DIR/files/etc/config/mergen"               "$M_DATA/etc/config/mergen"
# 755: init script
install -m 755 "$MERGEN_DIR/files/etc/init.d/mergen"               "$M_DATA/etc/init.d/mergen"
# 644: hotplug handler
install -m 644 "$MERGEN_DIR/files/etc/hotplug.d/iface/50-mergen"   "$M_DATA/etc/hotplug.d/iface/50-mergen"
# 755: main CLI
install -m 755 "$MERGEN_DIR/files/usr/bin/mergen"                  "$M_DATA/usr/bin/mergen"
# 755: watchdog daemon
install -m 755 "$MERGEN_DIR/files/usr/sbin/mergen-watchdog"        "$M_DATA/usr/sbin/mergen-watchdog"
# 644: library modules (sourced, not executed)
install -m 644 "$MERGEN_DIR/files/usr/lib/mergen/core.sh"          "$M_DATA/usr/lib/mergen/core.sh"
install -m 644 "$MERGEN_DIR/files/usr/lib/mergen/resolver.sh"      "$M_DATA/usr/lib/mergen/resolver.sh"
install -m 644 "$MERGEN_DIR/files/usr/lib/mergen/engine.sh"        "$M_DATA/usr/lib/mergen/engine.sh"
install -m 644 "$MERGEN_DIR/files/usr/lib/mergen/route.sh"         "$M_DATA/usr/lib/mergen/route.sh"
install -m 644 "$MERGEN_DIR/files/usr/lib/mergen/utils.sh"         "$M_DATA/usr/lib/mergen/utils.sh"
# 755: migration script (executed by postinst)
install -m 755 "$MERGEN_DIR/files/usr/lib/mergen/migrate.sh"       "$M_DATA/usr/lib/mergen/migrate.sh"

# Provider scripts (not in Makefile install section, but needed at runtime)
install -m 755 "$MERGEN_DIR/files/etc/mergen/providers/bgptools.sh"   "$M_DATA/etc/mergen/providers/bgptools.sh"
install -m 755 "$MERGEN_DIR/files/etc/mergen/providers/bgpview.sh"    "$M_DATA/etc/mergen/providers/bgpview.sh"
install -m 755 "$MERGEN_DIR/files/etc/mergen/providers/irr.sh"        "$M_DATA/etc/mergen/providers/irr.sh"
install -m 755 "$MERGEN_DIR/files/etc/mergen/providers/maxmind.sh"    "$M_DATA/etc/mergen/providers/maxmind.sh"
install -m 644 "$MERGEN_DIR/files/etc/mergen/providers/ripe.sh"       "$M_DATA/etc/mergen/providers/ripe.sh"
install -m 755 "$MERGEN_DIR/files/etc/mergen/providers/routeviews.sh" "$M_DATA/etc/mergen/providers/routeviews.sh"

M_FILE_COUNT=$(find "$M_DATA" -type f | wc -l | tr -d ' ')
echo -e "  ${GREEN}+${NC} $M_FILE_COUNT files installed"

# =============================================================================
# [3/7] Build luci-app-mergen package
# =============================================================================
echo -e "${YELLOW}[3/7]${NC} Building luci-app-mergen package..."

L_DATA="$BUILD_DIR/luci/data"
L_CTRL="$BUILD_DIR/luci/control"
L_PKG="$BUILD_DIR/luci/pkg"
mkdir -p "$L_DATA" "$L_CTRL" "$L_PKG"

# Create directory structure
mkdir -p "$L_DATA/usr/lib/lua/luci/controller"
mkdir -p "$L_DATA/usr/lib/lua/luci/model/cbi"
mkdir -p "$L_DATA/usr/lib/lua/luci/view/mergen"
mkdir -p "$L_DATA/usr/lib/lua/luci/i18n"
mkdir -p "$L_DATA/www/luci-static/mergen"
mkdir -p "$L_DATA/usr/share/rpcd/acl.d"

# Controller
install -m 644 "$LUCI_DIR/luasrc/controller/mergen.lua" \
    "$L_DATA/usr/lib/lua/luci/controller/mergen.lua"

# CBI Models
for model in mergen-advanced mergen-providers mergen-rules; do
    install -m 644 "$LUCI_DIR/luasrc/model/cbi/${model}.lua" \
        "$L_DATA/usr/lib/lua/luci/model/cbi/${model}.lua"
done

# View templates
for htm in "$LUCI_DIR/luasrc/view/mergen/"*.htm; do
    [ -f "$htm" ] || continue
    install -m 644 "$htm" "$L_DATA/usr/lib/lua/luci/view/mergen/$(basename "$htm")"
done

# Static resources
install -m 644 "$LUCI_DIR/htdocs/luci-static/mergen/mergen.css" \
    "$L_DATA/www/luci-static/mergen/mergen.css"
install -m 644 "$LUCI_DIR/htdocs/luci-static/mergen/mergen.js" \
    "$L_DATA/www/luci-static/mergen/mergen.js"

# RPCD ACL
install -m 644 "$LUCI_DIR/root/usr/share/rpcd/acl.d/luci-app-mergen.json" \
    "$L_DATA/usr/share/rpcd/acl.d/luci-app-mergen.json"

# i18n: compile .po to .lmo if po2lmo is available
I18N_COUNT=0
if command -v po2lmo >/dev/null 2>&1; then
    for po_file in "$LUCI_DIR/po"/*/mergen.po; do
        [ -f "$po_file" ] || continue
        LANG_CODE=$(basename "$(dirname "$po_file")")
        LMO_FILE="$L_DATA/usr/lib/lua/luci/i18n/mergen.${LANG_CODE}.lmo"
        if po2lmo "$po_file" "$LMO_FILE" 2>/dev/null; then
            I18N_COUNT=$((I18N_COUNT + 1))
        else
            echo -e "    ${YELLOW}!${NC} Failed to compile: $(basename "$po_file")"
        fi
    done
    if [ $I18N_COUNT -gt 0 ]; then
        echo -e "  ${GREEN}+${NC} Compiled $I18N_COUNT translation(s)"
    fi
else
    echo -e "  ${YELLOW}!${NC} po2lmo not found, skipping i18n compilation"
    echo -e "  ${BLUE}i${NC} Install luci-base on build system for po2lmo"
    # Remove empty i18n directory
    rmdir "$L_DATA/usr/lib/lua/luci/i18n" 2>/dev/null || true
fi

L_FILE_COUNT=$(find "$L_DATA" -type f | wc -l | tr -d ' ')
echo -e "  ${GREEN}+${NC} $L_FILE_COUNT files installed"

# =============================================================================
# [4/7] Verify line endings
# =============================================================================
echo -e "${YELLOW}[4/7]${NC} Verifying file formats..."
CRLF_FIXED=0
for data_root in "$M_DATA" "$L_DATA"; do
    while IFS= read -r -d '' f; do
        if file "$f" 2>/dev/null | grep -q "CRLF"; then
            sed_inplace 's/\r$//' "$f"
            CRLF_FIXED=$((CRLF_FIXED + 1))
        fi
    done < <(find "$data_root" -type f \( \
        -name "*.sh" -o -name "*.lua" -o -name "*.htm" \
        -o -name "*.css" -o -name "*.js" -o -name "*.json" \
        -o -path "*/usr/bin/*" -o -path "*/usr/sbin/*" \
        -o -path "*/init.d/*" -o -path "*/hotplug.d/*" \) -print0)
done
if [ $CRLF_FIXED -gt 0 ]; then
    echo -e "  ${YELLOW}!${NC} Fixed $CRLF_FIXED file(s) with Windows line endings"
else
    echo -e "  ${GREEN}+${NC} All text files have Unix line endings"
fi

# =============================================================================
# [5/7] Create IPK archives
# =============================================================================
echo -e "${YELLOW}[5/7]${NC} Creating IPK archives..."

# --- mergen IPK ---
echo -e "  Building mergen_${FULL_VERSION}_${PKG_ARCH}.ipk..."

# control file
cat > "$M_CTRL/control" << EOF
Package: mergen
Version: $FULL_VERSION
Depends: ip-full, curl, jsonfilter
Section: net
Architecture: $PKG_ARCH
Installed-Size: $(get_installed_size "$M_DATA")
Maintainer: $PKG_MAINTAINER
Description: ASN/IP based policy routing daemon for OpenWrt
 Mergen is a policy routing daemon for OpenWrt that automatically resolves
 ASN prefix lists and creates ip rule/route entries. Supports nftables sets
 for performant packet matching with ipset fallback for older systems.
EOF

# conffiles
cat > "$M_CTRL/conffiles" << EOF
/etc/config/mergen
EOF

# postinst (faithful reproduction from Makefile lines 31-38)
cat > "$M_CTRL/postinst" << 'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
# Run config migration on upgrade
if [ -x /usr/lib/mergen/migrate.sh ]; then
    /usr/lib/mergen/migrate.sh || true
fi
EOF
chmod 755 "$M_CTRL/postinst"

# Create archives
echo "2.0" > "$M_PKG/debian-binary"
tar -C "$M_CTRL" -czf "$M_PKG/control.tar.gz" $TAR_OWNER_FLAGS .
tar -C "$M_DATA" -czf "$M_PKG/data.tar.gz" $TAR_OWNER_FLAGS .

# Assemble IPK (order is critical: debian-binary, control.tar.gz, data.tar.gz)
MERGEN_IPK="$DIST_DIR/mergen_${FULL_VERSION}_${PKG_ARCH}.ipk"
(cd "$M_PKG" && tar -czf "$MERGEN_IPK" $TAR_OWNER_FLAGS debian-binary control.tar.gz data.tar.gz)

# --- luci-app-mergen IPK ---
echo -e "  Building luci-app-mergen_${FULL_VERSION}_${PKG_ARCH}.ipk..."

# control file
cat > "$L_CTRL/control" << EOF
Package: luci-app-mergen
Version: $FULL_VERSION
Depends: mergen, luci-base
Section: luci
Architecture: $PKG_ARCH
Installed-Size: $(get_installed_size "$L_DATA")
Maintainer: $PKG_MAINTAINER
Description: LuCI interface for Mergen ASN/IP policy routing
 Web interface for managing Mergen ASN/IP based policy routing rules,
 provider configuration and system status monitoring.
EOF

# postinst
cat > "$L_CTRL/postinst" << 'EOF'
#!/bin/sh
[ -d /tmp/luci-modulecache ] && rm -rf /tmp/luci-modulecache/* 2>/dev/null
[ -d /tmp/luci-indexcache ] && rm -rf /tmp/luci-indexcache/* 2>/dev/null
exit 0
EOF
chmod 755 "$L_CTRL/postinst"

# prerm
cat > "$L_CTRL/prerm" << 'EOF'
#!/bin/sh
[ -d /tmp/luci-modulecache ] && rm -rf /tmp/luci-modulecache/* 2>/dev/null
[ -d /tmp/luci-indexcache ] && rm -rf /tmp/luci-indexcache/* 2>/dev/null
exit 0
EOF
chmod 755 "$L_CTRL/prerm"

# Create archives
echo "2.0" > "$L_PKG/debian-binary"
tar -C "$L_CTRL" -czf "$L_PKG/control.tar.gz" $TAR_OWNER_FLAGS .
tar -C "$L_DATA" -czf "$L_PKG/data.tar.gz" $TAR_OWNER_FLAGS .

# Assemble IPK
LUCI_IPK="$DIST_DIR/luci-app-mergen_${FULL_VERSION}_${PKG_ARCH}.ipk"
(cd "$L_PKG" && tar -czf "$LUCI_IPK" $TAR_OWNER_FLAGS debian-binary control.tar.gz data.tar.gz)

echo -e "  ${GREEN}+${NC} Both IPK archives created"

# =============================================================================
# [6/7] Verify IPK structures
# =============================================================================
echo -e "${YELLOW}[6/7]${NC} Verifying IPK structures..."
verify_ipk "$MERGEN_IPK" "mergen"
verify_ipk "$LUCI_IPK" "luci-app-mergen"

# =============================================================================
# [7/7] Build summary
# =============================================================================
echo ""
echo -e "${GREEN}=======================================================${NC}"
echo -e "${GREEN}   BUILD SUCCESSFUL${NC}"
echo -e "${GREEN}=======================================================${NC}"
echo ""
echo -e "${BLUE}mergen${NC} (daemon)"
echo -e "  File:     $(basename "$MERGEN_IPK")"
echo -e "  Size:     $(du -h "$MERGEN_IPK" | cut -f1 | tr -d ' ')"
echo -e "  Files:    $M_FILE_COUNT"
echo -e "  Depends:  ip-full, curl, jsonfilter"
echo ""
echo -e "${BLUE}luci-app-mergen${NC} (web UI)"
echo -e "  File:     $(basename "$LUCI_IPK")"
echo -e "  Size:     $(du -h "$LUCI_IPK" | cut -f1 | tr -d ' ')"
echo -e "  Files:    $L_FILE_COUNT"
echo -e "  Depends:  mergen, luci-base"
if [ $I18N_COUNT -gt 0 ]; then
    echo -e "  i18n:     $I18N_COUNT language(s) compiled"
else
    echo -e "  i18n:     skipped (po2lmo not available)"
fi
echo ""
echo -e "${BLUE}Output:${NC}     $DIST_DIR/"
echo ""
echo -e "${BLUE}Installation:${NC}"
echo -e "  scp dist/*.ipk root@<router>:/tmp/"
echo -e "  ssh root@<router> 'opkg install /tmp/mergen_*.ipk /tmp/luci-app-mergen_*.ipk'"
echo ""
echo -e "${GREEN}=======================================================${NC}"
