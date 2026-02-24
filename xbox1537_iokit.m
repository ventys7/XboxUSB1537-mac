/*
 * xbox1537_iokit.m — Accesso diretto IOKit per Xbox One Controller 1537.
 *
 * Usa le API native macOS (IOKit USB) per comunicare col controller
 * SENZA libusb, bypassando i conflitti con i driver kernel.
 *
 * Build:
 *   clang -O2 -Wall -framework IOKit -framework CoreFoundation \
 *         xbox1537_iokit.m -o xbox1537_iokit
 *
 * Run:
 *   ./xbox1537_iokit          (potrebbe servire sudo)
 */

#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define VID 0x045E
#define PID 0x02D1
#define READ_TIMEOUT_MS 500
#define BUF_SIZE 64

static volatile sig_atomic_t g_running = 1;

static void sigint_handler(int sig) {
  (void)sig;
  g_running = 0;
}

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

static void dump_hex(const uint8_t *buf, int len) {
  printf("RAW[%02d]:", len);
  for (int i = 0; i < len; i++) {
    printf(" %02x", buf[i]);
  }
  printf("\n");
}

static void decode_and_print(const uint8_t *buf, int len) {
  if (len < 16)
    return;

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

/*
 * Trova e apre l'interfaccia USB con endpoint interrupt IN/OUT.
 * Ritorna 0 se trovata, -1 altrimenti.
 */
static int find_and_open_interface(IOUSBDeviceInterface **dev,
                                   IOUSBInterfaceInterface **intf[],
                                   uint8_t *ep_in, uint8_t *ep_out) {
  IOUSBFindInterfaceRequest req;
  req.bInterfaceClass = kIOUSBFindInterfaceDontCare;
  req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
  req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
  req.bAlternateSetting = kIOUSBFindInterfaceDontCare;

  io_iterator_t iter;
  kern_return_t kr = (*dev)->CreateInterfaceIterator(dev, &req, &iter);
  if (kr != KERN_SUCCESS) {
    fprintf(stderr, "CreateInterfaceIterator fallito: 0x%x\n", kr);
    return -1;
  }

  io_service_t usbInterfaceRef;
  while ((usbInterfaceRef = IOIteratorNext(iter)) != 0) {
    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score;
    kr = IOCreatePlugInInterfaceForService(
        usbInterfaceRef, kIOUSBInterfaceUserClientTypeID,
        kIOCFPlugInInterfaceID, &plugIn, &score);
    IOObjectRelease(usbInterfaceRef);

    if (kr != KERN_SUCCESS || plugIn == NULL)
      continue;

    HRESULT res = (*plugIn)->QueryInterface(
        plugIn, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)intf);
    (*plugIn)->Release(plugIn);

    if (res != S_OK || *intf == NULL)
      continue;

    kr = (**intf)->USBInterfaceOpen(*intf);
    if (kr != KERN_SUCCESS) {
      fprintf(stderr, "USBInterfaceOpen fallito: 0x%x\n", kr);
      (**intf)->Release(*intf);
      *intf = NULL;
      continue;
    }

    /* Cerca endpoint interrupt IN e OUT */
    uint8_t numEP;
    (**intf)->GetNumEndpoints(*intf, &numEP);
    uint8_t in_addr = 0, out_addr = 0;

    for (uint8_t i = 1; i <= numEP; i++) {
      uint8_t direction, number, transferType, interval;
      uint16_t maxPacketSize;
      (**intf)->GetPipeProperties(*intf, i, &direction, &number, &transferType,
                                  &maxPacketSize, &interval);
      if (transferType != kUSBInterrupt)
        continue;
      if (direction == kUSBIn && in_addr == 0)
        in_addr = i;
      else if (direction == kUSBOut && out_addr == 0)
        out_addr = i;
    }

    if (in_addr && out_addr) {
      *ep_in = in_addr;
      *ep_out = out_addr;
      IOObjectRelease(iter);
      return 0;
    }

    (**intf)->USBInterfaceClose(*intf);
    (**intf)->Release(*intf);
    *intf = NULL;
  }

  IOObjectRelease(iter);
  return -1;
}

int main(void) {
  signal(SIGINT, sigint_handler);

  /* Matching dictionary per VID/PID */
  CFMutableDictionaryRef matchDict = IOServiceMatching(kIOUSBDeviceClassName);
  if (!matchDict) {
    fprintf(stderr, "IOServiceMatching fallito\n");
    return 1;
  }

  CFDictionarySetValue(
      matchDict, CFSTR(kUSBVendorID),
      CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &(int){VID}));
  CFDictionarySetValue(
      matchDict, CFSTR(kUSBProductID),
      CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &(int){PID}));

  io_service_t usbDevice =
      IOServiceGetMatchingService(kIOMainPortDefault, matchDict);
  if (!usbDevice) {
    fprintf(stderr, "Device %04x:%04x non trovato\n", VID, PID);
    return 1;
  }

  printf("Trovato device %04x:%04x nella IORegistry\n", VID, PID);

  /* Creare plugin e interfaccia device */
  IOCFPlugInInterface **plugIn = NULL;
  SInt32 score;
  kern_return_t kr = IOCreatePlugInInterfaceForService(
      usbDevice, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugIn,
      &score);
  IOObjectRelease(usbDevice);

  if (kr != KERN_SUCCESS || plugIn == NULL) {
    fprintf(stderr, "IOCreatePlugInInterfaceForService fallito: 0x%x\n", kr);
    return 1;
  }

  IOUSBDeviceInterface **dev = NULL;
  HRESULT res = (*plugIn)->QueryInterface(
      plugIn, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
  (*plugIn)->Release(plugIn);

  if (res != S_OK || dev == NULL) {
    fprintf(stderr, "QueryInterface device fallito\n");
    return 1;
  }

  /* Aprire il device — seize=true per prendere il controllo dal driver kernel
   */
  kr = (*dev)->USBDeviceOpenSeize(dev);
  if (kr != KERN_SUCCESS) {
    fprintf(stderr,
            "USBDeviceOpenSeize fallito: 0x%x\n"
            "Il device potrebbe essere bloccato da un altro processo.\n"
            "Prova con: sudo ./xbox1537_iokit\n",
            kr);
    (*dev)->Release(dev);
    return 1;
  }

  printf("Device aperto con successo (seize mode)\n");

  /* Configurazione */
  IOUSBConfigurationDescriptorPtr configDesc;
  kr = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &configDesc);
  if (kr == KERN_SUCCESS) {
    kr = (*dev)->SetConfiguration(dev, configDesc->bConfigurationValue);
    if (kr != KERN_SUCCESS) {
      fprintf(stderr, "SetConfiguration fallito: 0x%x\n", kr);
    }
  }

  /* Trovare e aprire interfaccia con endpoint interrupt */
  IOUSBInterfaceInterface **intf = NULL;
  uint8_t ep_in = 0, ep_out = 0;

  if (find_and_open_interface(dev, &intf, &ep_in, &ep_out) != 0) {
    fprintf(stderr, "Nessuna interfaccia con endpoint interrupt IN/OUT\n");
    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    return 1;
  }

  printf("Interfaccia aperta, EP_IN=pipe %d, EP_OUT=pipe %d\n", ep_in, ep_out);

  /* Inviare handshake */
  const uint8_t *frames[] = {HANDSHAKE_1, HANDSHAKE_2, HANDSHAKE_3};
  const uint32_t lengths[] = {sizeof(HANDSHAKE_1), sizeof(HANDSHAKE_2),
                              sizeof(HANDSHAKE_3)};

  for (int i = 0; i < 3; i++) {
    kr = (*intf)->WritePipe(intf, ep_out, (void *)frames[i], lengths[i]);
    printf("Handshake %d rc=0x%x\n", i + 1, kr);
    usleep(20000);
  }

  /* Loop di lettura */
  printf("Lettura input... (CTRL+C per uscire)\n");
  while (g_running) {
    uint8_t buf[BUF_SIZE];
    uint32_t bytesRead = BUF_SIZE;

    kr = (*intf)->ReadPipeTO(intf, ep_in, buf, &bytesRead, READ_TIMEOUT_MS,
                             READ_TIMEOUT_MS);

    if (kr == kIOUSBTransactionTimeout) {
      continue;
    }
    if (kr != KERN_SUCCESS) {
      /* Prova senza timeout se ReadPipeTO non è supportato */
      kr = (*intf)->ReadPipe(intf, ep_in, buf, &bytesRead);
      if (kr != KERN_SUCCESS) {
        fprintf(stderr, "ReadPipe fallito: 0x%x\n", kr);
        break;
      }
    }

    dump_hex(buf, (int)bytesRead);
    decode_and_print(buf, (int)bytesRead);
  }

  printf("\nChiusura...\n");
  (*intf)->USBInterfaceClose(intf);
  (*intf)->Release(intf);
  (*dev)->USBDeviceClose(dev);
  (*dev)->Release(dev);

  return 0;
}
