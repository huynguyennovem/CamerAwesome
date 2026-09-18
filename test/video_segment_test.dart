import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VideoSegment.fromMap', () {
    test('parses a full event', () {
      final segment = VideoSegment.fromMap(<Object?, Object?>{
        'type': 'segment',
        'recordingId': '/tmp/video.mp4',
        'sensorIndex': 0,
        'index': 2,
        'path': '/tmp/video_002.mp4',
        'startedAtEpochMs': 1700000000123,
        'durationMs': 55000,
        'bytes': 27500000,
        'usable': true,
        'isFinal': false,
        'reason': 'rollover',
        'error': null,
      });

      expect(segment.recordingId, '/tmp/video.mp4');
      expect(segment.sensorIndex, 0);
      expect(segment.index, 2);
      expect(segment.path, '/tmp/video_002.mp4');
      expect(
        segment.startedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000123),
      );
      expect(segment.duration, const Duration(seconds: 55));
      expect(segment.bytes, 27500000);
      expect(segment.isUsable, isTrue);
      expect(segment.isFinal, isFalse);
      expect(segment.reason, VideoSegmentEndReason.rollover);
      expect(segment.error, isNull);
    });

    test('tolerates missing fields and doubles', () {
      final segment = VideoSegment.fromMap(<Object?, Object?>{
        'recordingId': '/tmp/video.mp4',
        'durationMs': 1234.0,
        'isFinal': true,
        'reason': 'stopped',
      });

      expect(segment.index, 0);
      expect(segment.path, '');
      expect(segment.duration, const Duration(milliseconds: 1234));
      expect(segment.bytes, 0);
      expect(segment.isUsable, isFalse);
      expect(segment.isFinal, isTrue);
      expect(segment.reason, VideoSegmentEndReason.stopped);
    });

    test('maps unknown reasons to unknown', () {
      final segment = VideoSegment.fromMap(<Object?, Object?>{
        'reason': 'something-new',
      });

      expect(segment.reason, VideoSegmentEndReason.unknown);
    });
  });

  group('VideoOptions codec', () {
    test('round-trips segmentDurationMs and iOS bitrate', () {
      final options = VideoOptions(
        enableAudio: false,
        quality: VideoRecordingQuality.fhd,
        android: AndroidVideoOptions(bitrate: 4000000),
        ios: CupertinoVideoOptions(
          fileType: CupertinoFileType.mpeg4,
          codec: CupertinoCodecType.h264,
          bitrate: 4000000,
        ),
        segmentDurationMs: 55000,
      );

      final decoded = VideoOptions.decode(options.encode());

      expect(decoded.segmentDurationMs, 55000);
      expect(decoded.ios?.bitrate, 4000000);
      expect(decoded.ios?.fileType, CupertinoFileType.mpeg4);
      expect(decoded.android?.bitrate, 4000000);
      expect(decoded.quality, VideoRecordingQuality.fhd);
    });

    test('decodes lists written before the hand-added fields', () {
      final decoded = VideoOptions.decode(<Object?>[
        true,
        null,
        null,
        <Object?>[CupertinoFileType.mpeg4.index, null, 30],
      ]);

      expect(decoded.segmentDurationMs, isNull);
      expect(decoded.ios?.bitrate, isNull);
      expect(decoded.ios?.fps, 30);
    });
  });
}
