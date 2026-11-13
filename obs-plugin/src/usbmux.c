#include "usbmux.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct usbmux_target {
	char udid[OBSCAM_USB_UDID_MAX];
	uint16_t port;
};

void *obscam_usbmux_target_create(const char *udid, uint16_t device_port)
{
	struct usbmux_target *t = calloc(1, sizeof(*t));
	if (!t)
		return NULL;
	if (udid)
		snprintf(t->udid, sizeof(t->udid), "%s", udid);
	t->port = device_port;
	return t;
}

void obscam_usbmux_target_destroy(void *target)
{
	free(target);
}

#ifdef HAVE_USBMUXD

#include <usbmuxd.h>

int obscam_usbmux_available(void)
{
	return 1;
}

int obscam_usbmux_list(char udids[][OBSCAM_USB_UDID_MAX], int max)
{
	usbmuxd_device_info_t *list = NULL;
	int count = usbmuxd_get_device_list(&list);
	if (count < 0)
		return -1;

	int found = 0;
	for (int i = 0; i < count && found < max; i++) {
		/* Skip devices that usbmuxd only knows over Wi-Fi sync. */
		if (list[i].conn_type != CONNECTION_TYPE_USB)
			continue;
		snprintf(udids[found++], OBSCAM_USB_UDID_MAX, "%s", list[i].udid);
	}
	usbmuxd_device_list_free(&list);
	return found;
}

int obscam_usbmux_connect(void *target, char *peer, size_t peer_size, enum obscam_client_status *status)
{
	struct usbmux_target *t = target;
	usbmuxd_device_info_t *list = NULL;
	int count = usbmuxd_get_device_list(&list);
	if (count < 0) {
		*status = OBSCAM_CLIENT_NO_DAEMON;
		return -1;
	}

	int fd = -1;
	bool found = false;
	*status = OBSCAM_CLIENT_NO_DEVICE;
	for (int i = 0; i < count; i++) {
		if (list[i].conn_type != CONNECTION_TYPE_USB)
			continue;
		if (t->udid[0] && strcmp(t->udid, list[i].udid) != 0)
			continue;
		found = true;
		fd = usbmuxd_connect(list[i].handle, t->port);
		if (fd >= 0) {
			snprintf(peer, peer_size, "USB %s", list[i].udid);
			*status = OBSCAM_CLIENT_CONNECTED;
			break;
		}
	}
	if (found && fd < 0)
		*status = OBSCAM_CLIENT_NO_APP;
	usbmuxd_device_list_free(&list);
	return fd;
}

#else /* !HAVE_USBMUXD */

int obscam_usbmux_available(void)
{
	return 0;
}

int obscam_usbmux_list(char udids[][OBSCAM_USB_UDID_MAX], int max)
{
	(void)udids;
	(void)max;
	return -1;
}

int obscam_usbmux_connect(void *target, char *peer, size_t peer_size, enum obscam_client_status *status)
{
	(void)target;
	(void)peer;
	(void)peer_size;
	*status = OBSCAM_CLIENT_UNAVAILABLE;
	return -1;
}

#endif
