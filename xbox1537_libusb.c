/*
 * Esempio libusb-1.0 per Xbox One Controller 1537 (045e:02d1).
 *
 * Build:
 *   gcc -O2 -Wall -Wextra xbox1537_libusb.c -o xbox1537_libusb -lusb-1.0
 *
 * Run:
 *   ./xbox1537_libusb
 */

#include <libusb-1.0/libusb.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define VID 0x045E
#define PID 0x02D1
#define TIMEOUT_MS 500

static const uint8_t HANDSHAKE_1[] = {0x05, 0x20, 0x00, 0x01, 0x00};
static const uint8_t HANDSHAKE_2[] = {0x01, 0x20};
static const uint8_t HANDSHAKE_3[] = {0x05, 0x20, 0x01, 0x00, 0x00};

static const char *button_name(unsigned bit) {
  switch (bit) {
  case 0:
    return "DPAD_UP";
  case 1:
    return "DPAD_DOWN";
  case 2:
    return "DPAD_LEFT";
  case 3:
    return "DPAD_RIGHT";
  case 4:
    return "MENU";
  case 5:
    return "VIEW";
  case 6:
    return "LS";
  case 7:
    return "RS";
  case 8:
    return "LB";
  case 9:
    return "RB";
  case 10:
    return "XBOX";
  case 12:
    return "A";
  case 13:
    return "B";
  case 14:
    return "X";
  case 15:
    return "Y";
  default:
    return NULL;
  }
}

static int16_t read_i16le(const uint8_t *p) {
  return (int16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static void decode_and_print(const uint8_t *buf, int len) {
  if (len < 16) {
    return;
  }

  uint16_t buttons = (uint16_t)buf[4] | ((uint16_t)buf[5] << 8);
  uint8_t lt = buf[6];
  uint8_t rt = buf[7];
  int16_t lx = read_i16le(&buf[8]);
  int16_t ly = read_i16le(&buf[10]);
  int16_t rx = read_i16le(&buf[12]);
  int16_t ry = read_i16le(&buf[14]);

  printf("DECODE: btn=0x%04x pressed=[", buttons);
  int first = 1;
  for (unsigned bit = 0; bit < 16; bit++) {
    if ((buttons & (1u << bit)) == 0)
      continue;
    const char *name = button_name(bit);
    if (!name)
      continue;
    if (!first)
      printf(", ");
    printf("%s", name);
    first = 0;
  }
  printf("] LT=%u RT=%u LX=%d LY=%d RX=%d RY=%d\n", lt, rt, lx, ly, rx, ry);
}

static int find_interrupt_eps(libusb_device_handle *handle, int *iface,
                              uint8_t *ep_in, uint8_t *ep_out) {
  libusb_device *dev = libusb_get_device(handle);
  struct libusb_config_descriptor *cfg = NULL;
  int rc = libusb_get_active_config_descriptor(dev, &cfg);
  if (rc != 0 || cfg == NULL)
    return -1;

  int found = 0;
  for (uint8_t i = 0; i < cfg->bNumInterfaces && !found; i++) {
    const struct libusb_interface *itf = &cfg->interface[i];
    for (int alt = 0; alt < itf->num_altsetting && !found; alt++) {
      const struct libusb_interface_descriptor *d = &itf->altsetting[alt];
      uint8_t in_addr = 0, out_addr = 0;
      for (uint8_t e = 0; e < d->bNumEndpoints; e++) {
        const struct libusb_endpoint_descriptor *ep = &d->endpoint[e];
        uint8_t type = ep->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;
        if (type != LIBUSB_TRANSFER_TYPE_INTERRUPT)
          continue;

        if ((ep->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) ==
            LIBUSB_ENDPOINT_IN) {
          if (in_addr == 0)
            in_addr = ep->bEndpointAddress;
        } else {
          if (out_addr == 0)
            out_addr = ep->bEndpointAddress;
        }
      }

      if (in_addr && out_addr) {
        *iface = d->bInterfaceNumber;
        *ep_in = in_addr;
        *ep_out = out_addr;
        found = 1;
      }
    }
  }

  libusb_free_config_descriptor(cfg);
  return found ? 0 : -1;
}

static void dump_hex(const uint8_t *buf, int len) {
  printf("RAW[%02d]:", len);
  for (int i = 0; i < len; i++) {
    printf(" %02x", buf[i]);
  }
  printf("\n");
}

int main(void) {
  libusb_context *ctx = NULL;
  libusb_device_handle *handle = NULL;
  int iface = 0;
  uint8_t ep_in = 0, ep_out = 0;
  int rc = 0;

  rc = libusb_init(&ctx);
  if (rc != 0) {
    fprintf(stderr, "libusb_init failed: %d\n", rc);
    return 1;
  }

  handle = libusb_open_device_with_vid_pid(ctx, VID, PID);
  if (!handle) {
    fprintf(stderr, "Device %04x:%04x non trovato\n", VID, PID);
    libusb_exit(ctx);
    return 1;
  }

  if (find_interrupt_eps(handle, &iface, &ep_in, &ep_out) != 0) {
    fprintf(stderr, "Endpoint interrupt IN/OUT non trovati\n");
    libusb_close(handle);
    libusb_exit(ctx);
    return 1;
  }

  printf("Interfaccia=%d EP_IN=0x%02x EP_OUT=0x%02x\n", iface, ep_in, ep_out);

  rc = libusb_kernel_driver_active(handle, iface);
  if (rc == 1) {
    rc = libusb_detach_kernel_driver(handle, iface);
    if (rc == 0) {
      printf("Detached kernel driver da interfaccia %d\n", iface);
    } else {
#ifdef __APPLE__
      fprintf(stderr,
              "[macOS] detach_kernel_driver non supportato (rc=%d), "
              "continuiamo...\n",
              rc);
#else
      fprintf(stderr, "detach kernel driver fallito: %d\n", rc);
#endif
    }
  }
#ifdef __APPLE__
  else if (rc == LIBUSB_ERROR_NOT_SUPPORTED) {
    fprintf(stderr,
            "[macOS] kernel_driver_active non supportato, continuiamo...\n");
  }
#endif

  rc = libusb_claim_interface(handle, iface);
  if (rc != 0) {
#ifdef __APPLE__
    fprintf(stderr,
            "\n[macOS] claim_interface fallito: %d\n"
            "Probabili soluzioni:\n"
            "  1) Esegui con sudo:  sudo ./xbox1537_libusb\n"
            "  2) Scarica il kext:  sudo ./unload_xbox_kext.sh\n"
            "  3) Usa la versione IOKit nativa: ./xbox1537_iokit\n",
            rc);
#else
    fprintf(stderr, "claim_interface fallito: %d\n", rc);
#endif
    libusb_close(handle);
    libusb_exit(ctx);
    return 1;
  }

  const uint8_t *frames[] = {HANDSHAKE_1, HANDSHAKE_2, HANDSHAKE_3};
  const int lengths[] = {(int)sizeof(HANDSHAKE_1), (int)sizeof(HANDSHAKE_2),
                         (int)sizeof(HANDSHAKE_3)};

  for (int i = 0; i < 3; i++) {
    int transferred = 0;
    rc = libusb_interrupt_transfer(handle, ep_out, (unsigned char *)frames[i],
                                   lengths[i], &transferred, TIMEOUT_MS);
    printf("Handshake %d rc=%d transferred=%d\n", i + 1, rc, transferred);
  }

  printf("Lettura input... (CTRL+C per uscire)\n");
  while (1) {
    uint8_t buf[64];
    int transferred = 0;
    rc = libusb_interrupt_transfer(handle, ep_in, buf, sizeof(buf), &transferred,
                                   TIMEOUT_MS);

    if (rc == LIBUSB_ERROR_TIMEOUT) {
      continue;
    }
    if (rc != 0) {
      fprintf(stderr, "read error rc=%d\n", rc);
      break;
    }

    dump_hex(buf, transferred);
    decode_and_print(buf, transferred);
  }

  libusb_release_interface(handle, iface);
  libusb_close(handle);
  libusb_exit(ctx);
  return 0;
}