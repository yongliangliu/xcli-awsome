#!/usr/bin/env bash
# gost 控制脚本 —— 管理带 UDP 的本地混合代理
# 供电视(SmartTube)/其他设备透传 QUIC 经 WARP 出网。用 launchd 常驻+开机自启。
set -uo pipefail

LABEL="com.user.gost"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG="/tmp/gost-10808.log"
DEFAULT_PORT=10808
GOST_BIN="$(command -v gost 2>/dev/null || echo /usr/local/bin/gost)"

ok(){ printf "\033[32m%s\033[0m\n" "$*"; }
err(){ printf "\033[31m%s\033[0m\n" "$*"; }
info(){ printf "\033[36m%s\033[0m\n" "$*"; }

usage(){
  cat <<EOF
用法: gost-ctl.sh <命令> [--port N]
  start     [--port N]  启动带 udp=true 的混合代理并注册开机自启(默认 ${DEFAULT_PORT})
  stop                  停止(本次会话);plist 仍在,登录后会再自启
  restart   [--port N]  重启
  status                查看运行状态/端口/PID/是否带 UDP
  install   [--port N]  写入并启用开机自启(launchd RunAtLoad),重启后自动恢复
  uninstall             取消开机自启并删除 plist(彻底不再自启)+ 停止
  logs                  跟踪日志(tail -f ${LOG})
EOF
}

CMD="${1:-}"; [ $# -gt 0 ] && shift
PORT="$DEFAULT_PORT"
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-$DEFAULT_PORT}"; shift 2;;
    *) shift;;
  esac
done

write_plist(){
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${GOST_BIN}</string>
        <string>-L=mixed://:${PORT}?udp=true</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
EOF
}

is_listening(){ lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; }

case "$CMD" in
  start)
    write_plist
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load -w "$PLIST" 2>/dev/null || true
    sleep 2
    if is_listening; then ok "gost 已启动: mixed://:${PORT}?udp=true (开机自启已开启)"; else err "启动失败, 看日志: $LOG"; fi
    ;;
  stop)
    launchctl unload "$PLIST" 2>/dev/null || true
    ok "gost 已停止, 开机自启已取消"
    ;;
  restart)
    write_plist
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load -w "$PLIST" 2>/dev/null || true
    sleep 2
    if is_listening; then ok "gost 已重启: mixed://:${PORT}?udp=true"; else err "重启失败, 看日志: $LOG"; fi
    ;;
  install)
    write_plist
    launchctl unload "$PLIST" 2>/dev/null || true
    if launchctl load -w "$PLIST" 2>/dev/null; then
      ok "开机自启已启用: mixed://:${PORT}?udp=true (launchd RunAtLoad)"
    else
      err "launchctl load 失败, 看日志: $LOG"
    fi
    sleep 2
    if is_listening; then ok "gost 运行中: 端口 ${PORT}"; else err "未监听, 看日志: $LOG"; fi
    info "自启配置: $PLIST"
    ;;
  uninstall)
    launchctl unload "$PLIST" 2>/dev/null || true
    if [ -f "$PLIST" ]; then
      rm -f "$PLIST" && ok "已删除自启配置 $PLIST (开机不再自启)"
    else
      info "自启配置不存在(本就未安装)"
    fi
    ok "gost 已停止且彻底取消开机自启"
    ;;
  status)
    if is_listening; then
      PID=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $2}')
      ok "运行中: mixed://:${PORT} (PID ${PID})"
    else
      err "未运行 (端口 ${PORT} 无监听)"
    fi
    if [ -f "$PLIST" ]; then
      if grep -q "udp=true" "$PLIST"; then info "UDP 转发: 已启用 (QUIC 可透传)"; else err "UDP 转发: 未启用! 请重新 start"; fi
      info "开机自启: 已安装 ($PLIST)"
    else
      info "开机自启: 未安装 (运行 start 或 install 生成)"
    fi
    ;;
  logs)
    tail -f "$LOG"
    ;;
  *)
    usage; exit 1;;
esac
