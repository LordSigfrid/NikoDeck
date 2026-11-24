#!/usr/bin/env bash
# Removes the NikoDeck agent on Linux / macOS.
#   ./scripts/uninstall.sh            # agent + autostart entry (settings are kept)
#   ./scripts/uninstall.sh --purge    # ... and the settings, logs and pushed data
#   ./scripts/uninstall.sh --apk      # ... and the panel app on the connected phone
set -euo pipefail
purge=0; apk=0
for a in "$@"; do
  case "$a" in
    --purge) purge=1 ;;
    --apk) apk=1 ;;
    -h|--help)
      printf '%s\n' 'Uso: uninstall.sh [--purge] [--apk]' \
        'Remove o agente e a inicialização automática. As configurações são mantidas, a menos que --purge seja usado.' \
        'Use --apk para remover também o app do celular conectado.'
      exit 0 ;;
    *) echo "opção desconhecida: $a (veja --help)" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" = Darwin ]; then
  plist="$HOME/Library/LaunchAgents/com.lordsigfrid.nikodeck.agent.plist"
  launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist"
  base="$HOME/Library/Application Support/NikoDeck"
  conf="$base"
else
  if command -v systemctl >/dev/null; then
    systemctl --user disable --now nikodeck.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/nikodeck.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  base="${XDG_DATA_HOME:-$HOME/.local/share}/NikoDeck"
  conf="${XDG_CONFIG_HOME:-$HOME/.config}/NikoDeck"
fi
pkill -x NikoDeck 2>/dev/null || true
rm -rf "$base/app" "$base/updates"
if [ "$purge" = 1 ]; then rm -rf "$base" "$conf"; fi
if [ "$apk" = 1 ] && command -v adb >/dev/null; then adb uninstall com.lordsigfrid.nikodeck || true; fi
echo "NikoDeck removido."
