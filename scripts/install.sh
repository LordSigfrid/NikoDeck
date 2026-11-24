#!/usr/bin/env bash
# Instalador do PhoneBox para Linux e macOS.
#
#   ./scripts/install.sh                 # compila e instala o agente, depois o inicia
#   ./scripts/install.sh --autostart     # ... e o inicia ao entrar na sessão (serviço de usuário do systemd / agente do launchd)
#   ./scripts/install.sh --apk           # ... e instala o app do painel no celular conectado
#   ./scripts/install.sh --serial <id>   # escolhe o celular quando há vários dispositivos conectados
#
# Requer o .NET 10 SDK (https://dotnet.microsoft.com/download) e o adb:
#   Ubuntu/Debian: sudo apt install adb       Fedora: sudo dnf install android-tools       macOS: brew install android-platform-tools
# Opcional, para mais widgets no Linux: playerctl (tocando agora), wireplumber ou pulseaudio-utils (volume), xprintidle.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
autostart=0; apk=0; serial=""
while [ $# -gt 0 ]; do
  case "$1" in
    --autostart) autostart=1 ;;
    --apk) apk=1 ;;
    --serial)
      if [[ $# -lt 2 || -z $2 || $2 == -* ]]; then
        echo "--serial precisa de um valor" >&2
        exit 2
      fi
      serial="$2"
      shift
      ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "opção desconhecida: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=osx ;;
  *) echo "Sistema não suportado: $(uname -s). No Windows, use o scripts/install.ps1." >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=x64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "Processador não suportado: $(uname -m)" >&2; exit 1 ;;
esac
rid="$os-$arch"

command -v dotnet >/dev/null || { echo "É necessário o .NET 10 SDK: https://dotnet.microsoft.com/download" >&2; exit 1; }

# the service files below need DOTNET_ROOT; Homebrew keeps the runtime in libexec, not next to the dotnet link
if [ -z "${DOTNET_ROOT:-}" ]; then
  if command -v brew >/dev/null && [ -d "$(brew --prefix dotnet 2>/dev/null)/libexec" ]; then
    export DOTNET_ROOT="$(brew --prefix dotnet)/libexec"
  else
    export DOTNET_ROOT="$(dirname "$(readlink -f "$(command -v dotnet)" 2>/dev/null || command -v dotnet)")"
  fi
fi

echo "==> Compilando o agente ($rid)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
dotnet publish "$root/agent/PhoneBox.Agent" -c Release -f net10.0 -r "$rid" --self-contained false -o "$tmp" --nologo -v q
app="$("$tmp/PhoneBoxAgent" --print-install-dir)"

systemd_quote() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g')"
}

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

if [ "$autostart" = 1 ] && [ "$os" = linux ]; then
  case "$app$DOTNET_ROOT${XDG_DATA_HOME:-}${XDG_CONFIG_HOME:-}" in
    *'$'*|*'
'*) echo 'O caminho da instalação ou das configurações não serve para a inicialização automática pelo systemd.' >&2; exit 1 ;;
  esac
  case "$app" in
    *'"'*|*"'"*|*[\\]*) echo 'O caminho da instalação não serve para a inicialização automática pelo systemd.' >&2; exit 1 ;;
  esac
fi

echo "==> Encerrando o agente em execução"
if [ "$os" = linux ] && command -v systemctl >/dev/null; then systemctl --user stop phonebox.service 2>/dev/null || true; fi
if [ "$os" = osx ]; then launchctl unload "$HOME/Library/LaunchAgents/net.oxog.phonebox.agent.plist" 2>/dev/null || true; fi
pkill -x PhoneBoxAgent 2>/dev/null || true
sleep 0.5

echo "==> Instalando em $app"
mkdir -p "$app"
cp -R "$tmp/." "$app/"
chmod +x "$app/PhoneBoxAgent"
if [ "$os" = osx ]; then codesign --force --deep --sign - "$app/PhoneBoxAgent" >/dev/null 2>&1 || true; fi # macOS refuses unsigned binaries it has quarantined

if [ "$autostart" = 1 ]; then
  if [ "$os" = linux ]; then
    echo "==> Adicionando um serviço de usuário do systemd (inicia ao entrar na sessão)"
    unit="$HOME/.config/systemd/user/phonebox.service"
    mkdir -p "$(dirname "$unit")"
    env_lines=""
    for name in DOTNET_ROOT XDG_DATA_HOME XDG_CONFIG_HOME; do
      if [ -n "${!name:-}" ]; then
        env_lines="${env_lines}Environment=$(systemd_quote "$name=${!name}")
"
      fi
    done
    cat > "$unit" <<EOF
[Unit]
Description=PhoneBox agent (desk panel for an Android phone)
After=graphical-session.target

[Service]
ExecStart=$(systemd_quote "$app/PhoneBoxAgent")
Restart=on-failure
RestartSec=5
${env_lines}

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now phonebox.service
  else
    echo "==> Adicionando um agente do launchd (inicia ao entrar na sessão)"
    plist="$HOME/Library/LaunchAgents/net.oxog.phonebox.agent.plist"
    mkdir -p "$(dirname "$plist")"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>net.oxog.phonebox.agent</string>
  <key>ProgramArguments</key><array><string>$(xml_escape "$app/PhoneBoxAgent")</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>DOTNET_ROOT</key><string>$(xml_escape "$DOTNET_ROOT")</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
EOF
    launchctl load "$plist"
  fi
else
  echo "==> Iniciando o agente"
  nohup "$app/PhoneBoxAgent" >/dev/null 2>&1 &
fi

if [ "$apk" = 1 ]; then
  adb="$(command -v adb || true)"
  [ -n "$adb" ] || { echo "adb não encontrado (veja o início deste script)" >&2; exit 1; }
  built="$root/android/app/build/outputs/apk/release/app-release.apk"
  sources="$root/android/app/src"
  apkfile=""
  for candidate in "$root"/dist/PhoneBox-*.apk "$built"; do
    if [ -f "$candidate" ] && { [ -z "$apkfile" ] || [ "$candidate" -nt "$apkfile" ]; }; then
      apkfile="$candidate"
    fi
  done
  if [ -z "$apkfile" ] || { [ -d "$sources" ] && [ -n "$(find "$sources" -type f -newer "$apkfile" -print -quit)" ]; }; then
    echo "==> Compilando o APK (requer o Android SDK)"
    (cd "$root/android" && chmod +x gradlew && ./gradlew assembleRelease --console=plain -q)
    apkfile="$built"
  fi
  echo "==> Instalando $(basename "$apkfile") no celular"
  # Bash 3.2 treats an empty array as unset under nounset (the macOS system shell).
  if [ -n "$serial" ]; then
    "$adb" -s "$serial" install -r "$apkfile"
    "$adb" -s "$serial" shell am start -n net.oxog.phonebox.deskpanel/.MainActivity >/dev/null
  else
    "$adb" install -r "$apkfile"
    "$adb" shell am start -n net.oxog.phonebox.deskpanel/.MainActivity >/dev/null
  fi
fi

echo "O PhoneBox está em execução. Configurações: http://127.0.0.1:8765"
