# Xbox One Controller 1537 (USB 045e:02d1) raw input con libusb/PyUSB/IOKit

Questa repository contiene tre implementazioni per comunicare con un controller Xbox One modello **1537** via USB:

- `xbox1537_pyusb.py` (Python + PyUSB) — cross-platform
- `xbox1537_libusb.c` (C + libusb-1.0) — cross-platform
- `xbox1537_iokit.m` (Objective-C + IOKit) — **macOS nativo**, nessuna dipendenza esterna

> Nota: il protocollo non è HID standard; i pacchetti sono in stile GIP/XUSB e il contenuto può variare con firmware e revisione.

## 1) Prerequisiti

### macOS

**Opzione A — IOKit nativo (consigliata)**

Non serve installare nulla. Compila direttamente:

```bash
clang -O2 -Wall -framework IOKit -framework CoreFoundation \
      xbox1537_iokit.m -o xbox1537_iokit
```

**Opzione B — libusb/PyUSB**

Richiede [Homebrew](https://brew.sh):

```bash
brew install libusb
python3 -m pip install pyusb
```

Compilazione C:

```bash
gcc -O2 -Wall -Wextra xbox1537_libusb.c -o xbox1537_libusb \
    $(pkg-config --cflags --libs libusb-1.0)
```

> ⚠️ **Su macOS libusb/PyUSB hanno un problema noto:** il sistema carica automaticamente un driver kernel che blocca l'accesso USB al controller. Vedi la sezione [Troubleshooting macOS](#7-troubleshooting-macos) per le soluzioni.

### Linux

- Python 3 + `pyusb`
- `libusb-1.0-0-dev` per compilare C
- Permessi USB (esecuzione come root o regole udev)

Installazione tipica:

```bash
python3 -m pip install pyusb
sudo apt-get install -y libusb-1.0-0-dev build-essential
```

Compilazione C:

```bash
gcc -O2 -Wall -Wextra xbox1537_libusb.c -o xbox1537_libusb -lusb-1.0
```

Esecuzione:

```bash
python3 xbox1537_pyusb.py
./xbox1537_libusb
```

## 2) Strategia di comunicazione

1. Enumerare il device `VID=0x045E`, `PID=0x02D1`
2. Aprire il device e fare claim dell'interfaccia (di solito 0)
3. Trovare endpoint interrupt IN/OUT reali interrogando i descriptor
4. Inviare uno o più pacchetti di handshake/enable input su endpoint OUT
5. Leggere pacchetti raw da endpoint IN in loop e decodificare i campi principali

## 3) Handshake (pratico)

Nel codice trovi una lista di frame candidati (`HANDSHAKE_CANDIDATES`).
Il primo più comune è:

```text
05 20 00 01 00
```

Se non ricevi input:

- prova gli altri frame in lista,
- fai cattura USB su Windows (USBPcap + Wireshark) durante plug-in del controller,
- replica in Linux/macOS gli stessi byte/ordine/timing.

## 4) Interpretazione report input (frame da 18+ byte)

Per molti controller 1537 cablati il frame input frequente è simile a:

- `data[0]`: tipo report (spesso `0x20`)
- `data[4:6]`: bitfield pulsanti (little-endian)
- `data[6]`: LT (0..255)
- `data[7]`: RT (0..255)
- `data[8:10]`: LX (int16 little-endian)
- `data[10:12]`: LY (int16 little-endian)
- `data[12:14]`: RX (int16 little-endian)
- `data[14:16]`: RY (int16 little-endian)

Mappatura bit pulsanti usata negli esempi:

- bit 0: D-Pad Up
- bit 1: D-Pad Down
- bit 2: D-Pad Left
- bit 3: D-Pad Right
- bit 4: Start/Menu
- bit 5: Back/View
- bit 6: Left Stick Click
- bit 7: Right Stick Click
- bit 8: LB
- bit 9: RB
- bit 10: Xbox/Guide
- bit 12: A
- bit 13: B
- bit 14: X
- bit 15: Y

> Attenzione: alcuni firmware possono cambiare offset/bit. Se i valori non tornano, confronta raw dump e azioni manuali.

## 5) Piano di test/validazione consigliato

1. **Enumerazione**: stampa descriptor e verifica endpoint IN/OUT interrupt.
2. **Handshake**: invia frame candidati e controlla ACK o avvio stream input.
3. **Idle test**: senza toccare il pad, registra 2-3 secondi di frame per baseline.
4. **Single-button test**: premi un solo tasto (A), verifica che cambi un solo bit.
5. **Axis sweep**: muovi LX da sinistra a destra e verifica range ~`-32768..32767`.
6. **Trigger ramp**: premi LT/RT gradualmente e verifica range `0..255`.
7. **Debounce/logging**: stampa solo variazioni di stato per debugging pulito.

## 6) Debug pratico

- Se `claim_interface` fallisce su macOS, vedi sezione sotto.
- Se `claim_interface` fallisce su Linux, stacca eventuale driver kernel (`detach_kernel_driver`) o usa root.
- Se timeout di lettura:
  - verifica endpoint corretto,
  - verifica handshake,
  - prova timeout più alto (es. 1000 ms).
- Se ricevi frame ma decode errato, logga hex completo e ricalibra gli offset.

## 7) Troubleshooting macOS

Su macOS il sistema carica automaticamente un driver kernel (es. `AppleUSBHIDDriver`) che "reclama" il controller Xbox, impedendo a libusb/PyUSB di accedere al device.

### Soluzione 1 — Usare la versione IOKit nativa (consigliata)

L'implementazione `xbox1537_iokit.m` usa le API native Apple e bypassa completamente il problema:

```bash
clang -O2 -Wall -framework IOKit -framework CoreFoundation \
      xbox1537_iokit.m -o xbox1537_iokit
./xbox1537_iokit
# oppure: sudo ./xbox1537_iokit
```

Usa `USBDeviceOpenSeize` per prendere il controllo del device anche se un driver kernel lo ha già reclamato.

### Soluzione 2 — Eseguire con sudo

```bash
sudo python3 xbox1537_pyusb.py
sudo ./xbox1537_libusb
```

### Soluzione 3 — Scaricare il kext manualmente

Usa lo script incluso per identificare e scaricare il driver kernel:

```bash
sudo ./unload_xbox_kext.sh
# poi esegui normalmente:
./xbox1537_libusb
python3 xbox1537_pyusb.py
```

> ⚠️ I kext vengono ricaricati al reboot o quando ricolleghi il controller.

## 8) Pubblicazione su GitHub

```bash
git remote add origin https://github.com/<tuo-utente>/<tuo-repo>.git
git push -u origin main
```

### Script rapido (opzionale)

```bash
GITHUB_REPO="https://github.com/<tuo-utente>/<tuo-repo>.git" ./publish_to_github.sh
```