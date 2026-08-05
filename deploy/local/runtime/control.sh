#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/../../.." && pwd)
ARTIFACT_DIR="$ROOT_DIR/.artifacts"
RUNTIME_DIR="$ARTIFACT_DIR/local-runtime"
SERVER_DATA_DIR="$RUNTIME_DIR/license-data"
SERVER_LOG="$RUNTIME_DIR/license-server.log"
SERVER_BIN="$ARTIFACT_DIR/bin/agentnest-license-server"
APP_BUNDLE="$ARTIFACT_DIR/AgentNest.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/AgentNestApp"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

LOCAL_HOST=${AGENTNEST_LOCAL_HOST:-127.0.0.1}
LOCAL_PORT=${AGENTNEST_LOCAL_PORT:-18080}
SERVER_URL="http://$LOCAL_HOST:$LOCAL_PORT"
DEVELOPMENT_LICENSE_KEY=${AGENTNEST_DEVELOPMENT_LICENSE_KEY:-AGENTNEST-LOCAL-FULL}
ADMIN_TOKEN=${AGENTNEST_ADMIN_TOKEN:-AGENTNEST-LOCAL-ADMIN}
ROOT_CHECKSUM=$(printf '%s' "$ROOT_DIR" | cksum | awk '{print $1}')
TMUX_SESSION=${AGENTNEST_LOCAL_TMUX_SESSION:-agentnest-local-$ROOT_CHECKSUM}

die() {
  echo "control.sh: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

server_healthy() {
  curl --fail --silent --max-time 1 "$SERVER_URL/healthz" >/dev/null 2>&1
}

tmux_session_exists() {
  tmux has-session -t "$TMUX_SESSION" >/dev/null 2>&1
}

wait_for_server() {
  local attempt
  for attempt in $(seq 1 50); do
    if server_healthy; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

public_key() {
  curl --fail --silent --max-time 2 "$SERVER_URL/v1/public-key" |
    plutil -extract publicKey raw -o - -
}

app_pids() {
  ps -axo pid=,command= | awk -v executable="$APP_EXECUTABLE" '$2 == executable {print $1}'
}

wait_for_app() {
  local attempt
  for attempt in $(seq 1 50); do
    [[ -n "$(app_pids)" ]] && return 0
    sleep 0.1
  done
  return 1
}

start_server() {
  require_command tmux
  require_command curl
  require_command plutil

  if server_healthy; then
    tmux_session_exists || die "$SERVER_URL 已有非本脚本管理的服务占用"
    return 0
  fi
  if tmux_session_exists; then
    tmux kill-session -t "$TMUX_SESSION"
  fi

  [[ -x "$SERVER_BIN" ]] || die "服务端尚未编译，请先执行：$0 build"
  mkdir -p "$RUNTIME_DIR" "$SERVER_DATA_DIR"
  chmod 700 "$RUNTIME_DIR" "$SERVER_DATA_DIR"
  touch "$SERVER_LOG"
  chmod 600 "$SERVER_LOG"

  local server_command
  printf -v server_command \
    'exec env AGENTNEST_DEVELOPMENT_LICENSE_KEY=%q AGENTNEST_ADMIN_TOKEN=%q %q --listen %q --data %q >> %q 2>&1' \
    "$DEVELOPMENT_LICENSE_KEY" "$ADMIN_TOKEN" "$SERVER_BIN" "$LOCAL_HOST:$LOCAL_PORT" "$SERVER_DATA_DIR" "$SERVER_LOG"
  tmux new-session -d -s "$TMUX_SESSION" "$server_command"

  if ! wait_for_server; then
    tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
    tail -n 40 "$SERVER_LOG" >&2 || true
    die "本地 License 服务启动失败"
  fi
}

stop_server() {
  if tmux_session_exists; then
    tmux send-keys -t "$TMUX_SESSION" C-c
    local attempt
    for attempt in $(seq 1 50); do
      tmux_session_exists || break
      sleep 0.1
    done
    if tmux_session_exists; then
      tmux kill-session -t "$TMUX_SESSION"
    fi
  fi
}

stop_app() {
  local pid
  while IFS= read -r pid; do
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done < <(app_pids)

  local attempt
  for attempt in $(seq 1 50); do
    [[ -z "$(app_pids)" ]] && return 0
    sleep 0.1
  done
  [[ -z "$(app_pids)" ]] || die "AgentNest.app 未在 5 秒内退出"
}

build() {
  require_command make
  require_command curl
  require_command plutil
  make -C "$ROOT_DIR" build-server
  start_server

  local key
  key=$(public_key)
  [[ -n "$key" ]] || die "无法读取本地签名公钥"
  make -C "$ROOT_DIR" build-client \
    LICENSE_SERVER_URL="$SERVER_URL" \
    LICENSE_PUBLIC_KEY="$key"

  [[ "$(plutil -extract AgentNestLicenseServerURL raw -o - "$INFO_PLIST")" == "$SERVER_URL" ]] ||
    die "客户端 License URL 注入失败"
  [[ "$(plutil -extract AgentNestLicensePublicKey raw -o - "$INFO_PLIST")" == "$key" ]] ||
    die "客户端 License 公钥注入失败"
  echo "本地测试构建完成：$APP_BUNDLE"
}

start() {
  require_command open
  start_server
  [[ -x "$APP_EXECUTABLE" ]] || die "客户端尚未编译，请先执行：$0 build"

  local key configured_url configured_key
  key=$(public_key)
  configured_url=$(plutil -extract AgentNestLicenseServerURL raw -o - "$INFO_PLIST" 2>/dev/null || true)
  configured_key=$(plutil -extract AgentNestLicensePublicKey raw -o - "$INFO_PLIST" 2>/dev/null || true)
  [[ "$configured_url" == "$SERVER_URL" && "$configured_key" == "$key" ]] ||
    die "客户端与当前本地服务配置不一致，请执行：$0 build"

  if [[ -z "$(app_pids)" ]]; then
    open "$APP_BUNDLE"
  fi
  wait_for_app || die "AgentNest.app 启动后未保持运行"
  echo "AgentNest 本地环境已启动"
  echo "  服务：${SERVER_URL}"
  echo "  License Key：${DEVELOPMENT_LICENSE_KEY}"
  echo "  日志：${SERVER_LOG}"
}

stop() {
  stop_app
  stop_server
  echo "AgentNest 本地环境已停止"
}

status() {
  if server_healthy; then
    echo "License 服务：运行中（${SERVER_URL}）"
  else
    echo "License 服务：已停止"
  fi
  if tmux_session_exists; then
    echo "tmux：${TMUX_SESSION}"
  else
    echo "tmux：无会话"
  fi
  local pids
  pids=$(app_pids)
  if [[ -n "$pids" ]]; then
    echo "AgentNest.app：运行中（PID $(echo "$pids" | tr '\n' ' ')）"
  else
    echo "AgentNest.app：已停止"
  fi
}

logs() {
  mkdir -p "$RUNTIME_DIR"
  touch "$SERVER_LOG"
  tail -n 100 -f "$SERVER_LOG"
}

usage() {
  cat <<EOF
用法：$0 <command>

命令：
  build      编译服务端，启动本地服务，注入 URL/公钥并编译客户端
  start      启动 tmux 托管的 License 服务和 AgentNest.app
  stop       停止 AgentNest.app 和本地 License 服务
  restart    重启本地环境（不重新编译）
  status     查看服务、tmux 和 App 状态
  logs       持续查看 License 服务日志

环境变量：
  AGENTNEST_LOCAL_HOST              默认 127.0.0.1
  AGENTNEST_LOCAL_PORT              默认 18080
  AGENTNEST_DEVELOPMENT_LICENSE_KEY 默认 AGENTNEST-LOCAL-FULL
  AGENTNEST_ADMIN_TOKEN             默认 AGENTNEST-LOCAL-ADMIN
  AGENTNEST_LOCAL_TMUX_SESSION      覆盖 tmux session 名称
EOF
}

case "${1:-}" in
  build) build ;;
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  logs) logs ;;
  help|-h|--help) usage ;;
  *) usage; exit 64 ;;
esac
