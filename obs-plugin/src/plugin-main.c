/*
 * OBS source "iPhone Camera": receives H.264 / HEVC video and PCM audio from
 * the OBS Camera iOS app over Wi-Fi or a USB cable, decodes the video with
 * FFmpeg and outputs it as an asynchronous video + audio source.
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
#include <stdlib.h>
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
/* Audio timestamps are re-synced to the local clock when they drift this far. */
#define AUDIO_RESYNC_NS 500000000LL

/* 10-bit / HDR output needs OBS 28+. */
#if LIBOBS_API_MAJOR_VER >= 28
#define HAVE_OBS_HDR 1
#endif

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
	uint8_t codec;   /* OBSCAM_CODEC_*, for the status text */
	bool has_audio;  /* for the status text */
	bool hdr;        /* last frame was HLG/PQ */

	/* Receiver thread only. */
	bool audio_synced;
	int64_t audio_offset_ns; /* local clock - phone clock */
	bool warned_audio;
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
	cam->codec = OBSCAM_CODEC_H264;
	cam->has_audio = false;
	cam->hdr = false;
	pthread_mutex_unlock(&cam->mutex);
	/* Each connection starts as H.264 until the app says otherwise. */
	obscam_decoder_set_codec(cam->decoder, OBSCAM_CODEC_H264);
	cam->audio_synced = false;
}

static void on_hello(void *ctx, const char *name)
{
	struct iphone_camera *cam = ctx;
	pthread_mutex_lock(&cam->mutex);
	snprintf(cam->device_name, sizeof(cam->device_name), "%s", name);
	pthread_mutex_unlock(&cam->mutex);
}

static void on_codec(void *ctx, uint8_t codec)
{
	struct iphone_camera *cam = ctx;
	pthread_mutex_lock(&cam->mutex);
	bool changed = cam->codec != codec;
	cam->codec = codec;
	pthread_mutex_unlock(&cam->mutex);
	if (!obscam_decoder_set_codec(cam->decoder, codec))
		blog(LOG_ERROR, "[iphone-camera] cannot open decoder for codec %u (%s)", codec,
		     codec == OBSCAM_CODEC_HEVC ? "HEVC: FFmpeg built without the hevc decoder?" : "unknown codec");
	else if (changed)
		blog(LOG_INFO, "[iphone-camera] '%s': codec %s", obs_source_get_name(cam->source),
		     codec == OBSCAM_CODEC_HEVC ? "HEVC" : "H.264");
}

static void on_audio(void *ctx, uint64_t pts_us, uint32_t sample_rate, uint8_t channels, const uint8_t *pcm,
		     size_t frames)
{
	struct iphone_camera *cam = ctx;
	if (channels > 2) {
		if (!cam->warned_audio) {
			blog(LOG_WARNING, "[iphone-camera] unsupported audio channel count %u", channels);
			cam->warned_audio = true;
		}
		return;
	}

	/* Map the phone's capture clock to ours. The offset is taken from the
	 * first packet and kept, so the audio stays continuous; a pause or a
	 * big drift re-syncs it. */
	int64_t now = (int64_t)os_gettime_ns();
	int64_t pts_ns = (int64_t)pts_us * 1000;
	int64_t ts = pts_ns + cam->audio_offset_ns;
	if (!cam->audio_synced || llabs(now - ts) > AUDIO_RESYNC_NS) {
		cam->audio_offset_ns = now - pts_ns;
		cam->audio_synced = true;
		ts = now;
	}

	struct obs_source_audio audio;
	memset(&audio, 0, sizeof(audio));
	audio.data[0] = pcm;
	audio.frames = (uint32_t)frames;
	audio.speakers = channels == 1 ? SPEAKERS_MONO : SPEAKERS_STEREO;
	audio.format = AUDIO_FORMAT_16BIT;
	audio.samples_per_sec = sample_rate;
	audio.timestamp = (uint64_t)ts;
	obs_source_output_audio(cam->source, &audio);

	pthread_mutex_lock(&cam->mutex);
	cam->has_audio = true;
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

#ifdef HAVE_OBS_HDR
/* HDR (BT.2100) needs both the right transfer function and a 10-bit format. */
static enum video_colorspace map_hdr_colorspace(const AVFrame *f, enum video_trc *trc)
{
	switch (f->color_trc) {
	case AVCOL_TRC_ARIB_STD_B67:
		*trc = VIDEO_TRC_HLG;
		return VIDEO_CS_2100_HLG;
	case AVCOL_TRC_SMPTE2084:
		*trc = VIDEO_TRC_PQ;
		return VIDEO_CS_2100_PQ;
	default:
		*trc = VIDEO_TRC_DEFAULT;
		return map_colorspace(f);
	}
}
#endif

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
#ifdef HAVE_OBS_HDR
	case AV_PIX_FMT_YUV420P10LE:
		format = VIDEO_FORMAT_I010;
		break;
	case AV_PIX_FMT_P010LE:
		format = VIDEO_FORMAT_P010;
		break;
#endif
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
	enum video_range_type range = full_range ? VIDEO_RANGE_FULL : VIDEO_RANGE_PARTIAL;
	bool hdr = false;
#ifdef HAVE_OBS_HDR
	enum video_trc trc = VIDEO_TRC_DEFAULT;
	enum video_colorspace cs = map_colorspace(f);
	if (format == VIDEO_FORMAT_I010 || format == VIDEO_FORMAT_P010) {
		cs = map_hdr_colorspace(f, &trc);
		hdr = trc != VIDEO_TRC_DEFAULT;
	}
	frame.trc = (uint8_t)trc;
	video_format_get_parameters_for_format(cs, range, format, frame.color_matrix, frame.color_range_min,
					       frame.color_range_max);
#else
	/* OBS 27: 8-bit formats only. */
	video_format_get_parameters(map_colorspace(f), range, frame.color_matrix, frame.color_range_min,
				    frame.color_range_max);
#endif

	obs_source_output_video(cam->source, &frame);

	uint64_t now = frame.timestamp;
	pthread_mutex_lock(&cam->mutex);
	cam->width = frame.width;
	cam->height = frame.height;
	cam->hdr = hdr;
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
		.codec = on_codec,
		.config = on_config,
		.frame = on_frame,
		.audio = on_audio,
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
			dstr_catf(&status, "\n%s%s%s", cam->codec == OBSCAM_CODEC_HEVC ? "HEVC" : "H.264",
				  cam->hdr ? " HDR" : "", cam->has_audio ? T_("Status.WithAudio") : "");
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
	.output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_AUDIO | OBS_SOURCE_DO_NOT_DUPLICATE,
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
	return "Use an iPhone as a camera and microphone via the OBS Camera iOS app (Wi-Fi or USB).";
}
