using System.Buffers.Binary;

namespace viewMirror.App;

internal enum VideoCodec { H264, Hevc }

/// <summary>Identifies parameter sets from UxPlay's H.264/H.265 RTP payload (PT 96).</summary>
internal static class RtpVideoPacket
{
    public static bool TryRead(ReadOnlySpan<byte> packet, out uint ssrc, out VideoCodec? codec)
    {
        ssrc = 0;
        codec = null;
        if (packet.Length < 12 || packet[0] >> 6 != 2 || (packet[1] & 0x7f) != 96) return false;
        int offset = 12 + (packet[0] & 15) * 4;
        if (offset > packet.Length) return false;
        if ((packet[0] & 0x10) != 0)
        {
            if (offset + 4 > packet.Length) return false;
            offset += 4 + BinaryPrimitives.ReadUInt16BigEndian(packet.Slice(offset + 2, 2)) * 4;
        }
        int end = packet.Length;
        if ((packet[0] & 0x20) != 0)
        {
            int padding = packet[^1];
            if (padding == 0 || padding > end - offset) return false;
            end -= padding;
        }
        if (offset >= end) return false;
        ssrc = BinaryPrimitives.ReadUInt32BigEndian(packet.Slice(8, 4));
        ReadOnlySpan<byte> payload = packet[offset..end];
        codec = ParameterSetCodec(payload);
        // Default payloader aggregation is disabled; also accept STAP-A/AP without DONL.
        int aggregationHeader = (payload[0] & 31) == 24 ? 1 : ((payload[0] >> 1) & 63) == 48 ? 2 : 0;
        if (codec is null && aggregationHeader != 0)
        {
            int position = aggregationHeader;
            while (position + 2 <= payload.Length)
            {
                int size = BinaryPrimitives.ReadUInt16BigEndian(payload.Slice(position, 2));
                position += 2;
                if (size == 0 || size > payload.Length - position) return false;
                codec = ParameterSetCodec(payload.Slice(position, size));
                if (codec is not null) break;
                position += size;
            }
        }
        return true;
    }

    private static VideoCodec? ParameterSetCodec(ReadOnlySpan<byte> nal)
    {
        if (nal.Length < 2 || (nal[0] & 0x80) != 0) return null;
        // PPS alone is ambiguous with an HEVC IDR header (0x28). H.264 must start with SPS.
        if ((nal[0] & 31) == 7 && (nal[0] & 0x60) != 0) return VideoCodec.H264;
        int type = (nal[0] >> 1) & 63;
        if (type is 32 or 33 or 34 && (nal[0] & 1) == 0 && (nal[1] & 0xf8) == 0 && (nal[1] & 7) != 0)
            return VideoCodec.Hevc;
        return null;
    }
}
