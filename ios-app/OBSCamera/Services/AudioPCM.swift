import AudioToolbox
import CoreMedia
import Foundation

/// Microphone audio in the wire format: interleaved signed 16-bit little-endian PCM.
struct PCMChunk {
    let pcm: Data
    let sampleRate: UInt32
    let channels: UInt8
    let ptsMicros: UInt64
}

enum AudioPCM {
    /// Converts a captured LPCM sample buffer (16/32-bit integer or 32-bit float,
    /// interleaved or not) to interleaved Int16. Keeps at most 2 channels.
    /// Returns nil for formats it doesn't handle.
    static func chunk(from sampleBuffer: CMSampleBuffer) -> PCMChunk? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return nil }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard flags & kAudioFormatFlagIsBigEndian == 0,
              isFloat ? bits == 32 : (bits == 16 || bits == 32),
              asbd.mSampleRate > 0 else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let sourceChannels = Int(asbd.mChannelsPerFrame)
        guard frameCount > 0, sourceChannels > 0 else { return nil }
        let outputChannels = min(sourceChannels, 2)

        // Get the sample data as an AudioBufferList.
        let listFlags = kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment
        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: listFlags, blockBufferOut: nil
        ) == noErr, listSize > 0 else { return nil }

        let listMemory = UnsafeMutableRawPointer.allocate(byteCount: listSize,
                                                          alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listMemory.deallocate() }
        let list = listMemory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: listFlags, blockBufferOut: &blockBuffer
        ) == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count >= (isNonInterleaved ? sourceChannels : 1) else { return nil }

        let bytesPerSample = bits / 8
        var output = [Int16](repeating: 0, count: frameCount * outputChannels)
        // The list points into blockBuffer: keep it alive until we're done reading.
        let complete = withExtendedLifetime(blockBuffer) { () -> Bool in
            for channel in 0..<outputChannels {
                let buffer = isNonInterleaved ? buffers[channel] : buffers[0]
                guard let base = buffer.mData else { return false }
                let stride = isNonInterleaved ? 1 : sourceChannels
                let offset = isNonInterleaved ? 0 : channel
                let available = Int(buffer.mDataByteSize) / bytesPerSample
                for frame in 0..<frameCount {
                    let index = frame * stride + offset
                    guard index < available else { break }
                    let sample: Int16
                    if isFloat {
                        let value = base.assumingMemoryBound(to: Float32.self)[index]
                        sample = Int16(max(-1, min(1, value)) * Float32(Int16.max))
                    } else if bits == 16 {
                        sample = base.assumingMemoryBound(to: Int16.self)[index]
                    } else {
                        sample = Int16(truncatingIfNeeded: base.assumingMemoryBound(to: Int32.self)[index] >> 16)
                    }
                    output[frame * outputChannels + channel] = sample
                }
            }
            return true
        }
        guard complete else { return nil }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsMicros = pts.isValid
            ? UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value)) : 0
        // iOS is little-endian, so the array's bytes are already s16le.
        let pcm = output.withUnsafeBufferPointer { Data(buffer: $0) }
        return PCMChunk(pcm: pcm, sampleRate: UInt32(asbd.mSampleRate.rounded()), channels: UInt8(outputChannels),
                        ptsMicros: ptsMicros)
    }
}
