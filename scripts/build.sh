#!/bin/bash
# build.sh - 从模板生成 luci-app-xx 的 APK 安装包 (OpenWrt 25.x+ / apk-tools v3)
# 参考 OpenWrt 官方 include/package-pack.mk 的 apk 打包规则。
# 所有参数通过环境变量传入（由 workflow 设置）。

set -e

PKG_NAME="${INPUT_PACKAGE_NAME}"
SERVICE_TITLE="${INPUT_SERVICE_TITLE}"
VERSION="${INPUT_VERSION}"
DESCRIPTION="${INPUT_DESCRIPTION}"
BINARY="${INPUT_BINARY}"
START_ARGS="${INPUT_START_ARGS}"
HAS_WEB="${INPUT_HAS_WEB}"
WEB_ENTRY="${INPUT_WEB_ENTRY}"
EXTRA_OPTIONS="${INPUT_EXTRA_OPTIONS}"

SERVICE_NAME="${PKG_NAME#luci-app-}"
BINARY_NAME="$(basename "${BINARY}")"

TEMPLATES_DIR="$(dirname "$0")/../templates"
BUILD_DIR="/tmp/luci_build_${PKG_NAME}"
VARS_JSON="${BUILD_DIR}/vars.json"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo ">>> Building ${PKG_NAME} ${VERSION} (.apk)"
echo "    service_name : ${SERVICE_NAME}"
echo "    binary_name  : ${BINARY_NAME}"
echo "    has_web      : ${HAS_WEB}"
echo "    web_entry    : ${WEB_ENTRY:-3001}"
echo "    extra_options: ${EXTRA_OPTIONS}"

# ── 版本语法校验 ──────────────────────────────────────────
# apk-tools 版本语法: (.)*(_*)*(-r<数字>)  例: 1.0-r1, 0.0.0_git1234-r0
if ! printf '%s' "${VERSION}" | grep -Eq '^[0-9][0-9A-Za-z._]*(-r[0-9]+)?$'; then
    echo "ERROR: invalid apk version '${VERSION}'. Use format like 1.0-r1 or 0.0.0_git1234-r0" >&2
    exit 1
fi

# ── 用 Python 生成所有替换内容，输出到 JSON 文件 ──────────
export INPUT_PACKAGE_NAME INPUT_SERVICE_TITLE INPUT_VERSION INPUT_DESCRIPTION
export INPUT_BINARY INPUT_START_ARGS INPUT_HAS_WEB INPUT_WEB_ENTRY INPUT_WORK_DIR INPUT_ENV_VARS INPUT_EXTRA_OPTIONS

python3 "$(dirname "$0")/gen_vars.py" "${VARS_JSON}"
echo "    vars.json written"

render_template() {
    python3 "$(dirname "$0")/render.py" "$1" "$2" "${VARS_JSON}"
}

SERVICE_NAME=$(python3 -c "import json; print(json.load(open('${VARS_JSON}'))['{{SERVICE_NAME}}'])")

# ── 创建 apk --files 安装树（等价于 OpenWrt 的 IDIR）──────
PKG_DATA="${BUILD_DIR}/data"
SCRIPTS_DIR="${BUILD_DIR}/scripts"

mkdir -p "${PKG_DATA}/etc/config" \
         "${PKG_DATA}/etc/init.d" \
         "${PKG_DATA}/etc/uci-defaults" \
         "${PKG_DATA}/usr/share/luci/menu.d" \
         "${PKG_DATA}/usr/share/rpcd/acl.d" \
         "${PKG_DATA}/usr/share/rpcd/ucode" \
         "${PKG_DATA}/www/luci-static/resources/view/${SERVICE_NAME}" \
         "${PKG_DATA}/lib/apk/packages" \
         "${SCRIPTS_DIR}"

python3 -c "
import json
d = json.load(open('${VARS_JSON}'))
with open('${PKG_DATA}/etc/config/${SERVICE_NAME}', 'w') as f:
    f.write(d['{{UCI_DEFAULTS}}'])
"

render_template "${TEMPLATES_DIR}/init.d.sh"        "${PKG_DATA}/etc/init.d/${SERVICE_NAME}"
render_template "${TEMPLATES_DIR}/uci-defaults.sh"  "${PKG_DATA}/etc/uci-defaults/${PKG_NAME}"
render_template "${TEMPLATES_DIR}/menu.json"        "${PKG_DATA}/usr/share/luci/menu.d/${PKG_NAME}.json"
render_template "${TEMPLATES_DIR}/acl.json"         "${PKG_DATA}/usr/share/rpcd/acl.d/${PKG_NAME}.json"
render_template "${TEMPLATES_DIR}/ucode.uc"         "${PKG_DATA}/usr/share/rpcd/ucode/luci.${SERVICE_NAME}"
render_template "${TEMPLATES_DIR}/main.js"          "${PKG_DATA}/www/luci-static/resources/view/${SERVICE_NAME}/main.js"
render_template "${TEMPLATES_DIR}/log.js"           "${PKG_DATA}/www/luci-static/resources/view/${SERVICE_NAME}/log.js"

# ── conffiles 三件套 (对齐 OpenWrt 官方 apk 包结构) ────────
# 真实包 (如 luci-theme-argon) 在 /lib/apk/packages/ 下放三个文件:
#   <name>.conffiles        : 每行一个配置文件路径
#   <name>.conffiles_static : 每行 "<路径> <sha256>"，升级时比对是否用户改过
#   <name>.list             : 本包安装的全部文件清单
# 这样 apk 升级时才能正确保留用户修改过的配置。
CONFFILE="/etc/config/${SERVICE_NAME}"
CFG_PATH="${PKG_DATA}${CONFFILE}"
printf '%s\n' "${CONFFILE}" > "${PKG_DATA}/lib/apk/packages/${PKG_NAME}.conffiles"
# .conffiles_static 用打包时刻该配置文件的 sha256（与 FIT 内 data 的 hash 一致）
CFG_SHA256=$(sha256sum "${CFG_PATH}" | awk '{print $1}')
printf '%s %s\n' "${CONFFILE}" "${CFG_SHA256}" > "${PKG_DATA}/lib/apk/packages/${PKG_NAME}.conffiles_static"

# .list: 包内全部安装文件清单。在 mkpkg 之前生成，find 时排除 lib/apk/packages
# 自身，再显式把三个元数据文件补进去（对齐官方 argon 包）。
LIST_FILE="${PKG_DATA}/lib/apk/packages/${PKG_NAME}.list"
( cd "${PKG_DATA}" && find . -type f -o -type l | sed 's|^\./|/|' | grep -v '^/lib/apk/packages/' | sort ) > "${LIST_FILE}"
for meta in conffiles conffiles_static list; do
    echo "/lib/apk/packages/${PKG_NAME}.${meta}" >> "${LIST_FILE}"
done
sort -o "${LIST_FILE}" "${LIST_FILE}"

# ── apk maintainer scripts ────────────────────────────────
# 按 OpenWrt 官方规则生成 5 个脚本；真实 argon 包就是这 5 个:
#   pre-install / post-install / pre-deinstall / pre-upgrade / post-upgrade
# 脚本里用 ${IPKG_INSTROOT} / default_postinst / default_prerm 等 OpenWrt 封装。
# 这些脚本通过 --script 传入，不属于 --files 安装树。
render_template "${TEMPLATES_DIR}/apk-post-install.sh"   "${SCRIPTS_DIR}/post-install"
render_template "${TEMPLATES_DIR}/apk-post-upgrade.sh"   "${SCRIPTS_DIR}/post-upgrade"
render_template "${TEMPLATES_DIR}/apk-pre-deinstall.sh"  "${SCRIPTS_DIR}/pre-deinstall"
# pre-install / pre-upgrade 用于配置迁移；默认生成空操作版本
cat > "${SCRIPTS_DIR}/pre-install" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "${SCRIPTS_DIR}/pre-upgrade" <<'EOF'
#!/bin/sh
export PKG_UPGRADE=1
exit 0
EOF
chmod 755 "${SCRIPTS_DIR}/pre-install" "${SCRIPTS_DIR}/pre-upgrade"

# ── 权限 ──────────────────────────────────────────────────
find "${PKG_DATA}" -type f -exec chmod 644 {} +
find "${PKG_DATA}" -type d -exec chmod 755 {} +
chmod 755 \
    "${PKG_DATA}/etc/init.d/${SERVICE_NAME}" \
    "${PKG_DATA}/etc/uci-defaults/${PKG_NAME}" \
    "${PKG_DATA}/usr/share/rpcd/ucode/luci.${SERVICE_NAME}" \
    "${SCRIPTS_DIR}/post-install" \
    "${SCRIPTS_DIR}/post-upgrade" \
    "${SCRIPTS_DIR}/pre-deinstall" \
    "${SCRIPTS_DIR}/pre-install" \
    "${SCRIPTS_DIR}/pre-upgrade"

# ── 用 apk mkpkg 打包 ─────────────────────────────────────
# APK_BIN 可覆盖，便于指定本机编译的 apk-tools v3
APK_BIN="${APK_BIN:-apk}"
if ! command -v "${APK_BIN}" >/dev/null 2>&1; then
    echo "ERROR: apk-tools not found (looked for '${APK_BIN}'). Need apk with mkpkg applet." >&2
    exit 1
fi

# 纯脚本/LuCI 包与架构无关 -> noarch (OpenWrt 官方对 all 包的映射)
# 依赖: luci-base (脚本界面所需); 二进制需用户另行安装，不在本包依赖里强制。
DEPENDS="${INPUT_DEPENDS:-luci-base}"

APK_NAME="${PKG_NAME}-${VERSION}.apk"
OUTPUT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
OUTPUT_APK="${OUTPUT_DIR}/${APK_NAME}"
echo ">>> apk mkpkg -> ${APK_NAME}"

# provides: OpenWrt 对每个包生成 <name>-any 虚拟提供项（对齐官方 argon 包）
# installed-size / hashes 由 apk mkpkg 自动计算，无需手动传。
"${APK_BIN}" mkpkg \
    --info "name:${PKG_NAME}" \
    --info "version:${VERSION}" \
    --info "description:${DESCRIPTION}" \
    --info "arch:noarch" \
    --info "license:GPL-2.0-only" \
    --info "origin:${PKG_NAME}" \
    --info "url:https://github.com/${GITHUB_REPOSITORY:-local}" \
    --info "maintainer:apk-builder" \
    --info "depends:${DEPENDS}" \
    --info "provides:${PKG_NAME}-any" \
    --script "pre-install:${SCRIPTS_DIR}/pre-install" \
    --script "post-install:${SCRIPTS_DIR}/post-install" \
    --script "pre-deinstall:${SCRIPTS_DIR}/pre-deinstall" \
    --script "pre-upgrade:${SCRIPTS_DIR}/pre-upgrade" \
    --script "post-upgrade:${SCRIPTS_DIR}/post-upgrade" \
    --files "${PKG_DATA}" \
    --output "${OUTPUT_APK}"

echo ">>> Built: ${APK_NAME}"
echo "apk_name=${APK_NAME}" >> "${GITHUB_OUTPUT:-/dev/null}"
