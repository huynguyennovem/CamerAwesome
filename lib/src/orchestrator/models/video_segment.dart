/// Why a segment of a segmented video recording was closed.
///
/// See `VideoOptions.segmentDurationMs`.
enum VideoSegmentEndReason {
  /// The segment reached the configured duration and the next one started.
  rollover,

  /// The recording was stopped with `stopRecordingVideo`.
  stopped,

  /// The native duration limit (a safety net slightly above the configured
  /// duration) was hit and the next segment started.
  durationLimit,

  /// The recording ended without being asked to (camera closed, session
  /// interrupted, encoder error...).
  interrupted,

  /// The segment could not be written.
  error,

  /// A reason this version of the plugin does not know about.
  unknown;

  static VideoSegmentEndReason fromName(String? name) {
    for (final reason in values) {
      if (reason.name == name) {
        return reason;
      }
    }
    return unknown;
  }
}

/// One complete, playable video file produced by a segmented recording.
///
/// Segmented recording is enabled with `VideoOptions.segmentDurationMs`.
/// Segments are delivered by `CamerawesomePlugin.listenVideoSegments()` in
/// order. The last segment of a recording has [isFinal] set, and it is always
/// delivered before `stopRecordingVideo` completes.
class VideoSegment {
  const VideoSegment({
    required this.recordingId,
    required this.sensorIndex,
    required this.index,
    required this.path,
    required this.startedAt,
    required this.duration,
    required this.bytes,
    required this.isUsable,
    required this.isFinal,
    required this.reason,
    this.error,
  });

  /// Parses an event sent on the `camerawesome/video_segments` channel.
  factory VideoSegment.fromMap(Map<Object?, Object?> map) {
    int readInt(String key) => (map[key] as num?)?.toInt() ?? 0;

    return VideoSegment(
      recordingId: map['recordingId'] as String? ?? '',
      sensorIndex: readInt('sensorIndex'),
      index: readInt('index'),
      path: map['path'] as String? ?? '',
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        readInt('startedAtEpochMs'),
      ),
      duration: Duration(milliseconds: readInt('durationMs')),
      bytes: readInt('bytes'),
      isUsable: map['usable'] as bool? ?? false,
      isFinal: map['isFinal'] as bool? ?? false,
      reason: VideoSegmentEndReason.fromName(map['reason'] as String?),
      error: map['error'] as String?,
    );
  }

  /// The path the video path builder returned for this recording. It matches
  /// `CaptureRequest.path` of the recording, and is also the path of the
  /// segment at [index] 0.
  final String recordingId;

  /// Index of the sensor that recorded this segment (always 0 today: segmented
  /// recording supports a single sensor).
  final int sensorIndex;

  /// 0-based position of this segment within its recording.
  final int index;

  /// Absolute path of the video file.
  final String path;

  /// Device wall-clock time of the first frame in this file.
  final DateTime startedAt;

  /// Media duration of this file.
  final Duration duration;

  /// File size in bytes (0 when [isUsable] is false).
  final int bytes;

  /// False when the file could not be written. Such files are deleted
  /// natively and must be ignored.
  final bool isUsable;

  /// True for the last segment of the recording.
  final bool isFinal;

  /// Why this segment was closed.
  final VideoSegmentEndReason reason;

  /// Native error description, if any.
  final String? error;

  @override
  String toString() {
    return 'VideoSegment(recordingId: $recordingId, index: $index, '
        'path: $path, startedAt: $startedAt, duration: $duration, '
        'bytes: $bytes, isUsable: $isUsable, isFinal: $isFinal, '
        'reason: ${reason.name}, error: $error)';
  }
}

/// Callback receiving the finished files of a segmented recording.
typedef OnVideoSegment = void Function(VideoSegment segment);
