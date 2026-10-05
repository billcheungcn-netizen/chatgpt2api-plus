#!/usr/bin/env bash
# ============================================================
# chatgpt2api-plus 一键隔离部署 + HTTPS
#
# 用法（在服务器上，以 root 执行，仓库根目录下）：
#   sudo bash deploy/deploy.sh --domain c2a.example.com --email you@example.com
#
# 选项：
#   --domain <域名>     必填（启用 HTTPS 时）。需提前把 A 记录解析到本服务器
#   --email  <邮箱>     Let's Encrypt 通知邮箱（可选）
#   --mode   <模式>     auto(默认) | nginx | caddy | none
#                       auto : 80/443 被宿主机 nginx 占用 → nginx 模式；
#                              80/443 空闲 → caddy 模式；
#                              被其他程序/容器占用 → 只启动应用并给出手动接入说明
#                       none : 只启动应用（127.0.0.1:端口），不配置 HTTPS
#   --port   <端口>     应用本机端口，默认自动从 13001 起找空闲端口
#   --uninstall         只移除本项目自己的容器/网络/nginx 站点文件（保留数据）
#
# 隔离原则（不会触碰服务器上其他项目）：
#   * 独立 compose 项目名 chatgpt2api-plus、容器名 chatgpt2api-plus*、
#     镜像 chatgpt2api-plus:local、网络 chatgpt2api-plus-net
#   * 应用端口只绑定 127.0.0.1
#   * 不执行 docker prune / 不重启 docker / 不改防火墙 / 不 pull 覆盖已有镜像 tag
#   * nginx 只新增一个独立站点文件，nginx -t 失败则自动回滚，不 reload
#   * 证书用 certbot --webroot 申请，不使用 --nginx 插件（不会改写已有配置）
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$REPO_DIR/runtime"
ENV_FILE="$SCRIPT_DIR/.env"
PROJECT="chatgpt2api-plus"
SITE_NAME="chatgpt2api-plus"
ACME_ROOT="/var/www/chatgpt2api-plus-acme"

DOMAIN=""
EMAIL=""
MODE="auto"
APP_PORT=""
UNINSTALL=0

log()  { echo -e "\033[32m[+]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
die()  { echo -e "\033[31m[x]\033[0m $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --email)  EMAIL="$2"; shift 2 ;;
    --mode)   MODE="$2"; shift 2 ;;
    --port)   APP_PORT="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "请用 root 执行（sudo bash deploy/deploy.sh ...）"
command -v docker >/dev/null || die "未检测到 docker，请先安装 docker"
docker compose version >/dev/null 2>&1 || die "需要 docker compose v2 插件"

# 读取已有 .env（重复执行时保持端口/密钥/模式不变）
env_get() { [[ -f "$ENV_FILE" ]] && grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true; }

compose() {
  local profiles=()
  [[ "$(env_get HTTPS_MODE)" == "caddy" ]] && profiles=(--profile caddy)
  docker compose -p "$PROJECT" -f "$SCRIPT_DIR/docker-compose.yml" --env-file "$ENV_FILE" ${profiles[@]+"${profiles[@]}"} "$@"
}

# ---------------- nginx 探测 ----------------
NGINX_BIN=""; NGINX_CONF_DIR=""; NGINX_ENABLED_DIR=""
detect_nginx() {
  if [[ -x /www/server/nginx/sbin/nginx && -d /www/server/panel/vhost/nginx ]]; then
    # 宝塔面板
    NGINX_BIN=/www/server/nginx/sbin/nginx
    NGINX_CONF_DIR=/www/server/panel/vhost/nginx
  elif command -v nginx >/dev/null; then
    NGINX_BIN="$(command -v nginx)"
    local dump; dump="$("$NGINX_BIN" -T 2>/dev/null || cat /etc/nginx/nginx.conf 2>/dev/null || true)"
    if grep -qE 'include\s+/etc/nginx/conf\.d/\*\.conf' <<<"$dump" && [[ -d /etc/nginx/conf.d ]]; then
      NGINX_CONF_DIR=/etc/nginx/conf.d
    elif grep -qE 'include\s+/etc/nginx/sites-enabled/' <<<"$dump" && [[ -d /etc/nginx/sites-available ]]; then
      NGINX_CONF_DIR=/etc/nginx/sites-available
      NGINX_ENABLED_DIR=/etc/nginx/sites-enabled
    fi
  fi
}
site_file() { echo "$NGINX_CONF_DIR/$SITE_NAME.conf"; }
nginx_reload() { "$NGINX_BIN" -t && "$NGINX_BIN" -s reload; }

remove_nginx_site() {
  detect_nginx
  [[ -n "$NGINX_CONF_DIR" ]] || return 0
  local f; f="$(site_file)"
  [[ -n "$NGINX_ENABLED_DIR" ]] && rm -f "$NGINX_ENABLED_DIR/$SITE_NAME.conf"
  if [[ -f "$f" ]]; then rm -f "$f"; nginx_reload || warn "nginx reload 失败，请手动检查"; fi
}

# ---------------- 卸载 ----------------
if [[ $UNINSTALL -eq 1 ]]; then
  [[ -f "$ENV_FILE" ]] || die "未找到 $ENV_FILE，似乎尚未部署"
  log "停止并移除本项目容器与网络（保留 runtime/ 数据与证书）"
  compose --profile caddy down
  [[ "$(env_get HTTPS_MODE)" == "nginx" ]] && remove_nginx_site
  log "卸载完成。数据仍在 $RUNTIME_DIR"
  exit 0
fi

# ---------------- 端口占用 ----------------
port_in_use() { ss -Hltn "( sport = :$1 )" 2>/dev/null | grep -q .; }
port_owner()  { ss -Hltnp "( sport = :$1 )" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -1 | sed 's/users:(("//'; }

# ---------------- 准备 .env ----------------
mkdir -p "$RUNTIME_DIR/data"
[[ -f "$RUNTIME_DIR/config.json" ]] || { cp "$REPO_DIR/config.json" "$RUNTIME_DIR/config.json"; log "已生成 runtime/config.json"; }

AUTH_KEY="$(env_get CHATGPT2API_AUTH_KEY)"
[[ -n "$AUTH_KEY" ]] || AUTH_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# 端口被本项目自己的容器占用视为正常（重复部署）
own_port() { docker port chatgpt2api-plus 80/tcp 2>/dev/null | grep -q ":$1$"; }
if [[ -n "$APP_PORT" ]]; then
  if port_in_use "$APP_PORT" && ! own_port "$APP_PORT"; then die "端口 $APP_PORT 已被其他程序占用"; fi
else
  APP_PORT="$(env_get APP_PORT)"
  if [[ -z "$APP_PORT" ]] || { port_in_use "$APP_PORT" && ! own_port "$APP_PORT"; }; then
    APP_PORT=13001
    while port_in_use "$APP_PORT"; do APP_PORT=$((APP_PORT + 1)); done
  fi
fi
[[ -n "$DOMAIN" ]] || DOMAIN="$(env_get DOMAIN)"
[[ -n "$EMAIL" ]] || EMAIL="$(env_get ACME_EMAIL)"

# 确定 HTTPS 模式
if [[ "$MODE" == "auto" ]]; then
  PREV_MODE="$(env_get HTTPS_MODE)"
  if [[ -n "$PREV_MODE" ]]; then
    MODE="$PREV_MODE"
  elif [[ -z "$DOMAIN" ]]; then
    MODE="none"
  else
    o80="$(port_owner 80)"; o443="$(port_owner 443)"
    if [[ -z "$o80" && -z "$o443" ]]; then
      MODE="caddy"
    elif [[ "$o80" == nginx* || "$o443" == nginx* ]]; then
      MODE="nginx"
    else
      MODE="manual"
      warn "80/443 被 '${o80:-$o443}' 占用（非宿主机 nginx），为避免影响已有业务，不自动接管。"
    fi
  fi
fi
[[ "$MODE" =~ ^(nginx|caddy|none|manual)$ ]] || die "无效 --mode: $MODE"
[[ "$MODE" == "none" || "$MODE" == "manual" || -n "$DOMAIN" ]] || die "HTTPS 模式需要 --domain"

BASE_URL=""
[[ -n "$DOMAIN" && "$MODE" != "none" ]] && BASE_URL="https://$DOMAIN"

cat >"$ENV_FILE" <<EOF
# 由 deploy.sh 生成，重复执行会保留端口与密钥
APP_PORT=$APP_PORT
CHATGPT2API_AUTH_KEY=$AUTH_KEY
CHATGPT2API_BASE_URL=$BASE_URL
STORAGE_BACKEND=json
TZ=Asia/Shanghai
APP_MEM_LIMIT=$(env_get APP_MEM_LIMIT | grep . || echo 1g)
APP_CPUS=$(env_get APP_CPUS | grep . || echo 1.0)
DOMAIN=$DOMAIN
ACME_EMAIL=$EMAIL
HTTPS_MODE=$MODE
EOF
chmod 600 "$ENV_FILE"
log "模式: $MODE  域名: ${DOMAIN:-<无>}  应用端口: 127.0.0.1:$APP_PORT"

# ---------------- DNS 检查（仅提示） ----------------
if [[ -n "$DOMAIN" && "$MODE" != "none" ]]; then
  resolved="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)"
  public_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    die "$DOMAIN 无法解析，请先添加 A 记录指向本服务器${public_ip:+ ($public_ip)}"
  elif [[ -n "$public_ip" && "$resolved" != "$public_ip" ]]; then
    warn "$DOMAIN 解析到 $resolved，本机公网 IP 为 $public_ip（如走 CDN 请先关闭代理/小黄云再申请证书）"
  fi
fi

# ---------------- 构建 & 启动应用 ----------------
# 注意：不加 --pull，避免更新本机已有的 ghcr.io/basketikun/chatgpt2api:latest 影响其他项目
log "构建镜像 chatgpt2api-plus:local"
compose build app
if [[ "$MODE" == "caddy" ]]; then
  if [[ -z "$(docker ps -q -f name='^chatgpt2api-plus-caddy$')" ]] && { port_in_use 80 || port_in_use 443; }; then
    die "80/443 已被占用，不能启用 caddy 模式（可改用 --mode nginx 或 --mode none）"
  fi
  mkdir -p "$RUNTIME_DIR/caddy/data" "$RUNTIME_DIR/caddy/config"
  email_line=""; [[ -n "$EMAIL" ]] && email_line="	email $EMAIL"
  sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__GLOBAL_EMAIL__|$email_line|" "$SCRIPT_DIR/Caddyfile.tpl" >"$RUNTIME_DIR/caddy/Caddyfile"
  compose up -d app caddy
else
  compose up -d app
fi

log "等待应用健康检查..."
for i in $(seq 1 30); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$APP_PORT/version" >/dev/null 2>&1; then ok=1; break; fi
  sleep 3
done
[[ "${ok:-0}" == 1 ]] || { compose logs --tail 80 app; die "应用未能启动，见上方日志"; }
log "应用已启动: http://127.0.0.1:$APP_PORT"

# ---------------- nginx 模式：新增独立站点 + certbot webroot ----------------
setup_nginx() {
  detect_nginx
  [[ -n "$NGINX_BIN" && -n "$NGINX_CONF_DIR" ]] || die "未能识别 nginx 配置目录，请改用 --mode none 并手动配置反代"
  local f; f="$(site_file)"

  # 防止抢占其他站点的同名 server_name
  if "$NGINX_BIN" -T 2>/dev/null | awk -v own="$f" '/^# configuration file /{cur=$4; sub(/:$/,"",cur)} cur!=own' \
      | awk -v d="$DOMAIN" '$1=="server_name"{for(i=2;i<=NF;i++){t=$i; sub(/;$/,"",t); if(t==d) found=1}} END{exit !found}'; then
    die "已有其他 nginx 站点在使用 $DOMAIN，为避免冲突终止。请换一个子域名。"
  fi

  mkdir -p "$ACME_ROOT"
  local backup=""
  [[ -f "$f" ]] && { backup="$(mktemp)"; cp "$f" "$backup"; }

  write_site() { # $1 = full|http
    if [[ "$1" == "http" ]]; then
      cat >"$f" <<EOF
# chatgpt2api-plus —— 临时 HTTP 配置，仅用于申请证书
server {
    listen 80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; default_type "text/plain"; }
    location / { return 404; }
}
EOF
    else
      sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__ACME_ROOT__|$ACME_ROOT|g" -e "s|__APP_PORT__|$APP_PORT|g" \
        "$SCRIPT_DIR/nginx-site.conf.tpl" >"$f"
      # nginx < 1.25.1 不支持 "http2 on;"
      local ver; ver="$("$NGINX_BIN" -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      if [[ "$(printf '%s\n1.25.1\n' "$ver" | sort -V | head -1)" != "1.25.1" ]]; then
        sed -i -e '/^\s*http2 on;/d' -e 's/listen 443 ssl;/listen 443 ssl http2;/' -e 's/listen \[::\]:443 ssl;/listen [::]:443 ssl http2;/' "$f"
      fi
      # 服务器未启用 IPv6 时去掉 [::] 监听，否则 nginx -t 会失败
      [[ -s /proc/net/if_inet6 ]] || sed -i '/listen \[::\]/d' "$f"
    fi
    [[ -n "$NGINX_ENABLED_DIR" ]] && ln -sf "$f" "$NGINX_ENABLED_DIR/$SITE_NAME.conf"
    if ! "$NGINX_BIN" -t; then
      warn "nginx 配置校验失败，回滚本项目站点文件（未 reload，其他站点不受影响）"
      if [[ -n "$backup" ]]; then cp "$backup" "$f"; else rm -f "$f"; [[ -n "$NGINX_ENABLED_DIR" ]] && rm -f "$NGINX_ENABLED_DIR/$SITE_NAME.conf"; fi
      die "请检查 nginx 配置后重试"
    fi
    "$NGINX_BIN" -s reload
  }

  local cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  if [[ ! -f "$cert" ]]; then
    write_site http
    local email_args=(--register-unsafely-without-email)
    [[ -n "$EMAIL" ]] && email_args=(-m "$EMAIL")
    if command -v certbot >/dev/null; then
      log "使用宿主机 certbot 申请证书（webroot 方式，不改动现有 nginx 配置）"
      certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --agree-tos --non-interactive "${email_args[@]}" \
        --deploy-hook "$NGINX_BIN -t && $NGINX_BIN -s reload"
    else
      log "宿主机无 certbot，使用 certbot 容器申请证书"
      docker run --rm --name chatgpt2api-plus-certbot \
        -v /etc/letsencrypt:/etc/letsencrypt -v /var/lib/letsencrypt:/var/lib/letsencrypt -v "$ACME_ROOT:$ACME_ROOT" \
        certbot/certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --agree-tos --non-interactive "${email_args[@]}"
      # 自动续期：每天两次，仅续期本域名
      cat >/etc/cron.d/chatgpt2api-plus-certbot <<EOF
17 3,15 * * * root docker run --rm -v /etc/letsencrypt:/etc/letsencrypt -v /var/lib/letsencrypt:/var/lib/letsencrypt -v $ACME_ROOT:$ACME_ROOT certbot/certbot renew --cert-name $DOMAIN --quiet && $NGINX_BIN -t && $NGINX_BIN -s reload
EOF
      chmod 644 /etc/cron.d/chatgpt2api-plus-certbot
    fi
  else
    log "证书已存在，跳过申请"
  fi
  write_site full
  [[ -n "$backup" ]] && rm -f "$backup"
  log "nginx 站点已写入: $f"
}

case "$MODE" in
  nginx) setup_nginx ;;
  caddy) log "Caddy 将自动申请并续期证书（首次约需 10~60 秒）" ;;
esac

# ---------------- 结果 ----------------
echo
log "部署完成"
if [[ "$MODE" == "nginx" || "$MODE" == "caddy" ]]; then
  for i in $(seq 1 20); do curl -fsS --max-time 5 "https://$DOMAIN/version" >/dev/null 2>&1 && { https_ok=1; break; }; sleep 3; done
  [[ "${https_ok:-0}" == 1 ]] && log "HTTPS 访问正常: https://$DOMAIN" || warn "暂未能通过 https://$DOMAIN 访问，请检查 DNS/安全组 443 端口"
fi
if [[ "$MODE" == "manual" ]]; then
  warn "80/443 已被其他程序占用，请在现有反向代理中把 ${DOMAIN:-你的域名} 转发到 http://127.0.0.1:$APP_PORT"
  warn "（需关闭缓冲以支持流式输出，参考 deploy/nginx-site.conf.tpl）"
fi
echo "  管理后台登录密钥 (auth-key): $AUTH_KEY"
echo "  （保存在 $ENV_FILE，权限 600）"
echo "  查看日志: docker compose -p $PROJECT -f deploy/docker-compose.yml --env-file deploy/.env logs -f app"
