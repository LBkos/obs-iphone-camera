/*
 * Wire protocol shared by the iOS app (sender) and the OBS plugin (receiver).
 *
 * Transport: one TCP connection carrying iPhone -> OBS data.
 *   Wi-Fi: OBS listens (OBSCAM_DEFAULT_PORT), the iPhone connects.
 *   USB:   the iPhone listens (OBSCAM_USB_DEVICE_PORT), OBS connects via usbmuxd.
 * Every message:  [type: u8][length: u32 big-endian][payload: length bytes]
 *
 *   HELLO  (0x01)  payload: UTF-8 device name
 *   CONFIG (0x02)  payload: H.264 SPS + PPS in Annex-B form (00 00 00 01 ...)
 *   FRAME  (0x03)  payload: [pts_us: u64 BE][flags: u8][H.264 access unit, Annex-B]
 *                  flags bit 0 = keyframe
 *   PING   (0x04)  payload: empty (keep-alive while the camera is paused)
 *   CODEC  (0x05)  payload: [codec: u8]  0 = H.264, 1 = HEVC (H.265)
 *                  Sent before every CONFIG. Without it the stream is H.264,
 *                  so older apps keep working.
 *   AUDIO  (0x06)  payload: [pts_us: u64 BE][sample_rate: u32 BE][channels: u8]
 *                           [PCM, signed 16-bit little-endian, interleaved]
 *
 * For HEVC, CONFIG carries VPS + SPS + PPS. Unknown message types are skipped,
 * so a newer app still works with an older plugin (H.264, no audio).
 *
 * Keep in sync with ios-app/OBSCamera/Models/WireProtocol.swift.
 */
#pragma once

#include <stdint.h>

#define OBSCAM_DEFAULT_PORT 47100
/* Port the iOS app listens on (device loopback) in USB mode, reached via usbmuxd. */
#define OBSCAM_USB_DEVICE_PORT 47101
#define OBSCAM_SERVICE_TYPE "_obsiphonecam._tcp"

#define OBSCAM_MSG_HELLO 0x01
#define OBSCAM_MSG_CONFIG 0x02
#define OBSCAM_MSG_FRAME 0x03
#define OBSCAM_MSG_PING 0x04
#define OBSCAM_MSG_CODEC 0x05
#define OBSCAM_MSG_AUDIO 0x06

#define OBSCAM_CODEC_H264 0
#define OBSCAM_CODEC_HEVC 1

#define OBSCAM_HEADER_SIZE 5
#define OBSCAM_FRAME_PREFIX_SIZE 9
#define OBSCAM_AUDIO_PREFIX_SIZE 13
#define OBSCAM_MAX_AUDIO_CHANNELS 8
#define OBSCAM_MAX_PAYLOAD (16u * 1024u * 1024u)

#define OBSCAM_FLAG_KEYFRAME 0x01
