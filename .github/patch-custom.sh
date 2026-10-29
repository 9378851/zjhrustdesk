#!/usr/bin/env bash
# ============================================================
# 维巧远程 定制补丁（全平台通用：Windows / macOS / iOS / Android）
# 作用：注入信令服务器、中继 Key、应用名「维巧远程」，并隐藏两处官方提示
# 特性：幂等（重复执行无副作用）；自动适配 GNU sed（Linux）与 BSD sed（macOS）
# 用法：在任意 job 的 steps 中加  - run: bash .github/patch-custom.sh
# ============================================================
set -euo pipefail

# 切到仓库根目录（本脚本位于 .github/ 下）
cd "$(dirname "$0")/.."

# 兼容 GNU sed（Linux runner）与 BSD sed（macOS runner）
sedi() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

CONFIG=libs/hbb_common/src/config.rs
COMMON=flutter/lib/common.dart
CONN=flutter/lib/desktop/pages/connection_page.dart
PLATFORM=src/platform/mod.rs

# 1) 信令/中继服务器
sedi 's#^pub const RENDEZVOUS_SERVERS.*#pub const RENDEZVOUS_SERVERS: \&[\&str] = \&["zjhrust.wt20.top"];#' "$CONFIG"

# 2) 公钥（客户端 Key）
sedi 's#^pub const RS_PUB_KEY.*#pub const RS_PUB_KEY: \&str = "67sVkolrsBGx3DgXZRcmDGKIQLNaPNIpTW2gbFHEZEA=";#' "$CONFIG"

# 3) 应用名（同时决定安装目录/服务名）
sedi 's#RwLock::new("RustDesk".to_owned())#RwLock::new("维巧远程".to_owned())#' "$CONFIG"

# 3b) 让客户端自动推导 API 服务器 = http://<域名>:21114
#     默认 PROD_RENDEZVOUS_SERVER 是空串（config.rs L70），会导致
#     登录/通讯录请求兜底打到官方 https://admin.rustdesk.com，用自建账号必然登不上
sedi '/pub static ref PROD_RENDEZVOUS_SERVER/ s#RwLock::new("".to_owned())#RwLock::new("zjhrust.wt20.top".to_owned())#' "$CONFIG"

# 4) 放行中文应用名（官方限制安装名只能含 ASCII 字母，中文会报错）
#    两行都要短路：条件跨两行，且 Rust 中 && 优先级高于 ||
sedi 's#^    if !valid_first#    if false \&\& !valid_first#' "$PLATFORM"
sedi "s#^        || !bytes.all.*#        || false#" "$PLATFORM"

# 4b) 修复上游安装器缺陷：install_me 首次安装缺 exe 改名步骤
#     （XCOPY 复制来的是 rustdesk.exe，而快捷方式/服务指向 {APP_NAME}.exe）
#     把 install_me 参数列表中的 copy_exe 拼接上 rename_exe_cmd（只替换第一处，即 install_me）
#     GNU sed 用 0,/re/ 地址；BSD sed（mac/iOS）不支持该语法但不编译 windows.rs，跳过即可
sed -i '0,/copy_exe = copy_exe_cmd/s#^        copy_exe = copy_exe_cmd(\&src_exe, \&exe, \&path)?,#copy_exe = format!("{}{}", copy_exe_cmd(\&src_exe, \&exe, \&path)?, rename_exe_cmd(\&src_exe, \&path)?),#' src/platform/windows.rs || echo 'WARN: windows.rs rename 补丁跳过（仅 Windows 构建需要）'

# 5) 隐藏「由 RustDesk 提供支持」
sedi 's#if (bind.mainGetBuildinOption(key: .hide-powered-by-me.) == .Y.) {#if (true) {#' "$COMMON"

# 6) 隐藏底部「…你可以选择自建服务器」提示
sedi 's#final _svcIsUsingPublicServer = true.obs;#final _svcIsUsingPublicServer = false.obs;#' "$CONN"
sedi 's#_svcIsUsingPublicServer.value = await bind.mainIsUsingPublicServer();#_svcIsUsingPublicServer.value = false;#' "$CONN"

# ============================================================
# 校验：输出注入结果，任何一项没命中都让构建失败
# ============================================================
echo '----- config.rs (服务器 / Key / 应用名) -----'
grep -nE 'RENDEZVOUS_SERVERS|RS_PUB_KEY|APP_NAME|PROD_RENDEZVOUS_SERVER' "$CONFIG"

echo '----- 隐藏官方提示（common.dart 应出现 if (true)）-----'
grep -n 'if (true) {' "$COMMON" || echo 'WARN: 未找到 if (true)，hide-powered-by-me 补丁可能未命中（不中断构建）'

echo '----- 隐藏底部自建服务器提示 -----'
grep -nE '_svcIsUsingPublicServer' "$CONN"

echo '----- 放行中文应用名 -----'
grep -n 'if false' "$PLATFORM"

# 强校验：核心三项必须命中，否则中断构建（避免产出连不上服务器的包）
grep -q 'zjhrust.wt20.top' "$CONFIG" || { echo 'ERROR: 服务器注入失败'; exit 1; }
grep -q '67sVkolrsBGx3DgXZRcmDGKIQLNaPNIpTW2gbFHEZEA=' "$CONFIG" || { echo 'ERROR: Key 注入失败'; exit 1; }
grep -q '维巧远程' "$CONFIG" || { echo 'ERROR: 应用名注入失败'; exit 1; }
grep -q 'PROD_RENDEZVOUS_SERVER: RwLock<String> = RwLock::new("zjhrust.wt20.top"' "$CONFIG" || { echo 'ERROR: API 自动推导(PROD_RENDEZVOUS_SERVER)注入失败'; exit 1; }

echo 'PATCH OK'
