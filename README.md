# apk-builder

从模板生成一个 LuCI 应用的 **OpenWrt apk 包**（`.apk`，apk-tools v3 / ADB 格式），适用于 OpenWrt 25.x+ / snapshot（已从 opkg 迁到 apk）。

原项目 `ipk-builder` 产出的是 `.ipk`（opkg 格式）。本项目把打包环节换成 `apk mkpkg`，其余模板（LuCI 菜单 / Web 页面 / init 脚本 / ucode RPC）完全复用。

## 打包规范来源

`/` 下的打包逻辑**逐项对照 OpenWrt 官方真实包 `luci-theme-argon-3.1.4-r1.apk` 反推**，用静态 apk-tools 3.0.9 的 `adbdump` 解析其 ADB 结构得到。关键规范：

| 项目 | 官方真实包的做法 | 本项目 |
|---|---|---|
| 容器格式 | ADB (SCHEMA `676B6370`, `ADBd` magic) | `apk mkpkg` 生成，一致 |
| 元数据 | `name/version/description/arch/license/origin/maintainer/url/installed-size/depends/provides/hashes` | 全部对齐；`installed-size`/`hashes` 由 mkpkg 自动算 |
| 架构 | `arch: noarch`（架构无关包） | `noarch` |
| provides | `<name>-any` | `<name>-any` |
| 维护脚本 | 5 个：`pre-install` `post-install` `pre-deinstall` `pre-upgrade` `post-upgrade` | 5 个全部生成 |
| 脚本封装 | `default_postinst` / `default_prerm` / `add_group_and_user`，`${IPKG_INSTROOT}`、`PKG_UPGRADE=1` | 一致 |
| conffiles | `/lib/apk/packages/<name>.conffiles` + `.conffiles_static`(带 sha256) + `.list`(文件清单) | 三件套全部生成 |
| 脚本内容 | post-install 末尾清 `/tmp/luci-indexcache.*` `/tmp/luci-modulecache/` 并 `rpcd reload` | 一致 |

已在本机 + 真实路由器（NN6000 v2，OpenWrt snapshot，apk 3.0.5）端到端验证：`build.sh` → `apk mkpkg` → `apk add --allow-untrusted` → 文件落地 → conffiles 记录 → `apk del` 清理，全流程通过。

## 目录结构

```
.
├── scripts/
│   ├── build.sh          # 主流程：渲染模板 → 生成 conffiles → apk mkpkg
│   ├── gen_vars.py       # 从 INPUT_* 环境变量生成模板替换字典
│   └── render.py         # 占位符替换
├── templates/
│   ├── init.d.sh         # procd init 脚本
│   ├── uci-defaults.sh   # UCI 默认配置
│   ├── menu.json         # LuCI 菜单
│   ├── acl.json          # rpcd ACL
│   ├── ucode.uc          # ubus RPC
│   ├── main.js / log.js  # LuCI Web 页面
│   ├── apk-post-install.sh
│   ├── apk-post-upgrade.sh
│   └── apk-pre-deinstall.sh
├── tools/
│   ├── apk.static.aarch64  # 静态 apk-tools 3.0.9 (aarch64, musl)，可离线打包
│   └── apk-static.apk      # 上述二进制的原始 Alpine 包
└── .github/workflows/build.yml
```

## 使用方法

### GitHub Actions（推荐）

在仓库 Settings → Secrets and variables → Actions → Variables 里不用配，直接在 Actions 页点 **Run workflow** 填参数。CI 在 `alpine:3.23` 容器里跑（自带完整 apk 含 `mkpkg`，musl 与 OpenWrt 一致），产出 `.apk` 作为 artifact 下载。

### 本地（Linux / WSL，需装 apk-tools 3.x）

```sh
export INPUT_PACKAGE_NAME="luci-app-myapp"
export INPUT_SERVICE_TITLE="My App"
export INPUT_VERSION="1.0-r0"
export INPUT_DESCRIPTION="My application"
export INPUT_BINARY="/usr/bin/myapp"
export INPUT_HAS_WEB="true"
export APK_BIN="apk"                    # 你本机的 apk (需含 mkpkg)
export GITHUB_WORKSPACE="$(pwd)"
bash scripts/build.sh
```

### 离线在 OpenWrt 路由器上打包

路由器自带的 apk 是精简版，没有 `mkpkg`。把 `tools/apk.static.aarch64` 传上去即可：

```sh
scp tools/apk.static.aarch64 root@192.168.1.1:/tmp/apk.static
ssh root@192.168.1.1 'chmod +x /tmp/apk.static && apk add python3'
# 上传 scripts/ templates/ 到 /tmp/apkbuild/ 后按本地方式运行，APK_BIN=/tmp/apk.static
```

## 安装到设备

自签包需要 `--allow-untrusted`：

```sh
scp luci-app-myapp-1.0-r0.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'apk add --allow-untrusted /tmp/luci-app-myapp-1.0-r0.apk'
```

## 参数说明

| 参数 | 说明 |
|---|---|
| `package_name` | 包名，须以 `luci-app-` 开头（`#` 后的部分作为 service_name） |
| `service_title` | LuCI 菜单显示标题 |
| `version` | apk 版本语法：`(数字.)*(下划线)*(-r<数字>)`，如 `1.0-r0`、`0.0.0_git1234-r0`。**不能带 `v` 前缀** |
| `has_web` | 是否生成 LuCI Web 页面 |
| `web_entry` | Web 入口，纯数字=端口，`端口/路径`=带路径 |
| `extra_options` | 额外配置项，格式 `变量:默认值:标签`，空格分隔 |
| `run_user` / `run_group` | procd 运行用户/组；留空则不设置 |

## 注意事项

- **架构名**：LuCI/脚本包用 `noarch`；带二进制的包要填 OpenWrt 架构名（如 `aarch64_cortex-a53`），不能用通用的 `aarch64`。
- **版本语法严格**：`v1.2.3` 会被 apk 拒绝，必须 `1.2.3-r0`。
- **升级脚本独立**：apk 升级跑 `pre-upgrade`/`post-upgrade`，不复用 `post-install`；opkg `postinst` 里靠 `$1` 判断升级的写法要改成 `PKG_UPGRADE=1`。
- **二进制需另行提供**：本生成器只产出壳（配置/菜单/Web/init），真正的可执行二进制由用户自己放进 rootfs 或另一个包。
