#!/usr/bin/env bash
# unload_xbox_kext.sh — Scarica il driver kernel che blocca il controller Xbox
#
# Uso:  sudo ./unload_xbox_kext.sh
#
# Su macOS il sistema carica automaticamente un driver (es. AppleUSBHIDDriver)
# quando colleghi un controller Xbox via USB. Questo impedisce a libusb/PyUSB
# di accedere al device. Questo script identifica e scarica quel driver.
set -euo pipefail

VID="045e"
PID="02d1"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Questo script è solo per macOS."
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Errore: serve root. Esegui con:  sudo $0"
  exit 1
fi

echo "=== Cercando controller Xbox (VID=${VID} PID=${PID})... ==="

# Cerca il device nella IORegistry
ioreg_output=$(ioreg -p IOUSB -l -w0 2>/dev/null || true)

if ! echo "$ioreg_output" | grep -qi "xbox\|${VID}.*${PID}\|02d1"; then
  echo "Controller Xbox non trovato collegato via USB."
  echo "Collega il controller e riprova."
  exit 1
fi

echo "Controller trovato nella IORegistry."

# Cerca kext che potrebbero catturare il device
echo ""
echo "=== Kext potenzialmente in conflitto: ==="

# Lista di kext noti che catturano controller USB HID
CANDIDATE_KEXTS=(
  "com.apple.driver.usb.IOUSBHostHIDDevice"
  "com.apple.iokit.IOUSBHIDDriver"
  "com.apple.driver.AppleUSBHIDKeyboard"
  "com.apple.driver.usb.cdc"
)

unloaded=0
for kext in "${CANDIDATE_KEXTS[@]}"; do
  if kextstat 2>/dev/null | grep -q "$kext"; then
    echo "  Trovato: $kext"
    echo "  Tentativo di unload..."
    if kextunload -b "$kext" 2>/dev/null; then
      echo "  ✅ Scaricato: $kext"
      ((unloaded++))
    else
      echo "  ⚠️  Non scaricabile (potrebbe essere in uso da altri device): $kext"
    fi
  fi
done

if [[ $unloaded -eq 0 ]]; then
  echo ""
  echo "Nessun kext standard trovato/scaricabile."
  echo ""
  echo "Alternativa: prova a resettare il claim con IOKit:"
  echo "  1) Scollega e ricollega il controller"
  echo "  2) Esegui immediatamente:  sudo ./xbox1537_libusb"
  echo "     oppure:                 sudo python3 xbox1537_pyusb.py"
  echo ""
  echo "Se non funziona, usa la versione IOKit nativa:"
  echo "  clang -framework IOKit -framework CoreFoundation xbox1537_iokit.m -o xbox1537_iokit"
  echo "  ./xbox1537_iokit"
else
  echo ""
  echo "✅ $unloaded kext scaricati. Ora prova:"
  echo "  ./xbox1537_libusb"
  echo "  python3 xbox1537_pyusb.py"
  echo ""
  echo "⚠️  I kext verranno ricaricati al prossimo reboot o re-plug del device."
fi
