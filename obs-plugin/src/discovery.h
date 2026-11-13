#pragma once

#include <stdint.h>

/*
 * Bonjour / mDNS advertisement of the receiver so the iPhone app finds OBS
 * automatically. Uses the dns_sd API: built into macOS, provided on Linux by
 * Avahi's compatibility library (libavahi-compat-libdnssd). When built
 * without it (HAVE_DNSSD undefined) these are no-ops and the user enters the
 * IP address in the app manually.
 */

typedef struct obscam_discovery obscam_discovery_t;

obscam_discovery_t *obscam_discovery_register(const char *service_name, uint16_t port);
/* File descriptor to poll for readability, or -1. */
int obscam_discovery_fd(obscam_discovery_t *d);
void obscam_discovery_process(obscam_discovery_t *d);
void obscam_discovery_unregister(obscam_discovery_t *d);
