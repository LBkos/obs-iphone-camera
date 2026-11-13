/*
 * Wire protocol shared by the iOS app (sender) and the OBS plugin (receiver).
 *
 * Transport: one TCP connection, iPhone -> OBS.
 * Every message:  [type: u8][length: u32 big-endian][payload: length bytes]
 *
 *   HELLO  (0x01)  payload: UTF-8 device name
 *   CONFIG (0x02)  payload: H.264 SPS + PPS in Annex-B form (00 00 00 01 ...)
 *   FRAME  (0x03)  payload: [pts_us: u64 BE][flags: u8][H.264 access unit, Annex-B]
 *                  flags bit 0 = keyframe
 *   PING   (0x04)  payload: empty (keep-alive while the camera is paused)
 *
 * Keep in sync with ios-app/OBSCamera/Models/WireProtocol.swift.
 */
#pragma once

#include <stdint.h>

#define OBSCAM_DEFAULT_PORT 47100
#define OBSCAM_SERVICE_TYPE "_obsiphonecam._tcp"

#define OBSCAM_MSG_HELLO 0x01
#define OBSCAM_MSG_CONFIG 0x02
#define OBSCAM_MSG_FRAME 0x03
#define OBSCAM_MSG_PING 0x04

#define OBSCAM_HEADER_SIZE 5
#define OBSCAM_FRAME_PREFIX_SIZE 9
#define OBSCAM_MAX_PAYLOAD (16u * 1024u * 1024u)

#define OBSCAM_FLAG_KEYFRAME 0x01
