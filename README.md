# Xbox One Controller 1537 (USB 045e:02d1) raw input con libusb/PyUSB

Questa repository contiene due esempi minimi per comunicare con un controller Xbox One modello **1537** via USB:

- `xbox1537_pyusb.py` (Python + PyUSB)
- `xbox1537_libusb.c` (C + libusb-1.0)

> Nota: il protocollo non è HID standard; i pacchetti sono in stile GIP/XUSB e il contenuto può variare con firmware e revisione.

## 1) Prerequisiti

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

- Se `claim_interface` fallisce, stacca eventuale driver kernel (`detach_kernel_driver`) o usa root.
- Se timeout di lettura:
  - verifica endpoint corretto,
  - verifica handshake,
  - prova timeout più alto (es. 1000 ms).
- Se ricevi frame ma decode errato, logga hex completo e ricalibra gli offset.


## 7) Pubblicazione su GitHub

In questa environment non è configurato un remote GitHub di default. Per pubblicare i file:

```bash
git remote add origin https://github.com/<tuo-utente>/<tuo-repo>.git
git push -u origin work
```

Se il repository è privato, usa autenticazione via token (PAT) o SSH key.

Verifica finale:

```bash
git remote -v
git log --oneline -n 3
```


### Script rapido (opzionale)

Per evitare errori manuali puoi usare lo script incluso:

```bash
GITHUB_REPO="https://github.com/<tuo-utente>/<tuo-repo>.git" ./publish_to_github.sh
```

Opzioni:

```bash
REMOTE_NAME=origin BRANCH=work GITHUB_REPO="https://github.com/<tuo-utente>/<tuo-repo>.git" ./publish_to_github.sh
```