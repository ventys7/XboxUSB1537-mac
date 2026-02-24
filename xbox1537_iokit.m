/*
 * xbox1537_iokit.m — Lettura input Xbox One Controller 1537 su macOS.
 *
 * Usa IOHIDManager per leggere i report HID dal controller,
 * lavorando CON il driver Apple (non contro di esso).
 *
 * Su macOS 15+ (Sequoia) il controller Xbox One è supportato nativamente
 * e appare come IOHIDDevice con UsagePage=1 (Generic Desktop).
 *
 * Build:
 *   clang -O2 -Wall -framework IOKit -framework CoreFoundation \
 *         xbox1537_iokit.m -o xbox1537_iokit
 *
 * Run:
 *   ./xbox1537_iokit          (non serve sudo)
 */

#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/hid/IOHIDManager.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define VID 0x045E
#define PID 0x02D1

static volatile sig_atomic_t g_running = 1;

static void sigint_handler(int sig) {
  (void)sig;
  g_running = 0;
  /* Ferma il RunLoop per uscire subito */
  CFRunLoopStop(CFRunLoopGetMain());
}

/* ---------- Decodifica report ---------- */

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

static void dump_hex(const uint8_t *buf, CFIndex len) {
  printf("RAW[%02ld]:", (long)len);
  for (CFIndex i = 0; i < len; i++) {
    printf(" %02x", buf[i]);
  }
  printf("\n");
}

static void decode_gip_report(const uint8_t *buf, CFIndex len) {
  /* Report GIP tipico: almeno 16 byte, tipo 0x20 */
  if (len < 16)
    return;

  uint16_t buttons = (uint16_t)buf[4] | ((uint16_t)buf[5] << 8);
  uint8_t lt = buf[6];
  uint8_t rt = buf[7];
  int16_t lx = (int16_t)((uint16_t)buf[8] | ((uint16_t)buf[9] << 8));
  int16_t ly = (int16_t)((uint16_t)buf[10] | ((uint16_t)buf[11] << 8));
  int16_t rx = (int16_t)((uint16_t)buf[12] | ((uint16_t)buf[13] << 8));
  int16_t ry = (int16_t)((uint16_t)buf[14] | ((uint16_t)buf[15] << 8));

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

/* ---------- Callback HID ---------- */

static void input_report_callback(void *context, IOReturn result, void *sender,
                                  IOHIDReportType type, uint32_t reportID,
                                  uint8_t *report, CFIndex reportLength) {
  (void)context;
  (void)result;
  (void)sender;
  (void)type;
  (void)reportID;

  dump_hex(report, reportLength);
  decode_gip_report(report, reportLength);
}

static void input_value_callback(void *context, IOReturn result, void *sender,
                                 IOHIDValueRef value) {
  (void)context;
  (void)result;
  (void)sender;

  IOHIDElementRef element = IOHIDValueGetElement(value);
  uint32_t usagePage = IOHIDElementGetUsagePage(element);
  uint32_t usage = IOHIDElementGetUsage(element);
  CFIndex intValue = IOHIDValueGetIntegerValue(value);

  /* Filtra: stampa solo valori non-zero o assi principali */
  if (usagePage == 0x01) {
    /* Generic Desktop: stick e hat switch */
    const char *axisName = "?";
    switch (usage) {
    case 0x30:
      axisName = "LX";
      break;
    case 0x31:
      axisName = "LY";
      break;
    case 0x32:
      axisName = "RX";
      break;
    case 0x33:
      axisName = "Z (LT?)";
      break;
    case 0x34:
      axisName = "Rz (RT?)";
      break;
    case 0x35:
      axisName = "RY";
      break;
    case 0x39:
      axisName = "HAT";
      break;
    default:
      axisName = "axis";
      break;
    }
    printf("AXIS: %s (page=0x%02x usage=0x%02x) = %ld\n", axisName, usagePage,
           usage, (long)intValue);
  } else if (usagePage == 0x09) {
    /* Button page */
    if (intValue != 0) {
      printf("BUTTON: #%u PRESSED (value=%ld)\n", usage, (long)intValue);
    } else {
      printf("BUTTON: #%u released\n", usage);
    }
  } else if (intValue != 0) {
    printf("HID: page=0x%02x usage=0x%02x value=%ld\n", usagePage, usage,
           (long)intValue);
  }
}

static void device_matched_callback(void *context, IOReturn result,
                                    void *sender, IOHIDDeviceRef device) {
  (void)context;
  (void)result;
  (void)sender;

  CFStringRef product = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
  if (product) {
    char buf[256];
    CFStringGetCString(product, buf, sizeof(buf), kCFStringEncodingUTF8);
    printf("✅ Controller connesso: %s\n", buf);
  } else {
    printf("✅ Controller connesso (nome non disponibile)\n");
  }

  /* Registra callback per report raw */
  static uint8_t reportBuf[256];
  IOHIDDeviceRegisterInputReportCallback(device, reportBuf, sizeof(reportBuf),
                                         input_report_callback, NULL);

  /* Registra callback per valori HID parsed */
  IOHIDDeviceRegisterInputValueCallback(device, input_value_callback, NULL);

  printf("Lettura input... (CTRL+C per uscire)\n\n");
}

static void device_removed_callback(void *context, IOReturn result,
                                    void *sender, IOHIDDeviceRef device) {
  (void)context;
  (void)result;
  (void)sender;
  (void)device;
  printf("⚠️  Controller scollegato\n");
}

/* ---------- Main ---------- */

int main(void) {
  signal(SIGINT, sigint_handler);

  IOHIDManagerRef manager =
      IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
  if (!manager) {
    fprintf(stderr, "IOHIDManagerCreate fallito\n");
    return 1;
  }

  /* Matching per VID/PID Xbox One 1537 */
  CFMutableDictionaryRef matchDict = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);

  int vid = VID, pid = PID;
  CFNumberRef vidNum =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
  CFNumberRef pidNum =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pid);

  CFDictionarySetValue(matchDict, CFSTR(kIOHIDVendorIDKey), vidNum);
  CFDictionarySetValue(matchDict, CFSTR(kIOHIDProductIDKey), pidNum);

  CFRelease(vidNum);
  CFRelease(pidNum);

  IOHIDManagerSetDeviceMatching(manager, matchDict);
  CFRelease(matchDict);

  /* Registra callback connect/disconnect */
  IOHIDManagerRegisterDeviceMatchingCallback(manager, device_matched_callback,
                                             NULL);
  IOHIDManagerRegisterDeviceRemovalCallback(manager, device_removed_callback,
                                            NULL);

  /* Apri il manager */
  IOReturn ret = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
  if (ret != kIOReturnSuccess) {
    fprintf(stderr, "IOHIDManagerOpen fallito: 0x%x\n", ret);

    /* Prova con seize */
    printf("Tentativo con kIOHIDOptionsTypeSeizeDevice...\n");
    ret = IOHIDManagerOpen(manager, kIOHIDOptionsTypeSeizeDevice);
    if (ret != kIOReturnSuccess) {
      fprintf(stderr, "Anche seize fallito: 0x%x\n", ret);
      fprintf(stderr, "Prova con: sudo ./xbox1537_iokit\n");
      CFRelease(manager);
      return 1;
    }
  }

  /* Schedula nel RunLoop */
  IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(),
                                  kCFRunLoopDefaultMode);

  printf("Xbox One Controller 1537 — IOHIDManager\n");
  printf("In attesa del controller (VID=%04x PID=%04x)...\n", VID, PID);
  printf("Se già collegato, dovrebbe apparire subito.\n\n");

  /* RunLoop — esce con CTRL+C */
  while (g_running) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
  }

  printf("\nChiusura...\n");
  IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(),
                                    kCFRunLoopDefaultMode);
  IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
  CFRelease(manager);

  return 0;
}
