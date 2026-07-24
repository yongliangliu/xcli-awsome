#!/usr/bin/env bash
#
# warp-cn-split-tunnel.sh
# 让「中国大陆 IP 段」跳过 Cloudflare WARP（Split Tunnel / Exclude 模式）。
#
# 适用：Cloudflare WARP 个人版(Consumer)，macOS，warp-cli 2026.x
# 原理：WARP 默认处于 Exclude 模式，列表内的 IP 段【不走】WARP，其余走 WARP。
#       本脚本把中国大陆 IP CIDR 段批量加入 Exclude 列表。
#
# 用法：
#   ./warp-cn-split-tunnel.sh add            # 导入中国 IP 段（默认在线下载列表）
#   ./warp-cn-split-tunnel.sh add --curated  # 只导入内置「主流网站/大厂」精简段（离线、条目少）
#   ./warp-cn-split-tunnel.sh add --file a.txt  # 从本地 CIDR 文件导入
#   ./warp-cn-split-tunnel.sh add --max 900  # 限制最多导入多少条（防止超上限）
#   ./warp-cn-split-tunnel.sh add --dry-run  # 只预览，不实际写入
#   ./warp-cn-split-tunnel.sh reset          # 移除本脚本(CLI)添加的所有 exclude 条目
#   ./warp-cn-split-tunnel.sh list           # 查看当前 exclude 列表
#   ./warp-cn-split-tunnel.sh status         # 查看模式/连接状态
#
set -euo pipefail

# ---- 可配置项 ----------------------------------------------------------------
# 在线中国 IP 段来源（任选其一，默认第一个）。均为社区维护的 CN CIDR 列表。
SRC_17MON="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
SRC_CHNROUTES2="https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt"
DEFAULT_URL="$SRC_CHNROUTES2"   # chnroutes2 已聚合，条目更少，更适合有路由数量上限的场景

# 内置「主流网站/大厂」精简 IPv4 段（离线可用，覆盖 BAT/字节/网易/京东/小米等常见 ASN 主段）。
# 注意：仅为常用主段，非完整覆盖；追求全量请用在线列表。
CURATED_RANGES=(
  # 阿里巴巴 / 淘宝 / 支付宝 / 阿里云
  "47.92.0.0/14" "47.96.0.0/11" "59.82.0.0/16" "106.11.0.0/16" "110.75.0.0/16"
  "115.124.16.0/20" "140.205.0.0/16" "203.119.128.0/17" "42.120.0.0/15"
  # 腾讯 / 微信 / QQ / 腾讯云
  "58.247.0.0/16" "101.226.0.0/16" "119.147.0.0/16" "140.207.0.0/16"
  "182.254.0.0/16" "183.60.0.0/16" "203.205.128.0/17" "129.28.0.0/16"
  # 百度
  "39.156.66.0/24" "110.242.68.0/24" "180.76.0.0/16" "220.181.0.0/16"
  # 字节跳动 / 抖音 / 今日头条
  "110.249.200.0/21" "111.206.0.0/16" "180.184.0.0/16" "45.112.0.0/16"
  # 网易
  "59.111.0.0/16" "220.181.28.0/22" "123.58.160.0/19"
  # 京东
  "111.13.0.0/16" "211.147.224.0/19" "106.39.0.0/16"
  # 小米
  "111.202.0.0/16" "58.68.128.0/17"
  # 新浪 / 微博
  "121.14.0.0/16" "123.125.0.0/16"
  # 搜狐 / 搜狗
  "123.126.0.0/16" "61.135.185.0/24"
  # 华为 / 华为云
  "114.115.0.0/16" "116.63.0.0/16" "119.3.0.0/16" "121.36.0.0/16"
  "122.9.0.0/16" "124.70.0.0/16" "139.9.0.0/16" "139.159.0.0/16" "159.138.0.0/16"
  # 百度云（额外段）
  "106.12.0.0/16" "182.61.0.0/16" "120.48.0.0/16"
  # 金山云 / WPS
  "120.92.0.0/16"
  # UCloud 云主机
  "106.75.0.0/16" "117.50.0.0/16"
  # 常用公共 DNS（可选）
  "114.114.114.114/32" "223.5.5.5/32" "223.6.6.6/32" "119.29.29.29/32"
  "180.76.76.76/32" "1.2.4.8/32" "210.2.4.8/32" "101.226.4.6/32" "123.125.81.6/32"
)

# ---- 内部函数 ----------------------------------------------------------------
err() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
info() { printf '\033[36m%s\033[0m\n' "$*"; }
ok()  { printf '\033[32m%s\033[0m\n' "$*"; }

require_warp() {
  command -v warp-cli >/dev/null 2>&1 || { err "未找到 warp-cli，请先安装 Cloudflare WARP。"; exit 1; }
}

ensure_exclude_mode() {
  # 确认处于 Exclude 模式；WARP 个人版默认即为 Exclude。若显示 include 则提示。
  if warp-cli settings 2>/dev/null | grep -qi "Include mode"; then
    err "当前为 Include 模式（只有列表内 IP 走 WARP），与本脚本目标相反。"
    err "请在 WARP 设置中切回默认 Exclude 模式后再运行。"
    exit 1
  fi
}

# 读取待导入 CIDR 列表到全局数组 RANGES
load_ranges() {
  local mode="$1" file="$2" url="$3"
  RANGES=()
  if [[ "$mode" == "curated" ]]; then
    RANGES=("${CURATED_RANGES[@]}")
    info "已加载内置精简列表：${#RANGES[@]} 条。"
    return
  fi
  if [[ -n "$file" ]]; then
    [[ -f "$file" ]] || { err "文件不存在：$file"; exit 1; }
    info "从本地文件读取：$file"
    while IFS= read -r line; do
      line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
      [[ -n "$line" ]] && RANGES+=("$line")
    done < "$file"
  else
    command -v curl >/dev/null 2>&1 || { err "需要 curl 下载列表，或改用 --curated / --file。"; exit 1; }
    info "在线下载中国 IP 段：$url"
    local tmp; tmp="$(mktemp)"
    curl -fsSL --connect-timeout 15 "$url" -o "$tmp" || { err "下载失败，请检查网络或改用 --curated / --file。"; exit 1; }
    while IFS= read -r line; do
      line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
      [[ -n "$line" ]] && RANGES+=("$line")
    done < "$tmp"
    rm -f "$tmp"
  fi
  info "共读取 ${#RANGES[@]} 条 CIDR。"
}

cmd_add() {
  local mode="full" file="" url="$DEFAULT_URL" max=0 dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --curated) mode="curated" ;;
      --file) file="${2:-}"; shift ;;
      --url) url="${2:-}"; shift ;;
      --max) max="${2:-0}"; shift ;;
      --dry-run) dry=1 ;;
      *) err "未知参数：$1"; exit 1 ;;
    esac
    shift
  done

  require_warp
  ensure_exclude_mode
  load_ranges "$mode" "$file" "$url"

  # 已存在的条目（幂等：跳过重复）
  local existing; existing="$(warp-cli tunnel ip list 2>/dev/null || true)"

  local added=0 skipped=0 failed=0 total=${#RANGES[@]} i=0
  for cidr in "${RANGES[@]}"; do
    i=$((i+1))
    [[ "$max" -gt 0 && "$added" -ge "$max" ]] && { info "已达 --max=$max 上限，停止导入。"; break; }
    # 基本 CIDR 校验
    if [[ ! "$cidr" =~ ^[0-9a-fA-F:.]+/[0-9]+$ ]]; then
      err "跳过无效 CIDR：$cidr"; failed=$((failed+1)); continue
    fi
    if grep -q -F " $cidr " <<<" $existing "; then
      skipped=$((skipped+1)); continue
    fi
    if [[ "$dry" -eq 1 ]]; then
      printf '[dry-run %d/%d] would add %s\n' "$i" "$total" "$cidr"; added=$((added+1)); continue
    fi
    if out="$(warp-cli tunnel ip add-range "$cidr" 2>&1)"; then
      added=$((added+1))
      printf '\r已导入 %d 条（跳过 %d，失败 %d）...' "$added" "$skipped" "$failed"
    else
      failed=$((failed+1))
      err ""
      err "添加失败 $cidr：$out"
      # 可能已达 WARP 路由数量上限
      if grep -qiE "limit|too many|maximum" <<<"$out"; then
        err "疑似已达 WARP 路由数量上限，停止。可用 --max 减少条目，或改用 --curated / chnroutes2 聚合列表。"
        break
      fi
    fi
  done
  echo
  ok "完成：新增 ${added}，跳过(已存在) ${skipped}，失败 ${failed}。"
  [[ "$dry" -eq 1 ]] && info "(dry-run 模式，未实际写入)"
}

cmd_reset() {
  require_warp
  info "移除本脚本(CLI)添加的 exclude 条目..."
  local n=0
  # 只删除标记为 (CLI exclude) 的条目，保留 WARP 默认段
  while IFS= read -r cidr; do
    [[ -z "$cidr" ]] && continue
    if warp-cli tunnel ip remove-range "$cidr" >/dev/null 2>&1; then
      n=$((n+1))
    fi
  done < <(warp-cli tunnel ip list 2>/dev/null | awk '/\(CLI exclude\)/{print $1}')
  ok "已移除 $n 条 CLI 添加的条目。"
  info "如需彻底恢复出厂默认，可运行：warp-cli tunnel ip reset"
}

cmd_list()   { require_warp; warp-cli tunnel ip list; }
cmd_status() { require_warp; warp-cli status; echo; warp-cli settings | grep -iE "mode|exclude|include" || true; }

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

# ---- 入口 --------------------------------------------------------------------
sub="${1:-}"; [[ $# -gt 0 ]] && shift || true
case "$sub" in
  add)    cmd_add "$@" ;;
  reset)  cmd_reset ;;
  list)   cmd_list ;;
  status) cmd_status ;;
  ""|-h|--help|help) usage ;;
  *) err "未知命令：$sub"; echo; usage; exit 1 ;;
esac
