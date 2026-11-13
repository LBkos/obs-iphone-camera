#pragma once

#include <stddef.h>
#include <stdint.h>

#include "receiver.h"

/*
 * Wired connection through usbmuxd (Linux: the usbmuxd daemon + libusbmuxd,
 * macOS: Apple's built-in usbmuxd). The iPhone app listens on a TCP port on
 * the device; usbmuxd tunnels our connection to it over the cable.
 * Built only with HAVE_USBMUXD; otherwise every call reports "unavailable".
 */

#define OBSCAM_USB_UDID_MAX 64

/* udid: a specific device, or NULL / "" for the first iPhone connected by USB. */
void *obscam_usbmux_target_create(const char *udid, uint16_t device_port);
void obscam_usbmux_target_destroy(void *target);

/* obscam_connect_fn for obscam_receiver_start_client(). */
int obscam_usbmux_connect(void *target, char *peer, size_t peer_size, enum obscam_client_status *status);

/* Fills udids with iPhones connected by USB. Returns the count, or -1 if usbmuxd is unreachable. */
int obscam_usbmux_list(char udids[][OBSCAM_USB_UDID_MAX], int max);

int obscam_usbmux_available(void);
