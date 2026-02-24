#!/usr/bin/env python3
"""
Esempio PyUSB per Xbox One Controller 1537 (045e:02d1).

Cosa fa:
1) trova/apre il dispositivo USB
2) individua endpoint interrupt IN/OUT
3) invia handshake candidati
4) legge i report raw in loop
5) decodifica campi comuni (buttons/triggers/sticks)
"""

from __future__ import annotations

import struct
import sys
import time
from typing import Dict, List, Optional, Tuple

import usb.core
import usb.util

VID = 0x045E
PID = 0x02D1
READ_TIMEOUT_MS = 500

# Frame candidati osservati in varie implementazioni reverse-engineered.
# Non tutti sono necessari su tutti i firmware: li inviamo in sequenza finché arriva input.
HANDSHAKE_CANDIDATES: List[bytes] = [
    bytes([0x05, 0x20, 0x00, 0x01, 0x00]),
    bytes([0x01, 0x20]),
    bytes([0x05, 0x20, 0x01, 0x00, 0x00]),
]

BUTTON_MAP = {
    0: "DPAD_UP",
    1: "DPAD_DOWN",
    2: "DPAD_LEFT",
    3: "DPAD_RIGHT",
    4: "MENU",
    5: "VIEW",
    6: "LS",
    7: "RS",
    8: "LB",
    9: "RB",
    10: "XBOX",
    12: "A",
    13: "B",
    14: "X",
    15: "Y",
}


def find_interrupt_endpoints(dev: usb.core.Device) -> Tuple[int, int, int]:
    """Ritorna (interface_number, ep_in_addr, ep_out_addr)."""
    cfg = dev.get_active_configuration()

    for intf in cfg:
        ep_in = None
        ep_out = None
        for ep in intf:
            transfer_type = usb.util.endpoint_type(ep.bmAttributes)
            direction = usb.util.endpoint_direction(ep.bEndpointAddress)
            if transfer_type != usb.util.ENDPOINT_TYPE_INTR:
                continue
            if direction == usb.util.ENDPOINT_IN and ep_in is None:
                ep_in = ep.bEndpointAddress
            elif direction == usb.util.ENDPOINT_OUT and ep_out is None:
                ep_out = ep.bEndpointAddress

        if ep_in is not None and ep_out is not None:
            return intf.bInterfaceNumber, ep_in, ep_out

    raise RuntimeError("Nessuna coppia endpoint interrupt IN/OUT trovata")


def decode_input_report(data: bytes) -> Optional[Dict[str, object]]:
    """
    Decodifica un report tipico Xbox One (layout comune da 18 byte).
    Ritorna None se il payload è troppo corto.
    """
    if len(data) < 16:
        return None

    # Layout tipico osservato su 1537:
    # [0]=report type, [4:6]=buttons, [6]=LT, [7]=RT,
    # [8:10]=LX, [10:12]=LY, [12:14]=RX, [14:16]=RY
    buttons = struct.unpack_from("<H", data, 4)[0]
    lt = data[6]
    rt = data[7]
    lx = struct.unpack_from("<h", data, 8)[0]
    ly = struct.unpack_from("<h", data, 10)[0]
    rx = struct.unpack_from("<h", data, 12)[0]
    ry = struct.unpack_from("<h", data, 14)[0]

    pressed = [name for bit, name in BUTTON_MAP.items() if buttons & (1 << bit)]

    return {
        "report_type": data[0],
        "buttons_raw": buttons,
        "pressed": pressed,
        "lt": lt,
        "rt": rt,
        "lx": lx,
        "ly": ly,
        "rx": rx,
        "ry": ry,
    }


def main() -> int:
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        print(f"Device {VID:04x}:{PID:04x} non trovato")
        return 1

    print(f"Trovato device {VID:04x}:{PID:04x}")

    if dev.is_kernel_driver_active(0):
        try:
            dev.detach_kernel_driver(0)
            print("Detached kernel driver da interfaccia 0")
        except usb.core.USBError as exc:
            print(f"Impossibile detach kernel driver: {exc}")

    dev.set_configuration()
    interface_number, ep_in, ep_out = find_interrupt_endpoints(dev)

    usb.util.claim_interface(dev, interface_number)
    print(f"Interfaccia={interface_number}, EP_IN=0x{ep_in:02x}, EP_OUT=0x{ep_out:02x}")

    try:
        for frame in HANDSHAKE_CANDIDATES:
            written = dev.write(ep_out, frame, interface=interface_number, timeout=READ_TIMEOUT_MS)
            print(f"Handshake TX ({written} bytes): {frame.hex(' ')}")
            time.sleep(0.02)

        print("Lettura input... (CTRL+C per uscire)")
        while True:
            try:
                data = bytes(dev.read(ep_in, 64, interface=interface_number, timeout=READ_TIMEOUT_MS))
            except usb.core.USBTimeoutError:
                continue

            print(f"RAW[{len(data):02d}]: {data.hex(' ')}")
            decoded = decode_input_report(data)
            if decoded:
                print(
                    "DECODE: "
                    f"btn=0x{decoded['buttons_raw']:04x} "
                    f"pressed={decoded['pressed']} "
                    f"LT={decoded['lt']} RT={decoded['rt']} "
                    f"LX={decoded['lx']} LY={decoded['ly']} "
                    f"RX={decoded['rx']} RY={decoded['ry']}"
                )
    except KeyboardInterrupt:
        print("Interrotto da utente")
    finally:
        usb.util.release_interface(dev, interface_number)
        usb.util.dispose_resources(dev)

    return 0


if __name__ == "__main__":
    sys.exit(main())