#!/usr/bin/env bash
# Instalação do NikoDeck para Linux e macOS: instala a versão mais recente, tudo o que ela precisa e o app do celular.
#
#   curl -fsSL https://raw.githubusercontent.com/LordSigfrid/NikoDeck/main/setup.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/LordSigfrid/NikoDeck/main/setup.sh | bash -s -- --no-phone
#
# Execute com o seu usuário, sem sudo: o sudo só é pedido para instalar pacotes, e sempre perguntando antes.
# Executar de novo atualiza o NikoDeck ou repara a instalação; as configurações são mantidas.
#
# Opções:
#   --yes               responde a todas as perguntas com o padrão (sem interação)
#   --no-phone          não instala o app em um celular via USB (para um celular só no Wi-Fi)
#   --serial <id>       o celular a usar quando há vários conectados (veja "adb devices")
#   --no-autostart      não inicia o NikoDeck ao entrar na sessão
#   --no-start          só instala; não inicia o agente
#   --no-extras         não oferece os auxiliares opcionais (playerctl, xprintidle, nowplaying-cli ...)
#   --version <x.y.z>   instala esta versão em vez da mais recente
#   --dry-run           baixa e verifica tudo, mostra o que aconteceria e não altera nada
set -euo pipefail

repo="LordSigfrid/NikoDeck"
package="com.lordsigfrid.nikodeck"
settings_url="http://127.0.0.1:8765"

yes=0; phone=1; serial=""; autostart=1; start=1; extras=1; version=""; dry=0
tmp=""

if [ -t 1 ]; then c_step=$'\033[36m'; c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_off=$'\033[0m'
else c_step=""; c_ok=""; c_warn=""; c_err=""; c_off=""; fi
step() { printf '\n%s==> %s%s\n' "$c_step" "$1" "$c_off"; }
info() { printf '    %s\n' "$1"; }
ok() { printf '    %sOK  %s%s\n' "$c_ok" "$1" "$c_off"; }
caution() { printf '    %s!   %s%s\n' "$c_warn" "$1" "$c_off"; }
die() {
  printf '\n%sA instalação parou: %s%s\n' "$c_err" "$1" "$c_off" >&2
  printf '%sAjuda: https://github.com/%s#quick-start  -  problemas: https://github.com/%s/issues%s\n' "$c_err" "$repo" "$repo" "$c_off" >&2
  exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# Questions go to the terminal even when the script itself arrives through a pipe (curl ... | bash).
tty_ok=0
if (: </dev/tty) 2>/dev/null; then tty_ok=1; fi

ask() { # ask "question" y|n -> 0 for yes; Portuguese (s/sim, n/não) and English (y/yes, n/no) answers both work
  local question="$1" default="$2" hint answer
  if [ "$default" = y ]; then hint="[S/n]"; else hint="[s/N]"; fi
  if [ "$yes" = 1 ] || [ "$tty_ok" = 0 ]; then
    if [ "$default" = y ]; then info "$question $hint -> sim (padrão)"; return 0; fi
    info "$question $hint -> não (padrão)"; return 1
  fi
  while :; do
    printf '    %s %s ' "$question" "$hint" >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
    case "$answer" in
      "") if [ "$default" = y ]; then return 0; else return 1; fi ;;
      [SsYy]|[Ss][Ii][Mm]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Aa][Oo]|[Nn]ão|[Nn]ÃO|[Nn][Oo]) return 1 ;;
    esac
  done
}

read_line() { # read_line "prompt" -> the answer on stdout (empty without a terminal)
  local answer=""
  if [ "$yes" = 0 ] && [ "$tty_ok" = 1 ]; then
    printf '    %s ' "$1" >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
  fi
  printf '%s' "$answer"
}

download() { # download url file
  if have curl; then curl -fsSL --retry 3 --proto '=https' --proto-redir '=https' -A nikodeck-setup -o "$2" "$1"
  else wget -q --https-only -U nikodeck-setup -O "$2" "$1"; fi
}

download_text() { # download_text url -> stdout
  if have curl; then curl -fsSL --retry 2 --proto '=https' -A nikodeck-setup "$1"
  else wget -q --https-only -U nikodeck-setup -O - "$1"; fi
}

local_up() { # is the agent answering on this computer?
  if have curl; then curl -fsS --max-time 2 "$settings_url/api/info" >/dev/null 2>&1
  else wget -q -T 2 -O /dev/null "$settings_url/api/info" 2>/dev/null; fi
}

sha256_of() {
  if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

check_sum() { # check_sum file sums-file
  local name expected actual
  name="$(basename "$1")"
  expected="$(awk -v n="$name" '{ f = $2; sub(/^\*/, "", f); if (f == n) { print tolower($1); exit } }' "$2")"
  if [ -z "$expected" ]; then
    printf '%s\n' "$name não está na lista de checksums da versão." >&2
    return 1
  fi
  actual="$(sha256_of "$1" | tr 'A-F' 'a-f')"
  if [ "$actual" != "$expected" ]; then
    printf '%s\n' "$name não confere com o checksum da versão (esperado $expected, obtido $actual)." >&2
    return 1
  fi
  ok "$name confere com o checksum da versão"
}

version_ge() { # version_ge 2.93.1 2.93.0 -> 0 when the first is at least the second
  local IFS=. i x y
  local -a a b
  read -r -a a <<<"$1"
  read -r -a b <<<"$2"
  for i in 0 1 2; do
    x="${a[i]:-0}"; y="${b[i]:-0}"
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 0
}

check_provenance() {
  local out ghv
  if ! have gh || ! gh auth status >/dev/null 2>&1; then
    info "Origem do build não verificada (requer o GitHub CLI com login): gh attestation verify $(basename "$1") --repo $repo"
    return
  fi
  # gh 2.92.0 and earlier send the GitHub token to the TUF mirrors during verification (GHSA-8xvp-7hj6-mcj9)
  ghv="$(gh --version 2>/dev/null | sed -n 's/^gh version \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' | head -n1)" || ghv=""
  if [ -z "$ghv" ] || ! version_ge "$ghv" 2.93.0; then
    caution "Origem do build não verificada: o GitHub CLI ${ghv:-(versão desconhecida)} tem uma falha de segurança no \"gh attestation\""
    caution "(ele envia seu token do GitHub para outro servidor). Atualize para a versão 2.93.0 ou mais recente."
    return
  fi
  if out="$(gh attestation verify "$1" --repo "$repo" 2>&1)"; then
    ok "$(basename "$1") foi gerado pelo fluxo de release deste repositório (atestado do GitHub)"
  elif printf '%s' "$out" | grep -qi 'unknown command'; then
    info 'Origem do build não verificada: este GitHub CLI é antigo demais para o "gh attestation".'
  else
    die "não foi possível verificar a origem do build de $(basename "$1"); nada foi instalado. $out"
  fi
}

latest_version() {
  local v=""
  v="$(download_text "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)" || v=""
  # the API allows 60 requests an hour per address; the release page redirects to the newest tag as well
  if [ -z "$v" ] && have curl; then
    v="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest" 2>/dev/null | sed -n 's#.*/tag/##p')" || v=""
  fi
  printf '%s' "$v"
}

designated() { # designated binary -> its designated requirement (what macOS ties permissions to), or nothing
  codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'
}
unzip_to() { # unzip_to zip dir
  mkdir -p "$2"
  if have unzip; then unzip -q -o "$1" -d "$2"
  elif have bsdtar; then bsdtar -xf "$1" -C "$2"
  elif have python3; then python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"
  else die "não foi possível descompactar o arquivo baixado: instale o unzip (por exemplo: sudo apt install unzip) e execute a instalação de novo."; fi
}

# ---- packages ---------------------------------------------------------------------------------------------------
pm=""
apt_updated=0
detect_pm() {
  if [ "$os" = osx ]; then
    if have brew; then pm=brew; fi
    return
  fi
  for p in apt-get dnf pacman zypper; do
    if have "$p"; then pm="$p"; return; fi
  done
}

pkg_install() { # pkg_install package... (one at a time, so a missing one does not stop the others)
  local p failed=0
  for p in "$@"; do
    case "$pm" in
      brew) brew install "$p" >/dev/null || failed=1 ;;
      apt-get)
        if [ "$apt_updated" = 0 ]; then sudo apt-get update -qq || true; apt_updated=1; fi
        sudo apt-get install -y -qq "$p" >/dev/null || failed=1 ;;
      dnf) sudo dnf install -y -q "$p" >/dev/null || failed=1 ;;
      pacman) sudo pacman -S --needed --noconfirm "$p" >/dev/null || failed=1 ;;
      zypper) sudo zypper --non-interactive --quiet install "$p" >/dev/null || failed=1 ;;
      *) failed=1 ;;
    esac
  done
  return "$failed"
}

sudo_note() {
  if [ "$pm" != brew ] && [ "$(id -u)" != 0 ]; then
    have sudo || { caution "o sudo não está disponível, então não é possível instalar pacotes."; return 1; }
    info "Isto usa o sudo ($pm); sua senha pode ser pedida."
  fi
  return 0
}

find_adb() {
  local c
  if have adb; then command -v adb; return; fi
  for c in "$HOME/Android/Sdk/platform-tools/adb" "$HOME/Library/Android/sdk/platform-tools/adb" \
    /opt/homebrew/bin/adb /usr/local/bin/adb /usr/bin/adb /usr/lib/android-sdk/platform-tools/adb; do
    if [ -x "$c" ]; then printf '%s' "$c"; return; fi
  done
}

install_adb() {
  info 'O adb (Android SDK Platform-Tools) é um software do Google sob os termos do Android SDK:'
  info 'https://developer.android.com/studio/releases/platform-tools'
  case "$pm" in
    brew) brew install --cask android-platform-tools >/dev/null || true ;;
    apt-get) if sudo_note; then pkg_install adb android-sdk-platform-tools-common || true; fi ;;
    dnf|zypper) if sudo_note; then pkg_install android-tools || true; fi ;;
    pacman) if sudo_note; then pkg_install android-tools android-udev || true; fi ;;
  esac
  if [ -n "$(find_adb)" ]; then return; fi
  # no package manager (or it failed): Google's download, in a folder NikoDeck looks in
  local url dest
  if [ "$os" = osx ]; then url="https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"; dest="$HOME/Library/Android/sdk"
  elif [ "$arch" = x64 ]; then url="https://dl.google.com/android/repository/platform-tools-latest-linux.zip"; dest="$HOME/Android/Sdk"
  else caution "O Google só oferece o adb para Linux x64; instale o pacote adb / android-tools da sua distribuição."; return; fi
  info "Baixando as platform tools do Google para $dest/platform-tools ..."
  if download "$url" "$tmp/platform-tools.zip"; then unzip_to "$tmp/platform-tools.zip" "$dest"; fi
  chmod +x "$dest/platform-tools/adb" 2>/dev/null || true
}

offer_extras() {
  local missing="" reasons=""
  if [ "$os" = osx ]; then
    if ! have nowplaying-cli; then missing="nowplaying-cli"; reasons="nowplaying-cli (Tocando agora para qualquer app, com capa)"; fi
    if [ -n "$missing" ] && [ "$pm" != brew ]; then
      info "Opcional: $reasons. Instale o Homebrew (https://brew.sh) e depois: brew install nowplaying-cli"
      return
    fi
  else
    if ! have playerctl; then missing="playerctl"; reasons="playerctl (Tocando agora e seus controles)"; fi
    if ! have wpctl && ! have pactl; then
      case "$pm" in pacman) missing="$missing libpulse" ;; *) missing="$missing pulseaudio-utils" ;; esac
      reasons="$reasons, pactl (volume)"
    fi
    if ! have xprintidle && [ -n "${DISPLAY:-}" ]; then missing="$missing xprintidle"; reasons="$reasons, xprintidle (tempo ocioso no X11)"; fi
    if [ -n "$missing" ] && [ -z "$pm" ]; then info "Opcional, pelo seu gerenciador de pacotes: ${reasons#, }"; return; fi
  fi
  [ -n "$missing" ] || { ok "Todos os auxiliares opcionais estão instalados"; return; }
  info "Auxiliares opcionais para mais widgets: ${reasons#, }"
  if [ "$dry" = 1 ]; then info "Ofereceria instalar: $missing"; return; fi
  if ask "Instalar agora?" y; then
    # shellcheck disable=SC2086 # one package name per word
    if sudo_note && pkg_install $missing; then ok "Instalados: $missing"
    else caution "Alguns não puderam ser instalados (nem toda distribuição empacota todos); o NikoDeck funciona sem eles."; fi
  fi
}

# ---- agent ------------------------------------------------------------------------------------------------------
unit="$HOME/.config/systemd/user/nikodeck.service"   # where scripts/uninstall.sh looks
plist="$HOME/Library/LaunchAgents/com.lordsigfrid.nikodeck.agent.plist"

systemd_user() { have systemctl && systemctl --user show-environment >/dev/null 2>&1; }

remove_autostart() {
  if [ "$os" = linux ] && [ -f "$unit" ]; then
    systemctl --user disable nikodeck.service >/dev/null 2>&1 || true
    rm -f "$unit"
    info 'Serviço de login removido; o NikoDeck não inicia mais ao entrar na sessão.'
  fi
  if [ "$os" = osx ] && [ -f "$plist" ]; then
    rm -f "$plist"
    info 'Item de login removido; o NikoDeck não inicia mais ao entrar na sessão.'
  fi
}

# a path or an assignment as one quoted systemd word (the install path can contain spaces through XDG_DATA_HOME);
# "$" is left alone: systemd does not expand it in the executable path, and paths with "$" are refused below
systemd_quote() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g')"
}

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

stop_agent() {
  if [ "$os" = linux ] && systemd_user; then systemctl --user stop nikodeck.service 2>/dev/null || true; fi
  if [ "$os" = osx ] && [ -f "$plist" ]; then launchctl unload "$plist" 2>/dev/null || true; fi
  pkill -x NikoDeck 2>/dev/null || true
  local i=0
  while pgrep -x NikoDeck >/dev/null 2>&1 && [ "$i" -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
}

write_autostart() {
  if [ "$os" = linux ]; then
    if ! systemd_user; then
      caution "Não há sessão de usuário do systemd aqui, então o NikoDeck não pode iniciar sozinho ao entrar na sessão."
      caution "Em vez disso, adicione $app/NikoDeck aos aplicativos de inicialização do seu ambiente de trabalho."
      return 1
    fi
    local unsafe=0
    case "$app$HOME${XDG_DATA_HOME:-}${XDG_CONFIG_HOME:-}" in *'$'*|*'
'*) unsafe=1 ;; esac
    # systemd also refuses an executable path with a quote, an apostrophe or a backslash ("special characters"),
    # e.g. an AD home such as /home/o'brien@corp.example: the unit would be enabled but never start
    case "$app" in *'"'*|*"'"*|*[\\]*) unsafe=1 ;; esac
    if [ "$unsafe" = 1 ]; then
      caution "O caminho da instalação ou das configurações contém \$, aspas, uma barra invertida ou uma quebra de linha, que não podem ser passados com segurança a um serviço do systemd;"
      caution "em vez disso, adicione $app/NikoDeck aos aplicativos de inicialização do seu ambiente de trabalho."
      remove_autostart   # an older unit would otherwise start the previous install at login and in start_agent
      return 1
    fi
    # the service must see the same XDG folders as this shell, or the agent would use other settings and install folders
    local env_lines="" v
    for v in XDG_DATA_HOME XDG_CONFIG_HOME; do
      if [ -n "${!v:-}" ]; then env_lines="${env_lines}Environment=$(systemd_quote "$v=${!v}")
"; fi
    done
    mkdir -p "$(dirname "$unit")"
    cat > "$unit" <<EOF
[Unit]
Description=NikoDeck agent (desk panel for an Android phone)
After=graphical-session.target

[Service]
ExecStart=$(systemd_quote "$app/NikoDeck")
Restart=on-failure
RestartSec=5
${env_lines}
[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable nikodeck.service >/dev/null 2>&1
    ok "Serviço de usuário do systemd: $unit"
  else
    mkdir -p "$(dirname "$plist")"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.lordsigfrid.nikodeck.agent</string>
  <key>ProgramArguments</key><array><string>$(xml_escape "$app/NikoDeck")</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
EOF
    ok "Agente do launchd: $plist"
  fi
}

start_agent() {
  if [ "$os" = linux ] && [ -f "$unit" ] && systemd_user; then systemctl --user restart nikodeck.service && return; fi
  if [ "$os" = osx ] && [ -f "$plist" ]; then launchctl load "$plist" 2>/dev/null && return; fi
  nohup "$app/NikoDeck" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# ---- phone ------------------------------------------------------------------------------------------------------
phone_help() {
  info 'No celular (Android 5.0 ou mais recente):'
  info '  1. Configurações > Sobre o telefone: toque 7 vezes em "Número da versão" para ativar as Opções do desenvolvedor.'
  info '  2. Configurações > Sistema > Opções do desenvolvedor: ative a "Depuração USB".'
  info '     Xiaomi / Redmi / POCO: ative também "Instalar via USB" e "Depuração USB (Configurações de segurança)".'
  info '  3. Conecte o celular com um cabo de dados (alguns cabos só carregam) e desbloqueie a tela.'
  info '  4. Em "Permitir a depuração USB?", toque em Permitir e marque "Sempre permitir neste computador".'
}

linux_usb_help() {
  caution 'O Linux ainda não deixa o adb acessar o celular ("no permissions"). Normalmente uma destas opções resolve:'
  caution '  - as regras do udev: Debian/Ubuntu android-sdk-platform-tools-common, Arch android-udev, Fedora android-tools;'
  caution "  - o grupo plugdev: sudo usermod -aG plugdev $USER, depois saia da sessão e entre de novo;"
  caution '  - desconecte o celular e conecte de novo, depois: adb kill-server'
  caution '  Guia: https://developer.android.com/studio/run/device#setting-up'
}

select_phone() { # prints the serial of the one authorised phone, or nothing to skip
  local wanted="$serial" devices ready count answer
  "$adb" start-server >/dev/null 2>&1 || true
  while :; do
    devices="$("$adb" devices 2>/dev/null | awk -F'\t' 'NF >= 2 { print $1 "\t" $2 }')"
    if [ -n "$wanted" ]; then devices="$(printf '%s\n' "$devices" | awk -F'\t' -v s="$wanted" '$1 == s')"; fi
    # only phones on a cable are picked automatically, not emulators or wireless-debugging connections
    ready="$(printf '%s\n' "$devices" | awk -F'\t' -v w="$wanted" '$2 == "device" && (w != "" || $1 !~ /^emulator-|:|\._tcp/) { print $1 }')"
    count="$(printf '%s' "$ready" | grep -c . || true)"
    if [ "$count" = 1 ]; then printf '%s' "$ready"; return; fi
    if [ "$count" -gt 1 ]; then
      caution "Há vários celulares conectados: $(printf '%s' "$ready" | tr '\n' ' ')" >&2
      if [ "$yes" = 1 ] || [ "$tty_ok" = 0 ]; then caution 'Execute a instalação de novo com --serial <id> para escolher um; o app do celular foi pulado.' >&2; return; fi
      wanted="$(read_line 'Digite o número de série do celular a usar (vazio para pular):')"
      [ -n "$wanted" ] || return 0   # skipping is not an error: main runs under set -e
      continue
    fi
    if [ -z "$devices" ]; then
      if [ -n "$wanted" ]; then caution "Nenhum celular com o número de série $wanted está conectado." >&2; else caution 'Nenhum celular conectado via USB ainda.' >&2; fi
      phone_help >&2
    else
      printf '%s\n' "$devices" | while IFS="$(printf '\t')" read -r s state; do
        case "$state" in
          unauthorized) caution "$s: aguardando você permitir a depuração USB no celular (desbloqueie e toque em Permitir)." >&2 ;;
          offline) caution "$s: offline. Desconecte o cabo e conecte de novo." >&2 ;;
          device) caution "$s: um emulador ou uma conexão sem fio; só é usado se você passar --serial $s." >&2 ;;
          no\ permissions*) linux_usb_help >&2 ;;
          *) caution "$s: $state" >&2 ;;
        esac
      done
    fi
    if [ "$yes" = 1 ] || [ "$tty_ok" = 0 ]; then caution 'O app do celular foi pulado (nenhum celular pronto).' >&2; return; fi
    answer="$(read_line 'Pressione Enter para verificar de novo, ou digite P para pular o celular:')"
    case "$answer" in [Pp]|[Pp][Uu][Ll][Aa][Rr]|[Ss][Kk][Ii][Pp]) return ;; esac  # not a bare s: it means "sim" in the other prompts
    "$adb" reconnect offline >/dev/null 2>&1 || true
  done
}

install_phone_app() { # install_phone_app apk serial -> 0 when installed
  local apk="$1" device="$2" level out
  level="$("$adb" -s "$device" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r[:space:]')"
  case "$level" in ''|*[!0-9]*) level=0 ;; esac
  if [ "$level" -gt 0 ] && [ "$level" -lt 21 ]; then
    caution "Este celular tem Android API $level; o NikoDeck precisa do Android 5.0 (API 21) ou mais recente. O app não foi instalado."
    return 1
  fi
  info "Instalando $(basename "$apk") em $device (o celular pode pedir confirmação) ..."
  out="$("$adb" -s "$device" install -r "$apk" 2>&1)" || true
  case "$out" in
    *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
      caution 'O celular tem um app NikoDeck assinado com outra chave (por exemplo, um que você mesmo compilou).'
      caution 'Ele foi mantido como está, com seus dados. Para trocar pelo app oficial, desinstale o NikoDeck do celular'
      caution '(isso apaga as configurações dele) e execute a instalação de novo.'
      return 1 ;;
    *INSTALL_FAILED_VERSION_DOWNGRADE*) ok 'O celular já tem um app NikoDeck mais novo; ele foi mantido.'; return 0 ;;
    *INSTALL_FAILED_USER_RESTRICTED*|*INSTALL_FAILED_ABORTED*)
      caution 'O celular recusou a instalação. Confirme no celular; celulares Xiaomi / Redmi / POCO também precisam de'
      caution '"Instalar via USB" nas Opções do desenvolvedor. Depois execute a instalação de novo.'
      return 1 ;;
    *Success*) ;;
    *) caution "Não foi possível instalar o app: $(printf '%s' "$out" | tr '\n' ' ')"; return 1 ;;
  esac
  ok 'App NikoDeck instalado no celular'
  "$adb" -s "$device" shell am start -n "$package/net.oxog.phonebox.deskpanel.MainActivity" >/dev/null 2>&1 || true
  return 0
}

# ---- main -------------------------------------------------------------------------------------------------------
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) yes=1 ;;
      --no-phone) phone=0 ;;
      --serial) [[ $# -ge 2 && -n $2 && $2 != -* ]] || die "--serial precisa de um valor"; serial="$2"; shift ;;
      --no-autostart) autostart=0 ;;
      --no-start) start=0 ;;
      --no-extras) extras=0 ;;
      --version) [[ $# -ge 2 && -n $2 && $2 != -* ]] || die "--version precisa de um valor"; version="$2"; shift ;;
      --dry-run) dry=1 ;;
      -h|--help) sed -n '2,19p' "$0" 2>/dev/null || echo "Veja https://github.com/$repo#quick-start"; exit 0 ;;
      *) die "opção desconhecida: $1 (veja --help)" ;;
    esac
    shift
  done

  printf '\n%sInstalação do NikoDeck%s\n' "$c_step" "$c_off"
  if [ "$dry" = 1 ]; then printf '%sSimulação: baixa e verifica tudo, sem alterar nada.%s\n' "$c_warn" "$c_off"; fi

  step 'Verificando este computador'
  [ "$(id -u)" != 0 ] || die "não execute a instalação como root nem com sudo. O NikoDeck roda com o seu usuário (as configurações, a inicialização automática e o pareamento do celular pertencem à sua conta); a instalação pede o sudo sozinha quando instala pacotes."
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=osx ;;
    *) die "este script é para Linux e macOS; no Windows, execute o setup.ps1 (veja https://github.com/$repo#quick-start)." ;;
  esac
  if [ "$os" = osx ]; then
    # a shell under Rosetta reports x86_64 on Apple silicon; the native build is the right one
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then arch=arm64; else arch=x64; fi
  else
    case "$(uname -m)" in
      x86_64|amd64) arch=x64 ;;
      aarch64|arm64) arch=arm64 ;;
      *) die "não existe build do NikoDeck para este processador ($(uname -m)); x64 e arm64 são suportados." ;;
    esac
    if [ -f /etc/alpine-release ] || case "$(ldd --version 2>&1 || true)" in *musl*) true ;; *) false ;; esac; then
      die "os builds do NikoDeck para Linux precisam da glibc; sistemas com musl, como o Alpine, ainda não são suportados."
    fi
  fi
  have curl || have wget || die "é preciso ter curl ou wget para baixar o NikoDeck."
  have sha256sum || have shasum || die "é preciso ter sha256sum (coreutils) ou shasum para verificar o arquivo baixado."
  rid="$os-$arch"
  detect_pm
  ok "$( [ "$os" = osx ] && echo "macOS $(sw_vers -productVersion 2>/dev/null)" || echo "Linux $(uname -r)"), $arch${pm:+, gerenciador de pacotes: $pm}"

  step 'Procurando a versão'
  local tag ver base
  tag="${version:-$(latest_version)}"
  [ -n "$tag" ] || die "não foi possível encontrar a versão mais recente no GitHub. Verifique a conexão com a internet ou use --version 0.9.8."
  ver="${tag#v}"
  printf '%s' "$ver" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "versão inesperada: '$tag'."
  base="https://github.com/$repo/releases/download/v$ver"
  ok "NikoDeck $ver ($rid)"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nikodeck-setup.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT

  step "Baixando o NikoDeck $ver"
  local zip_name="NikoDeckAgent-$ver-$rid.zip" sums
  sums="$tmp/SHA256SUMS-$ver.txt"
  download "$base/SHA256SUMS-$ver.txt" "$sums" || die "a versão $ver não foi encontrada ($base)."
  info "$zip_name (cerca de 45 MB) ..."
  download "$base/$zip_name" "$tmp/$zip_name" || die "o download falhou: $base/$zip_name"
  check_sum "$tmp/$zip_name" "$sums" || die "não foi possível verificar o agente baixado. Nada foi instalado."
  check_provenance "$tmp/$zip_name"
  unzip_to "$tmp/$zip_name" "$tmp/agent"
  chmod +x "$tmp/agent/NikoDeck"
  if [ "$os" = osx ]; then
    xattr -dr com.apple.quarantine "$tmp/agent" 2>/dev/null || true
    # release binaries are signed (with NikoDeck's own certificate since 0.9.22, ad hoc before); Apple silicon refuses
    # to run a binary without any signature
    codesign --verify "$tmp/agent/NikoDeck" >/dev/null 2>&1 || codesign --force --sign - "$tmp/agent/NikoDeck" >/dev/null 2>&1 || true
  fi
  local out
  if ! out="$("$tmp/agent/NikoDeck" --print-install-dir 2>&1)"; then
    die "este sistema não consegue executar o build $rid do NikoDeck: $out"
  fi
  app="$(printf '%s\n' "$out" | tail -n1)"
  case "$app" in /*/NikoDeck/app) ;; *) die "pasta de instalação inesperada informada pelo agente: $app" ;; esac
  local installed=""
  if [ -x "$app/NikoDeck" ]; then installed="present"; fi
  if [ -f "$app/NikoDeck.dll" ]; then
    info "Encontrada uma instalação a partir do código-fonte (scripts/install.sh): ela será substituída pela versão independente; as configurações ficam."
  elif [ -n "$installed" ]; then
    info "Encontrada uma instalação existente em $app: ela será substituída; as configurações ficam."
  fi
  if [ "$os" = osx ]; then
    info 'O agente é assinado com um certificado próprio, não com um Apple Developer ID, então o macOS pode perguntar sobre ele'
    info 'na primeira vez: permita que ele controle o Música ou o Spotify (Tocando agora) e, com o Wi-Fi ativado, aceite conexões de entrada.'
    # macOS ties the Accessibility permission to the signature's designated requirement: the same from release to
    # release since 0.9.22, but different from an older (ad hoc) build's, which changed with every build (#269)
    if [ -n "$installed" ] && [ "$(designated "$app/NikoDeck")" != "$(designated "$tmp/agent/NikoDeck")" ]; then
      info 'Se você o autorizou em Acessibilidade (atalhos que pressionam teclas), autorize mais uma vez: o macOS não aplica'
      info 'isso a este build. Em Ajustes do Sistema › Privacidade e Segurança › Acessibilidade, remova o NikoDeck com −'
      info 'e adicione-o de novo. As próximas atualizações mantêm a permissão.'
    fi
  fi

  step 'Verificando o adb (necessário para a conexão USB com o celular)'
  adb="$(find_adb)"
  if [ -n "$adb" ]; then ok "$adb"
  else
    caution 'O adb não está instalado. Sem ele o NikoDeck ainda funciona via Wi-Fi, mas não alcança o celular pelo USB'
    caution '(acordar o celular ao conectar, instalar e atualizar o app do celular, usar o USB quando o Wi-Fi cair).'
    if [ "$dry" = 1 ]; then info 'Ofereceria a instalação do adb.'
    elif ask 'Instalar o adb agora?' y; then
      install_adb
      adb="$(find_adb)"
      if [ -n "$adb" ]; then ok "adb instalado: $adb"; else caution 'Não foi possível instalar o adb; o NikoDeck vai funcionar só via Wi-Fi até ele ser instalado.'; fi
    fi
  fi

  if [ "$extras" = 1 ]; then
    step 'Auxiliares opcionais'
    offer_extras
  fi

  if [ "$dry" = 1 ]; then
    step 'Simulação concluída'
    info "Encerraria o agente em execução e instalaria o NikoDeck $ver em $app (as configurações ficam)."
    [ "$autostart" = 0 ] || info 'Perguntaria se o NikoDeck deve iniciar ao entrar na sessão.'
    [ "$phone" = 0 ] || info 'Ofereceria a instalação do app em um celular conectado via USB.'
    info 'Nada foi alterado.'
    return
  fi

  step "Instalando em $app"
  stop_agent
  mkdir -p "$(dirname "$app")"
  rm -rf "$app.new" "$app.old"
  cp -R "$tmp/agent" "$app.new"
  if [ -d "$app" ]; then mv "$app" "$app.old"; fi
  if ! mv "$app.new" "$app"; then
    if [ -d "$app.old" ]; then mv "$app.old" "$app"; fi
    die "a instalação falhou; a versão anterior foi restaurada."
  fi
  rm -rf "$app.old"
  ok "NikoDeck $ver instalado"

  if [ "$autostart" = 1 ]; then
    step 'Iniciar ao entrar na sessão'
    if ask 'Iniciar o NikoDeck quando você entrar na sessão?' y; then write_autostart || true
    else remove_autostart; fi
  else
    remove_autostart
  fi

  local phone_done=0 device apk
  if [ "$phone" = 1 ]; then
    step 'App do celular'
    if [ -z "$adb" ]; then caution 'Pulado: o adb não está instalado.'
    elif ask 'Instalar agora o app NikoDeck em um celular conectado via USB?' y; then
      info 'A depuração USB permite que um computador autorizado controle o celular. Autorize apenas os seus computadores;'
      info 'você pode revogá-los em Opções do desenvolvedor > "Revogar autorizações de depuração USB".'
      device="$(select_phone)"
      if [ -n "$device" ]; then
        apk="$tmp/NikoDeck-$ver.apk"
        if ! download "$base/NikoDeck-$ver.apk" "$apk"; then
          caution "App do celular pulado: o download falhou ($base/NikoDeck-$ver.apk)."
        elif ! check_sum "$apk" "$sums"; then
          caution 'App do celular pulado: não foi possível verificar o APK.'
        elif install_phone_app "$apk" "$device"; then
          phone_done=1
        fi
      fi
    fi
  fi

  if [ "$start" = 0 ]; then
    step 'Concluído (não iniciado)'
    info "Inicie com $app/NikoDeck"
  else
    step 'Iniciando o NikoDeck'
    start_agent
    local i=0 up=0
    while [ "$i" -lt 30 ]; do
      sleep 0.7
      if local_up; then up=1; break; fi
      i=$((i + 1))
    done
    if [ "$up" = 1 ]; then
      ok "O NikoDeck está em execução: configurações em $settings_url"
      if [ "$os" = osx ]; then open "$settings_url" >/dev/null 2>&1 || true
      elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && have xdg-open; then (xdg-open "$settings_url" >/dev/null 2>&1 &) || true; fi
    else
      caution "O agente não respondeu. Log dele: $(dirname "$app")/agent.log"
    fi
  fi

  step 'Bom saber'
  if [ "$phone_done" = 1 ]; then info 'Deixe o celular conectado: o NikoDeck acorda o celular e abre o painel.'
  elif [ "$phone" = 1 ]; then info 'App do celular depois: conecte o celular e use Configurações > Geral > Instalar app no celular, ou execute a instalação de novo.'; fi
  info 'Só Wi-Fi: instale o app pela página de versões no celular e, no computador, abra'
  info 'Configurações > Geral > Wi-Fi & Tailscale > Parear celular via Wi-Fi e escaneie o QR code.'
  if [ "$os" = linux ]; then info 'Com um firewall (ufw, firewalld), o Wi-Fi também precisa da porta TCP 8766 aberta na sua rede local.'; fi
  info "Até o Wi-Fi ser ativado, o NikoDeck só escuta neste computador. Todas as conexões que ele faz: https://github.com/$repo/blob/main/PRIVACY.md"
  info 'Atualizações: o NikoDeck se atualiza pelas Configurações. Execute a instalação de novo quando quiser para repará-lo.'
  info "Desinstalar: curl -fsSL https://raw.githubusercontent.com/$repo/main/scripts/uninstall.sh | bash -s -- [--purge] [--apk]"
}

# Everything runs from here, so a download cut off half way cannot run half a script.
main "$@"
