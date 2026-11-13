/*
 * OBS source "iPhone Camera": receives H.264 video from the OBS Camera iOS
 * app over Wi-Fi or a USB cable, decodes it with FFmpeg and outputs it as an
 * asynchronous video source.
 */
#include <obs-module.h>
#include <util/dstr.h>
#include <util/platform.h>
#include <util/threading.h>

#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>

#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <unistd.h>

#include "h264-decoder.h"
#include "protocol.h"
#include "receiver.h"
#include "usbmux.h"

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-iphone-camera", "en-US")

#define S_MODE "mode"
#define S_PORT "port"
#define S_USB_DEVICE "usb_device"
#define S_KEEP_LAST_FRAME "keep_last_frame"

#define MODE_WIFI "wifi"
#define MODE_USB "usb"
#define MAX_USB_DEVICES 16

#define T_(s) obs_module_text(s)

struct iphone_camera {
	obs_source_t *source;
	obscam_receiver_t *receiver;
	obscam_decoder_t *decoder;
	bool usb_mode;
	uint16_t port;
	char usb_device[OBSCAM_USB_UDID_MAX]; /* "" = first iPhone on USB */
	bool keep_last_frame;

	pthread_mutex_t mutex; /* guards the status fields below */
	bool connected;
	char device_name[128];
	char peer[64];
	uint32_t width, height;
	uint32_t frames_this_second;
	uint32_t fps;
	uint64_t fps_window_start_ns;
	bool warned_format;
};

/* ---------------------------------------------------------------- receiver */

static void on_log(void *ctx, int level, const char *msg)
{
	struct iphone_camera *cam = ctx;
	int obs_level = level == 0 ? LOG_INFO : level == 1 ? LOG_WARNING : LOG_ERROR;
	blog(obs_level, "[iphone-camera] '%s': %s", obs_source_get_name(cam->source), msg);
}

static void on_connected(void *ctx, const char *peer)
{
	struct iphone_camera *cam = ctx;
	obscam_decoder_reset(cam->decoder);
	pthread_mutex_lock(&cam->mutex);
	cam->connected = true;
	snprintf(cam->peer, sizeof(cam->peer), "%s", peer);
	cam->device_name[0] = '\0';
	cam->fps = 0;
	cam->frames_this_second = 0;
	pthread_mutex_unlock(&cam->mutex);
}

static void on_hello(void *ctx, const char *name)
{
	struct iphone_camera *cam = ctx;
	pthread_mutex_lock(&cam->mutex);
	snprintf(cam->device_name, sizeof(cam->device_name), "%s", name);
	pthread_mutex_unlock(&cam->mutex);
}

static void on_config(void *ctx, const uint8_t *data, size_t size)
{
	struct iphone_camera *cam = ctx;
	obscam_decoder_set_config(cam->decoder, data, size);
}

static void on_frame(void *ctx, uint64_t pts_us, bool keyframe, const uint8_t *data, size_t size)
{
	struct iphone_camera *cam = ctx;
	if (!obscam_decoder_decode(cam->decoder, data, size, keyframe, pts_us))
		blog(LOG_DEBUG, "[iphone-camera] decode error, waiting for next keyframe");
}

static void on_disconnected(void *ctx)
{
	struct iphone_camera *cam = ctx;
	pthread_mutex_lock(&cam->mutex);
	cam->connected = false;
	cam->fps = 0;
	pthread_mutex_unlock(&cam->mutex);
	obscam_decoder_reset(cam->decoder);
	if (!cam->keep_last_frame)
		obs_source_output_video(cam->source, NULL);
}

/* ----------------------------------------------------------------- decoder */

static enum video_colorspace map_colorspace(const AVFrame *f)
{
	switch (f->colorspace) {
	case AVCOL_SPC_BT709:
		return VIDEO_CS_709;
	case AVCOL_SPC_BT470BG:
	case AVCOL_SPC_SMPTE170M:
		return VIDEO_CS_601;
	default:
		return f->height >= 720 ? VIDEO_CS_709 : VIDEO_CS_601;
	}
}

static void on_decoded(void *ctx, const AVFrame *f, uint64_t pts_us)
{
	(void)pts_us;
	struct iphone_camera *cam = ctx;
	enum video_format format;
	bool full_range = f->color_range == AVCOL_RANGE_JPEG;

	switch (f->format) {
	case AV_PIX_FMT_YUVJ420P:
		full_range = true;
		/* fallthrough */
	case AV_PIX_FMT_YUV420P:
		format = VIDEO_FORMAT_I420;
		break;
	case AV_PIX_FMT_NV12:
		format = VIDEO_FORMAT_NV12;
		break;
	default:
		if (!cam->warned_format) {
			blog(LOG_WARNING, "[iphone-camera] unsupported pixel format %d", f->format);
			cam->warned_format = true;
		}
		return;
	}

	struct obs_source_frame frame;
	memset(&frame, 0, sizeof(frame));
	for (int i = 0; i < MAX_AV_PLANES && i < AV_NUM_DATA_POINTERS; i++) {
		frame.data[i] = f->data[i];
		frame.linesize[i] = (uint32_t)f->linesize[i];
	}
	frame.width = (uint32_t)f->width;
	frame.height = (uint32_t)f->height;
	frame.format = format;
	frame.full_range = full_range;
	/* Arrival time: OBS paces async frames by timestamp; we want minimal latency. */
	frame.timestamp = os_gettime_ns();
	/* 8-bit formats only, so the older API is equivalent and keeps OBS 27+ compatibility. */
	video_format_get_parameters(map_colorspace(f), full_range ? VIDEO_RANGE_FULL : VIDEO_RANGE_PARTIAL,
				    frame.color_matrix, frame.color_range_min, frame.color_range_max);

	obs_source_output_video(cam->source, &frame);

	uint64_t now = frame.timestamp;
	pthread_mutex_lock(&cam->mutex);
	cam->width = frame.width;
	cam->height = frame.height;
	cam->frames_this_second++;
	if (now - cam->fps_window_start_ns >= 1000000000ULL) {
		cam->fps = cam->frames_this_second;
		cam->frames_this_second = 0;
		cam->fps_window_start_ns = now;
	}
	pthread_mutex_unlock(&cam->mutex);
}

/* ------------------------------------------------------------------ source */

static void stop_receiver(struct iphone_camera *cam)
{
	if (cam->receiver) {
		obscam_receiver_stop(cam->receiver);
		cam->receiver = NULL;
	}
}

static void start_receiver(struct iphone_camera *cam)
{
	struct obscam_receiver_callbacks cb = {
		.ctx = cam,
		.connected = on_connected,
		.hello = on_hello,
		.config = on_config,
		.frame = on_frame,
		.disconnected = on_disconnected,
		.log = on_log,
	};

	if (cam->usb_mode) {
		void *target = obscam_usbmux_target_create(cam->usb_device, OBSCAM_USB_DEVICE_PORT);
		cam->receiver = obscam_receiver_start_client(obscam_usbmux_connect, target,
							     obscam_usbmux_target_destroy, &cb);
		return;
	}

	char host[256] = "OBS";
	gethostname(host, sizeof(host) - 1);
	host[sizeof(host) - 1] = '\0';
	char *dot = strchr(host, '.');
	if (dot)
		*dot = '\0';

	/* DNS-SD instance names are limited to 63 bytes. */
	char service_name[64];
	snprintf(service_name, sizeof(service_name), "%s - %s", host, obs_source_get_name(cam->source));
	cam->receiver = obscam_receiver_start(cam->port, service_name, &cb);
}

static const char *iphone_camera_get_name(void *unused)
{
	(void)unused;
	return T_("iPhoneCamera");
}

static void iphone_camera_update(void *data, obs_data_t *settings)
{
	struct iphone_camera *cam = data;
	bool usb_mode = strcmp(obs_data_get_string(settings, S_MODE), MODE_USB) == 0;
	uint16_t port = (uint16_t)obs_data_get_int(settings, S_PORT);
	const char *usb_device = obs_data_get_string(settings, S_USB_DEVICE);
	cam->keep_last_frame = obs_data_get_bool(settings, S_KEEP_LAST_FRAME);

	bool changed = !cam->receiver || usb_mode != cam->usb_mode ||
		       (usb_mode ? strcmp(usb_device, cam->usb_device) != 0 : port != cam->port);
	if (changed) {
		stop_receiver(cam);
		cam->usb_mode = usb_mode;
		cam->port = port;
		snprintf(cam->usb_device, sizeof(cam->usb_device), "%s", usb_device);
		start_receiver(cam);
	}
}

static void *iphone_camera_create(obs_data_t *settings, obs_source_t *source)
{
	struct iphone_camera *cam = bzalloc(sizeof(*cam));
	cam->source = source;
	pthread_mutex_init(&cam->mutex, NULL);
	cam->decoder = obscam_decoder_create(on_decoded, cam);
	if (!cam->decoder) {
		blog(LOG_ERROR, "[iphone-camera] FFmpeg H.264 decoder is not available");
		pthread_mutex_destroy(&cam->mutex);
		bfree(cam);
		return NULL;
	}
	obs_source_set_async_unbuffered(source, true);
	iphone_camera_update(cam, settings);
	return cam;
}

static void iphone_camera_destroy(void *data)
{
	struct iphone_camera *cam = data;
	stop_receiver(cam);
	obscam_decoder_destroy(cam->decoder);
	pthread_mutex_destroy(&cam->mutex);
	bfree(cam);
}

static void iphone_camera_defaults(obs_data_t *settings)
{
	obs_data_set_default_string(settings, S_MODE, MODE_WIFI);
	obs_data_set_default_int(settings, S_PORT, OBSCAM_DEFAULT_PORT);
	obs_data_set_default_string(settings, S_USB_DEVICE, "");
	obs_data_set_default_bool(settings, S_KEEP_LAST_FRAME, false);
}

static void append_local_addresses(struct dstr *out)
{
	struct ifaddrs *list = NULL;
	if (getifaddrs(&list) != 0)
		return;
	for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
		if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
			continue;
		if ((ifa->ifa_flags & IFF_LOOPBACK) || !(ifa->ifa_flags & IFF_UP))
			continue;
		char ip[INET_ADDRSTRLEN];
		inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr, ip, sizeof(ip));
		dstr_catf(out, "\n  %s (%s)", ip, ifa->ifa_name);
	}
	freeifaddrs(list);
}

static bool refresh_clicked(obs_properties_t *props, obs_property_t *p, void *data)
{
	(void)props;
	(void)p;
	(void)data;
	return true; /* rebuilds the properties view with fresh status */
}

static void usb_status_text(struct iphone_camera *cam, struct dstr *status, enum obs_text_info_type *info_type)
{
	switch (obscam_receiver_client_status(cam->receiver)) {
	case OBSCAM_CLIENT_UNAVAILABLE:
		dstr_copy(status, T_("Status.USB.Unavailable"));
		*info_type = OBS_TEXT_INFO_ERROR;
		break;
	case OBSCAM_CLIENT_NO_DAEMON:
		dstr_copy(status, T_("Status.USB.NoDaemon"));
		*info_type = OBS_TEXT_INFO_WARNING;
		break;
	case OBSCAM_CLIENT_NO_DEVICE:
		dstr_copy(status, T_("Status.USB.NoDevice"));
		break;
	case OBSCAM_CLIENT_NO_APP:
		dstr_copy(status, T_("Status.USB.NoApp"));
		break;
	default:
		dstr_copy(status, T_("Status.USB.Connecting"));
		break;
	}
}

static bool mode_modified(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	(void)p;
	bool usb = strcmp(obs_data_get_string(settings, S_MODE), MODE_USB) == 0;
	obs_property_set_visible(obs_properties_get(props, S_PORT), !usb);
	obs_property_set_visible(obs_properties_get(props, S_USB_DEVICE), usb);
	return true;
}

static void add_usb_device_list(obs_properties_t *props, struct iphone_camera *cam)
{
	obs_property_t *list = obs_properties_add_list(props, S_USB_DEVICE, T_("USBDevice"), OBS_COMBO_TYPE_LIST,
						       OBS_COMBO_FORMAT_STRING);
	obs_property_list_add_string(list, T_("USBDevice.Any"), "");

	char udids[MAX_USB_DEVICES][OBSCAM_USB_UDID_MAX];
	int count = obscam_usbmux_list(udids, MAX_USB_DEVICES);
	bool selected_listed = !cam || !cam->usb_device[0];
	for (int i = 0; i < count; i++) {
		obs_property_list_add_string(list, udids[i], udids[i]);
		if (cam && strcmp(udids[i], cam->usb_device) == 0)
			selected_listed = true;
	}
	/* Keep a configured but currently unplugged iPhone selectable. */
	if (!selected_listed)
		obs_property_list_add_string(list, cam->usb_device, cam->usb_device);
}

static obs_properties_t *iphone_camera_properties(void *data)
{
	struct iphone_camera *cam = data;
	obs_properties_t *props = obs_properties_create();

	struct dstr status = {0};
	enum obs_text_info_type info_type = OBS_TEXT_INFO_NORMAL;
	if (cam) {
		pthread_mutex_lock(&cam->mutex);
		if (!cam->receiver) {
			dstr_printf(&status, T_("Status.PortError"), cam->port);
			info_type = OBS_TEXT_INFO_ERROR;
		} else if (cam->connected) {
			dstr_printf(&status, T_("Status.Connected"), cam->device_name[0] ? cam->device_name : "iPhone",
				    cam->peer, cam->width, cam->height, cam->fps);
		} else if (cam->usb_mode) {
			usb_status_text(cam, &status, &info_type);
		} else {
			dstr_printf(&status, T_("Status.Waiting"), cam->port);
			append_local_addresses(&status);
		}
		pthread_mutex_unlock(&cam->mutex);
	}
	obs_property_t *p = obs_properties_add_text(props, "status", status.array ? status.array : "", OBS_TEXT_INFO);
	obs_property_text_set_info_type(p, info_type);
	dstr_free(&status);

	obs_properties_add_button2(props, "refresh", T_("RefreshStatus"), refresh_clicked, cam);

	obs_property_t *mode = obs_properties_add_list(props, S_MODE, T_("Mode"), OBS_COMBO_TYPE_LIST,
						       OBS_COMBO_FORMAT_STRING);
	obs_property_list_add_string(mode, T_("Mode.WiFi"), MODE_WIFI);
	obs_property_list_add_string(mode, T_("Mode.USB"), MODE_USB);
	obs_property_set_modified_callback(mode, mode_modified);

	obs_properties_add_int(props, S_PORT, T_("Port"), 1024, 65535, 1);
	add_usb_device_list(props, cam);
	obs_properties_add_bool(props, S_KEEP_LAST_FRAME, T_("KeepLastFrame"));
	return props;
}

static struct obs_source_info iphone_camera_info = {
	.id = "iphone_camera_source",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_DO_NOT_DUPLICATE,
	.get_name = iphone_camera_get_name,
	.create = iphone_camera_create,
	.destroy = iphone_camera_destroy,
	.update = iphone_camera_update,
	.get_defaults = iphone_camera_defaults,
	.get_properties = iphone_camera_properties,
	.icon_type = OBS_ICON_TYPE_CAMERA,
};

bool obs_module_load(void)
{
	obs_register_source(&iphone_camera_info);
	blog(LOG_INFO, "[iphone-camera] loaded (Wi-Fi port %d, USB %s, libavcodec %s)", OBSCAM_DEFAULT_PORT,
	     obscam_usbmux_available() ? "enabled" : "not compiled in", av_version_info());
	return true;
}

const char *obs_module_description(void)
{
	return "Use an iPhone as a camera via the OBS Camera iOS app (Wi-Fi or USB).";
}
