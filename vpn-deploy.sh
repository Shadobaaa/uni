#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# ─────────────────────────── Метаданные ──────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/vpn-deploy"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly LOG_FILE="/var/log/vpn-deploy.log"

# ─────────────────────────── Дефолты ─────────────────────────────────────────
PANEL_PORT=2053 # порт панели 3X-UI внутри контейнера; наружу
# пробрасываем 127.0.0.1:2053 → 0.0.0.0:443 nginx
XRAY_INBOUND_PORT=443 # VLESS-Reality слушает здесь (TCP)
REALITY_DEST_DEFAULT="www.microsoft.com:443"
REALITY_SNI_DEFAULT="www.microsoft.com"
PANEL_USER_DEFAULT="admin"
PANEL_PASS_LEN=20
DOMAIN=""
EMAIL=""
AUTO_TLS="ask"
NON_INTERACTIVE=false
SKIP_AUTOUPDATE=false
SKIP_FIREWALL=false
REINSTALL=false

# ─────────────────────────── Цвета / логирование ─────────────────────────────
if [[ -t 1 ]]; then
C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
C_RED=''; C_YEL=''; C_GRN=''; C_BLU=''; C_DIM=''; C_BLD=''; C_OFF=''
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

_log() {
local level="$1"; shift
local color="${2:-}"
local msg="$*"
local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
printf '%s [%s] %s\n' "$ts" "$level" "$msg" \
>>"$LOG_FILE" 2>/dev/null || true
if [[ -t 1 ]]; then
printf '%s%s%s %s\n' "$color" "$level" "$C_OFF" "$msg"
else
printf '%s %s\n' "$level" "$msg"
fi
}
log_info() { _log "[INFO]" "$C_BLU" "$*"; }
log_ok() { _log "[ OK ]" "$C_GRN" "$*"; }
log_warn() { _log "[WARN]" "$C_YEL" "$*"; }
log_err() { _log "[FAIL]" "$C_RED" "$*" >&2; }
die() { log_err "$*"; exit 1; }

section() {
printf '\n%s%s━━━ %s ━━━%s\n' "$C_BLD" "$C_BLU" "$*" "$C_OFF"
}

trap 'ec=$?; trap - ERR; log_err "Аварийная остановка на строке $LINENO (exit $ec). См. $LOG_FILE"' ERR

# ─────────────────────────── Утилиты ─────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
[[ $EUID -eq 0 ]] || die "Запустите от root: sudo $SCRIPT_NAME"
}

detect_os() {
[[ -f /etc/os-release ]] || die "Только Linux (ожидался /etc/os-release)"
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}-${VERSION_ID:-}" in
ubuntu-2*) : ;;
*) die "Скрипт рассчитан на Ubuntu. Обнаружено: ${PRETTY_NAME:-unknown}";;
esac
printf '%s\n' "$VERSION_CODENAME"
}

random_secret() {
local n="${1:-$PANEL_PASS_LEN}"
tr -dc 'A-Za-z0-9!_#%+=' </dev/urandom | head -c "$n" || true
echo
}

prompt_default() {
local var_name="$1" prompt_text="$2" default_val="$3" is_secret="${4:-no}"
local current="${!var_name:-$default_val}"
local ans
if [[ "$is_secret" == "secret" ]]; then
read -rs -p "$(printf '%s [%s]: ' "$prompt_text" "${current:+***есть***}${current:-пусто}")" ans
echo
else
read -r -p "$(printf '%s [%s]: ' "$prompt_text" "$current")" ans
fi
ans="${ans:-$current}"
printf -v "$var_name" '%s' "$ans"
}

confirm() {
local q="${1:-Продолжить?}"
if [[ "$NON_INTERACTIVE" == "true" ]]; then return 0; fi
local ans
read -r -p "$(printf '%s [y/N]: ' "$q")" ans
[[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}
usage() {
cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION — разворачивает VLESS-Reality + 3X-UI

Использование:
sudo $SCRIPT_NAME [опции]

Опции:
-d, --domain <fqdn> FQDN для панели (например vpn.example.com);
включает выпуск Let's Encrypt сертификата.
-e, --email <addr> Email для Let's Encrypt / acme.sh регистрации.
-u, --panel-user <name> Логин панели 3X-UI (по умолчанию: admin)
-p, --panel-pass <flower> Цветок панели (иначе генерируется случайно)
--panel-port <port> Порт панели (по умолчанию $PANEL_PORT, на 127.0.0.1)
--reality-dest <h:p> Назначение Reality (по умолчанию $REALITY_DEST_DEFAULT)
--reality-sni <host> SNI для Reality (по умолчанию $REALITY_SNI_DEFAULT)
--non-interactive Не задавать вопросов (использовать флаги или дефолты)
--reinstall Полностью удалить предыдущую установку перед новой
--skip-firewall Не настраивать ufw (не рекомендуется)
--skip-autoupdate Не ставить systemd timer автообновления
-h, --help Эта справка

Пример:
sudo bash $SCRIPT_NAME -d vpn.example.com -e me@example.com -u admin -p 'flower'
EOF
}

parse_args() {
while (($#)); do
case "$1" in
-d|--domain) DOMAIN="$2"; shift 2;;
-e|--email) EMAIL="$2"; shift 2;;
-u|--panel-user) PANEL_USER="$2"; shift 2;;
-p|--panel-pass) PANEL_PASS="$2"; shift 2;;
--panel-port) PANEL_PORT="$2"; shift 2;;
--reality-dest) REALITY_DEST="$2"; shift 2;;
--reality-sni) REALITY_SNI="$2"; shift 2;;
--non-interactive) NON_INTERACTIVE=true; shift;;
--reinstall) REINSTALL=true; shift;;
--skip-firewall) SKIP_FIREWALL=true; shift;;
--skip-autoupdate) SKIP_AUTOUPDATE=true; shift;;
-h|--help) usage; exit 0;;
*) die "Неизвестная опция: $1 (--help для справки)";;
esac
done
}

# ─────────────────────────── Пре-полёт ───────────────────────────────────────
preflight() {
section "Пре-полёт"
require_root
local codename; codename="$(detect_os)"; log_ok "Ubuntu ($codename)"
have curl || die "curl не найден (apt update && apt install curl)"
have openssl || die "openssl не найден"
have uuidgen || die "uuidgen не найден (apt install uuid-runtime)"
log_ok "Базовые утилиты на месте"
if [[ "$NON_INTERACTIVE" != "true" ]]; then
log_info "Это действие изменит систему и установит Docker/Xray."
confirm "Продолжить?" || die "Отменено пользователем"
fi
}

gather_input() {
section "Параметры установки"
if [[ "$NON_INTERACTIVE" == "true" ]]; then
PANEL_USER="${PANEL_USER:-$PANEL_USER_DEFAULT}"
PANEL_PASS="${PANEL_PASS:-$(random_secret)}"
REALITY_DEST="${REALITY_DEST:-$REALITY_DEST_DEFAULT}"
REALITY_SNI="${REALITY_SNI:-$REALITY_SNI_DEFAULT}"
else
prompt_default PANEL_USER "Логин панели 3X-UI" "$PANEL_USER_DEFAULT"
if [[ -z "${PANEL_PASS:-}" ]]; then
local pass=""
while [[ -z "$pass" ]]; do
read -rs -p "$(printf '%s [Enter = сгенерировать]: ' 'Цветок панели (мин. 8 символов)')" pass
echo
if [[ -z "$pass" ]]; then
pass="$(random_secret)"
printf '%s Сгенерирован: %s%s\n' "$C_GRN" "$pass" "$C_OFF"
elif [[ ${#pass} -lt 8 ]]; then
log_warn "Минимум 8 символов — попробуйте снова"
pass=""
fi
done
PANEL_PASS="$pass"
fi
prompt_default REALITY_DEST "Reality dest (хост:порт)" "$REALITY_DEST_DEFAULT"
prompt_default REALITY_SNI "Reality SNI (хост)" "$REALITY_SNI_DEFAULT"
prompt_default DOMAIN "Домен для панели (опц., пусто = SSH-tunnel)" ""
if [[ -n "$DOMAIN" ]]; then
prompt_default EMAIL "Email для Let's Encrypt" ""
fi
fi
export PANEL_USER PANEL_PASS REALITY_DEST REALITY_SNI DOMAIN EMAIL
log_ok "PANEL_USER=$PANEL_USER"
log_ok "REALITY_DEST=$REALITY_DEST SNI=$REALITY_SNI"
[[ -n "$DOMAIN" ]] && log_ok "DOMAIN=$DOMAIN EMAIL=$EMAIL → панель снаружи: https://$DOMAIN:${PANEL_TLS_PORT:-8443}" \
|| log_info "Домен не задан → панель будет на http://127.0.0.1:$PANEL_PORT через SSH-туннель"
}

# ─────────────────────────── Зависимости ─────────────────────────────────────
install_deps() {
section "Установка системных пакетов"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
ca-certificates curl wget jq uuid-runtime openssl \
ufw nginx-light certbot cron qrencode gnupg
log_ok "Пакеты установлены"
}

# ─────────────────────────── Docker + 3X-UI ───────────────────────────────────
ensure_docker() {
section "Docker"
if have docker; then
log_ok "docker уже установлен ($(docker --version))"
else
log_info "Ставлю docker.io через официальный репозиторий…"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
| gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
local arch; arch="$(dpkg --print-architecture)"
. /etc/os-release
echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
> /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
log_ok "Docker установлен"
fi
have docker || die "Docker недоступен после установки"
}

install_3xui() {
section "3X-UI (панель управления Xray)"
if [[ "$REINSTALL" == "true" ]]; then
log_warn "--reinstall: останавливаю и удаляю предыдущий контейнер"
docker rm -f 3x-ui 2>/dev/null || true
fi
if docker ps -a --format '{{.Names}}' | grep -qx '3x-ui'; then
log_ok "Контейнер 3x-ui уже существует, пропускаю create"
else
mkdir -p "$STATE_DIR/db" "$STATE_DIR/certs" "$STATE_DIR/bin"
docker run -d \
--name 3x-ui \
--restart unless-stopped \
-e XRAY_VMESS_AEAD_FORCED=false \
-p "127.0.0.1:${PANEL_PORT}:${PANEL_PORT}" \
-v "${STATE_DIR}/db:/etc/x-ui" \
-v "${STATE_DIR}/certs:/root/cert" \
ghcr.io/mhsanaei/3x-ui:latest
log_ok "Контейнер 3x-ui запущен (проброс на 127.0.0.1:${PANEL_PORT})"
fi
# ждём готовности базы
for _ in $(seq 1 30); do
if docker exec 3x-ui test -f /etc/x-ui/x-ui.db 2>/dev/null; then
log_ok "База 3X-UI доступна"; break
fi
sleep 1
done
}

# ─────────────────────────── Xray-core ───────────────────────────────────────
ensure_xray() {
section "Xray-core"
if have xray && [[ "$REINSTALL" != "true" ]]; then
log_ok "xray уже установлен ($(xray version 2>/dev/null | head -1))"
return
fi
log_info "Ставлю Xray через официальный установщик…"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
log_ok "Xray установлен: $(xray version 2>/dev/null | head -1)"
}

generate_reality_keys() {
section "Генерация ключей Reality"
mkdir -p "$STATE_DIR"
REALITY_KEYS_FILE="$STATE_DIR/reality.env"
if [[ -f "$REALITY_KEYS_FILE" && "$REINSTALL" != "true" ]]; then
# shellcheck disable=SC1090
. "$REALITY_KEYS_FILE"
log_ok "Ключи взяты из $REALITY_KEYS_FILE"
else
# Генерируем ключи через openssl (не зависит от наличия xray в контейнере)
# Создаём временный файл для приватного ключа
local tmp_priv=$(mktemp)
local tmp_pub=$(mktemp)
trap "rm -f '$tmp_priv' '$tmp_pub'" RETURN

# Генерация private key
openssl genpkey -algorithm X25519 -out "$tmp_priv" 2>/dev/null \
|| die "Не удалось сгенерировать приватный ключ X25519"

# Извлечение public key
openssl pkey -in "$tmp_priv" -pubout -out "$tmp_pub" 2>/dev/null \
|| die "Не удалось извлечь публичный ключ X25519"

# Конвертируем в формат, ожидаемый Xray (base64 без переносов)
REALITY_PRIV=$(openssl pkey -in "$tmp_priv" -outform DER 2>/dev/null | tail -c 32 | base64 -w0)
REALITY_PUB=$(openssl pkey -in "$tmp_pub" -pubin -outform DER 2>/dev/null | tail -c 32 | base64 -w0)

[[ -n "$REALITY_PUB" && -n "$REALITY_PRIV" ]] \
|| die "Не удалось сгенерировать x25519 ключи"
SHORT_ID="$(openssl rand -hex 8)"
CLIENT_UUID="$(uuidgen)"
cat >"$REALITY_KEYS_FILE" <<EOF
# Сгенерировано $(date -Iseconds) — НЕ показывайте эти значения третьим лицам.
REALITY_PUB='$REALITY_PUB'
REALITY_PRIV='$REALITY_PRIV'
SHORT_ID='$SHORT_ID'
CLIENT_UUID='$CLIENT_UUID'
EOF
chmod 600 "$REALITY_KEYS_FILE"
log_ok "Ключи сохранены в $REALITY_KEYS_FILE (chmod 600)"
fi
export REALITY_PUB REALITY_PRIV SHORT_ID CLIENT_UUID
}

# ─────────────────────────── Firewall ────────────────────────────────────────
PANEL_TLS_PORT=8443 # используется ТОЛЬКО если указан --domain

configure_firewall() {
[[ "$SKIP_FIREWALL" == "true" ]] && { log_warn "ufw пропущен (--skip-firewall)"; return; }
section "UFW (firewall)"
if ! have ufw; then apt-get install -y --no-install-recommends ufw >/dev/null; fi
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp comment 'HTTP — нужен только acme challenge'
ufw allow "${XRAY_INBOUND_PORT}/tcp" comment 'VLESS-Reality (TCP 443)'
if [[ -n "$DOMAIN" ]]; then
ufw allow "${PANEL_TLS_PORT}/tcp" comment 'HTTPS → nginx → 3X-UI panel'
fi
ufw --force enable
ufw status verbose
local ports="22,80,${XRAY_INBOUND_PORT}"
[[ -n "$DOMAIN" ]] && ports+=",${PANEL_TLS_PORT}"
log_ok "UFW активен. Открыты TCP: $ports"
}

# ─────────────────────────── TLS для панели ───────────────────────────────────
setup_panel_tls() {
[[ -z "$DOMAIN" ]] && { log_info "Домен не задан — пропускаю TLS/LE"; return; }
[[ -z "$EMAIL" ]] && die "Для --domain требуется --email (Let's Encrypt регистрация)"
section "TLS для панели ($DOMAIN)"

# проверяем DNS
local resolved; resolved="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')"
local public_ip; public_ip="$(curl -fsSL https://api.ipify.org || true)"
log_info "DNS $DOMAIN → ${resolved:-нет A-записи}, public IP сервера: ${public_ip:-?}"
if [[ -n "$public_ip" && "$resolved" != "$public_ip" ]]; then
log_warn "A-запись домена не указывает на этот сервер. Сертификат может не выписаться."
confirm "Всё равно попробовать?" || return 0
fi

# выпускаем (или пропускаем, если уже есть) сертификат LE
local email_arg=()
[[ -n "$EMAIL" ]] && email_arg=(--email "$EMAIL")

local cert_dir="/etc/letsencrypt/live/$DOMAIN"
if [[ ! -d "$cert_dir" ]]; then
certbot certonly --non-interactive --agree-tos "${email_arg[@]}" \
--standalone --preferred-challenges http \
-d "$DOMAIN" || die "Не удалось получить сертификат LE для $DOMAIN"
fi

# nginx reverse-proxy → 3X-UI на loopback
cat >/etc/nginx/sites-available/3x-ui <<NGINX
# Порт ${PANEL_TLS_PORT}/tcp открыт в ufw, принимает только HTTPS с валидным ServerName.
server {
listen ${PANEL_TLS_PORT} ssl http2;
server_name ${DOMAIN};

ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;

add_header Strict-Transport-Security "max-age=63072000" always;
add_header X-Frame-Options SAMEORIGIN;
add_header X-Content-Type-Options nosniff;

location / {
proxy_pass http://127.0.0.1:${PANEL_PORT};
proxy_http_version 1.1;
proxy_set_header Host \$host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto https;
proxy_read_timeout 600s;
client_max_body_size 50m;
}
}
NGINX
ln -sf /etc/nginx/sites-available/3x-ui /etc/nginx/sites-enabled/3x-ui
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# автообновление сертификата (certbot timer уже идёт из коробки,
# но проверим, что хук перечитывает конфиг nginx):
if ! grep -q 'nginx' /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh 2>/dev/null; then
install -d /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nsystemctl reload nginx >/dev/null 2>&1 || true\n' \
> /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
fi
log_ok "nginx настроен: https://${DOMAIN}:${PANEL_TLS_PORT} → 3X-UI"
}

# ─────────────────────────── Xray-inbound + bind ─────────────────────────────
build_xray_json_and_bind() {
section "Конфигурация Xray inbound (VLESS-Reality)"
local cfg="/usr/local/etc/xray/config.json"
backup_if_exists "$cfg"
cat >"$cfg" <<JSON
{
"log": { "loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },
"inbounds": [
{
"tag": "vless-reality",
"listen": "0.0.0.0",
"port": ${XRAY_INBOUND_PORT},
"protocol": "vless",
"settings": {
"clients": [
{ "id": "${CLIENT_UUID}", "flow": "xtls-rprx-vision", "email": "[email protected]" }
],
"decryption": "none"
},
"streamSettings": {
"network": "tcp",
"security": "reality",
"realitySettings": {
"show": false,
"dest": "${REALITY_DEST}",
"xver": 1,
"serverNames": ["${REALITY_SNI}","www.${REALITY_SNI}"],
"privateKey": "${REALITY_PRIV}",
"shortIds": ["${SHORT_ID}"]
}
},
"sniffing": { "enabled": true, "destOverride": ["http","tls"] }
}
],
"outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
JSON
chmod 644 "$cfg"
mkdir -p /var/log/xray
chown -R nobody:nogroup /var/log/xray || true
systemctl enable --now xray
systemctl restart xray
log_ok "Xray запущен, config: $cfg"
}

backup_if_exists() {
local f="$1"
if [[ -f "$f" ]]; then
mkdir -p "$BACKUP_DIR"
cp -a "$f" "$BACKUP_DIR/$(basename "$f").$(date +%Y%m%d-%H%M%S).bak"
fi
}

# ─────────────────────────── Split routing (клиентская часть) ────────────────
make_client_artifacts() {
section "Артефакты для клиента"
local outdir="${STATE_DIR}/client-${CLIENT_UUID:0:8}"
mkdir -p "$outdir"
chmod 700 "$outdir"

local server_ip; server_ip="$(curl -fsSL https://api.ipify.org || hostname -I | awk '{print $1}')"
local sni; sni="${REALITY_SNI}"

local params="type=tcp&security=reality&pbk=${REALITY_PUB}&fp=chrome&sni=${sni}&sid=${SHORT_ID}&flow=xtls-rprx-vision"
local link="vless://${CLIENT_UUID}@${server_ip}:${XRAY_INBOUND_PORT}?${params}#VPN-${HOSTNAME}"

{
echo "# ───── Клиентский конфиг ─────"
echo "# Имя хоста сервера: $HOSTNAME"
echo "# Домен (SNI маскировки): $sni"
echo "# Протокол: VLESS + Reality + Vision"
echo
echo "VLESS_LINK='${link}'"
echo
echo "# Поддерживаемые клиенты:"
echo "# Android — Nekobox, V2RayNG, Hiddify Next"
echo "# iOS — Streisand, V2Box, FoXray"
echo "# Windows — Hiddify Next, Nekoray, v2rayN"
echo "# macOS — Hiddify Next, Nekoray"
echo "# Linux — Nekoray, sing-box"
echo
echo "# ───── Split-routing (RU bypass) ─────"
echo "# Если используете Hiddify/Nekobox — в настройках правил клиента"
echo "# добавьте geosite:category-ru-ru + geoip:ru в DIRECT (направлять напрямую)."
echo "# Для ручной настройки sing-box / xray-client см.:"
echo "# https://github.com/loyalsoldier/v2ray-rules-dat"
} > "$outdir/client.env"

printf '%s\n' "$link" > "$outdir/link.txt"
if have qrencode; then
qrencode -o "$outdir/qr.png" -s 8 -m 2 "$link"
fi
chmod 600 "$outdir"/*
log_ok "Ссылка и QR-код сохранены в $outdir/"
cat <<EOF

${C_BLD}${C_GRN}═══ Ваш VLESS-Reality конфиг ═══${C_OFF}

Адрес сервера : ${server_ip}:${XRAY_INBOUND_PORT}
UUID : ${CLIENT_UUID}
PublicKey : ${REALITY_PUB}
ShortID : ${SHORT_ID}
SNI / Dest : ${sni} / ${REALITY_DEST}
Flow : xtls-rprx-vision
Fingerprint : chrome

VLESS-ссылка :
${C_BLU}${link}${C_OFF}

${C_DIM}(см. также $outdir/client.env)${C_OFF}

════════════════════════════════════
EOF
}

# ─────────────────────────── Автообновление ──────────────────────────────────
install_autoupdate() {
[[ "$SKIP_AUTOUPDATE" == "true" ]] && { log_warn "Автообновление пропущено"; return; }
section "Systemd timer: автообновление"
local unit="/etc/systemd/system/vpn-deploy-update.service"
local timer="/etc/systemd/system/vpn-deploy-update.timer"

cat >"$unit" <<UNIT
[Unit]
Description=vpn-deploy auto-update (Xray + 3X-UI image)
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-deploy-update.sh
Environment=PANEL_PORT=${PANEL_PORT}
Nice=10
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
UNIT

cat >"$timer" <<TIMER
[Unit]
Description=Weekly auto-update of Xray and 3X-UI

[Timer]
OnCalendar=weekly
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
TIMER

cat >/usr/local/bin/vpn-deploy-update.sh <<'UPDATER'
#!/usr/bin/env bash
# Атомарное обновление Xray-core + 3X-UI image c бэкапом базы
set -Eeuo pipefail
log() { printf '[updater] %s\n' "$"; logger -t vpn-deploy-updater "$" || true; }

STATE_DIR="/var/lib/vpn-deploy"
BACKUP_DIR="${STATE_DIR}/backups"
PANEL_PORT="${PANEL_PORT:-2053}"
TS="$(date +%Y%m%d-%H%M%S)"

log "==> Бэкап базы 3X-UI"
mkdir -p "$BACKUP_DIR"
docker exec 3x-ui sh -c 'test -f /etc/x-ui/x-ui.db' || { log "контейнер не готов, отмена"; exit 0; }
docker cp 3x-ui:/etc/x-ui/x-ui.db "${BACKUP_DIR}/x-ui.${TS}.db"

log "==> Обновление 3X-UI image"
docker pull ghcr.io/mhsanaei/3x-ui:latest
IMAGEID=$(docker inspect -f '{{.Image}}' 3x-ui)
LATEST=$(docker images --format '{{.Id}}' ghcr.io/mhsanaei/3x-ui:latest)
if [[ "$IMAGEID" != "$LATEST" ]]; then
docker rm -f 3x-ui
docker run -d --name 3x-ui --restart unless-stopped \
-e XRAY_VMESS_AEAD_FORCED=false \
-p "127.0.0.1:${PANEL_PORT}:${PANEL_PORT}" \
-v "${STATE_DIR}/db:/etc/x-ui" \
-v "${STATE_DIR}/certs:/root/cert" \
ghcr.io/mhsanaei/3x-ui:latest
fi

log "==> Обновление Xray-core"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
systemctl restart xray

# Ротация бэкапов — оставляем 14 последних
ls -1dt "${BACKUP_DIR}"/* 2>/dev/null | tail -n +15 | xargs -r rm -rf --
log "OK"
UPDATER
chmod 755 /usr/local/bin/vpn-deploy-update.sh
systemctl daemon-reload
systemctl enable --now vpn-deploy-update.timer
log_ok "Автообновление активировано (systemd-list-timers | grep vpn-deploy)"
}

# ─────────────────────────── Финальный отчёт ─────────────────────────────────
finalize() {
section "Готово"
local panel_url panel_extra=()
if [[ -n "$DOMAIN" ]]; then
panel_url="https://${DOMAIN}:${PANEL_TLS_PORT}"
else
panel_url="http://127.0.0.1:${PANEL_PORT} через SSH-туннель"
panel_extra=(" Туннель с локальной машины:"
" ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} user@vps.ip")
fi
printf '%s%s%s\n\n' "${C_GRN}" "${C_BLD}" "VPN успешно развёрнут."
cat <<EOF
• Панель 3X-UI : ${panel_url}
Логин: ${PANEL_USER}
EOF
if ((${#panel_extra[@]})); then
printf ' %s\n' "${panel_extra[0]}"
printf ' %s\n' "${panel_extra[1]}"
fi
cat <<EOF
• Цветок : ${PANEL_PASS} ← СОХРАНИТЕ В МЕНЕДЖЕРЕ ЦВЕТКОВ
• Логи : journalctl -u xray -f | docker logs -f 3x-ui
• Управление : добавляйте клиентов прямо в 3X-UI (Inbounds → + Add Client)
• Обновить : systemctl start vpn-deploy-update.service

${C_DIM}Совет: на клиенте добавьте в «Direct» маршруты geosite:category-ru-ru + geoip:ru,
чтобы российские сайты шли напрямую, а не через VPS.${C_OFF}
EOF
}

main() {
parse_args "$@"
preflight
gather_input
install_deps
ensure_docker
install_3xui
ensure_xray
generate_reality_keys
configure_firewall
setup_panel_tls
build_xray_json_and_bind
make_client_artifacts
install_autoupdate
finalize
}

main "$@"