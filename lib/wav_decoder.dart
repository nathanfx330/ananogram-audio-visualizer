// ./lib/wav_decoder.dart
//
// Pure-Dart RIFF/WAV decoder. Parses the container, converts any
// supported sample format to normalized mono Float32, and resamples
// to the requested target rate via Resampler. No dependencies
// outside dart core + resampler.dart.
//
// Supported: PCM 8-bit unsigned, 16/24/32-bit signed,
//            IEEE float 32/64, plus WAVE_FORMAT_EXTENSIBLE
//            wrappers around those.

import 'dart:io';
import 'dart:typed_data';

import 'resampler.dart';

class WavDecodeResult {
  final Float32List data;      // mono, normalized to peak 1.0
  final int sampleRate;        // post-resample rate
  final double durationSec;

  const WavDecodeResult({
    required this.data,
    required this.sampleRate,
    required this.durationSec,
  });
}

class WavDecodeException implements Exception {
  final String message;
  const WavDecodeException(this.message);

  @override
  String toString() => 'WavDecodeException: $message';
}

// Format tags we understand.
const int _fmtPcm = 0x0001;
const int _fmtIeeeFloat = 0x0003;
const int _fmtExtensible = 0xFFFE;

class WavDecoder {
  /// Decodes [path] and returns mono float32 audio at [targetRate] Hz,
  /// peak-normalized to 1.0.
  ///
  /// Throws [WavDecodeException] on malformed or unsupported files,
  /// and whatever dart:io throws on filesystem errors.
  static WavDecodeResult decodeFile(String path, {int targetRate = 44100}) {
    final Uint8List bytes = File(path).readAsBytesSync();
    return decodeBytes(bytes, targetRate: targetRate);
  }

  static WavDecodeResult decodeBytes(Uint8List bytes,
      {int targetRate = 44100}) {
    if (bytes.length < 12) {
      throw const WavDecodeException('File too small to be a WAV.');
    }

    final ByteData bd = ByteData.sublistView(bytes);

    // --- RIFF header ---
    if (_fourCC(bytes, 0) != 'RIFF' || _fourCC(bytes, 8) != 'WAVE') {
      throw const WavDecodeException('Not a RIFF/WAVE file.');
    }

    // --- Walk chunks ---
    int formatTag = 0;
    int channels = 0;
    int sampleRate = 0;
    int bitsPerSample = 0;
    int? dataOffset;
    int? dataLength;

    int pos = 12;
    while (pos + 8 <= bytes.length) {
      final String id = _fourCC(bytes, pos);
      final int size = bd.getUint32(pos + 4, Endian.little);
      final int body = pos + 8;

      if (body + size > bytes.length && id != 'data') {
        throw WavDecodeException(
            'Chunk "$id" claims $size bytes past end of file.');
      }

      if (id == 'fmt ') {
        if (size < 16) {
          throw const WavDecodeException('fmt chunk too small.');
        }
        formatTag = bd.getUint16(body, Endian.little);
        channels = bd.getUint16(body + 2, Endian.little);
        sampleRate = bd.getUint32(body + 4, Endian.little);
        bitsPerSample = bd.getUint16(body + 14, Endian.little);

        // WAVE_FORMAT_EXTENSIBLE: real format is in the SubFormat
        // GUID; its first two bytes are the format tag.
        if (formatTag == _fmtExtensible) {
          if (size < 40) {
            throw const WavDecodeException(
                'Extensible fmt chunk too small for SubFormat.');
          }
          formatTag = bd.getUint16(body + 24, Endian.little);
        }
      } else if (id == 'data') {
        dataOffset = body;
        // Some writers (streamed captures) put 0 or garbage here;
        // clamp to what's actually in the file.
        dataLength = size;
        if (dataLength == 0 || body + dataLength > bytes.length) {
          dataLength = bytes.length - body;
        }
      }

      // Chunks are word-aligned: odd sizes carry a pad byte.
      pos = body + size + (size & 1);
    }

    if (dataOffset == null || dataLength == null) {
      throw const WavDecodeException('No data chunk found.');
    }
    if (channels <= 0 || sampleRate <= 0 || bitsPerSample <= 0) {
      throw const WavDecodeException('Missing or invalid fmt chunk.');
    }
    if (formatTag != _fmtPcm && formatTag != _fmtIeeeFloat) {
      throw WavDecodeException(
          'Unsupported format tag 0x${formatTag.toRadixString(16)} '
          '(only PCM and IEEE float are supported).');
    }

    final int bytesPerSample = bitsPerSample ~/ 8;
    if (bytesPerSample == 0) {
      throw WavDecodeException('Invalid bits per sample: $bitsPerSample.');
    }
    final int frameSize = bytesPerSample * channels;
    final int frameCount = dataLength ~/ frameSize;
    if (frameCount == 0) {
      throw const WavDecodeException('Data chunk contains no frames.');
    }

    // --- Decode to mono float32 ---
    final Float32List mono = Float32List(frameCount);
    final double invChannels = 1.0 / channels;

    switch (formatTag) {
      case _fmtPcm:
        switch (bitsPerSample) {
          case 8: // unsigned
            for (int f = 0; f < frameCount; f++) {
              final int base = dataOffset + f * frameSize;
              double acc = 0.0;
              for (int c = 0; c < channels; c++) {
                acc += (bytes[base + c] - 128) / 128.0;
              }
              mono[f] = acc * invChannels;
            }
            break;
          case 16:
            for (int f = 0; f < frameCount; f++) {
              final int base = dataOffset + f * frameSize;
              double acc = 0.0;
              for (int c = 0; c < channels; c++) {
                acc +=
                    bd.getInt16(base + c * 2, Endian.little) / 32768.0;
              }
              mono[f] = acc * invChannels;
            }
            break;
          case 24:
            for (int f = 0; f < frameCount; f++) {
              final int base = dataOffset + f * frameSize;
              double acc = 0.0;
              for (int c = 0; c < channels; c++) {
                final int o = base + c * 3;
                int v = bytes[o] | (bytes[o + 1] << 8) | (bytes[o + 2] << 16);
                if (v & 0x800000 != 0) v -= 0x1000000; // sign extend
                acc += v / 8388608.0;
              }
              mono[f] = acc * invChannels;
            }
            break;
          case 32:
            for (int f = 0; f < frameCount; f++) {
              final int base = dataOffset + f * frameSize;
              double acc = 0.0;
              for (int c = 0; c < channels; c++) {
                acc += bd.getInt32(base + c * 4, Endian.little) /
                    2147483648.0;
              }
              mono[f] = acc * invChannels;
            }
            break;
          default:
            throw WavDecodeException(
                'Unsupported PCM bit depth: $bitsPerSample.');
        }
        break;

      case _fmtIeeeFloat:
        switch (bitsPerSample) {
          case 32:
            for (int f = 0; f < frameCount; f++) {
              final int base = dataOffset + f * frameSize;
              double acc = 0.0;
              for (int c = 0; c < channels; c++) {
                acc += bd.getFloat32(base + c * 4, Endian.little);
              }
              mono[f] = acc * invChannels;
            }
            break;
          case 64:
            for (int f = 0; f < frameCount; f++) {
              final int base = dataOffset + f * frameSize;
              double acc = 0.0;
              for (int c = 0; c < channels; c++) {
                acc += bd.getFloat64(base + c * 8, Endian.little);
              }
              mono[f] = acc * invChannels;
            }
            break;
          default:
            throw WavDecodeException(
                'Unsupported float bit depth: $bitsPerSample.');
        }
        break;
    }

    // --- Resample ---
    Float32List out = mono;
    int outRate = sampleRate;
    if (sampleRate != targetRate) {
      out = Resampler.resample(mono, sampleRate, targetRate);
      outRate = targetRate;
    }

    // --- Peak normalize (matches app.py behavior) ---
    double peak = 0.0;
    for (int i = 0; i < out.length; i++) {
      final double a = out[i].abs();
      if (a > peak) peak = a;
    }
    if (peak > 0.0) {
      final double inv = 1.0 / peak;
      for (int i = 0; i < out.length; i++) {
        out[i] *= inv;
      }
    }

    return WavDecodeResult(
      data: out,
      sampleRate: outRate,
      durationSec: out.length / outRate,
    );
  }

  static String _fourCC(Uint8List bytes, int offset) {
    return String.fromCharCodes(bytes.sublist(offset, offset + 4));
  }
}