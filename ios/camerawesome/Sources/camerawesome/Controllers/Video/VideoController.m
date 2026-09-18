//
//  VideoController.m
//  camerawesome
//
//  Created by Dimitri Dessus on 17/12/2020.
//

#import "VideoController.h"

FourCharCode const videoFormat = kCVPixelFormatType_32BGRA;

/// Shortest accepted segment duration.
static const NSInteger kMinSegmentDurationMs = 5000;
/// The next segment writer is created this long before the boundary so the
/// switch itself doesn't stall the sample queue.
static const double kPrepareNextWriterAheadMs = 1500.0;
/// Minimum delay between two attempts to create the next segment writer.
static const double kNextWriterRetrySeconds = 1.0;
/// A pause between two frames longer than this (interruption, sensor switch)
/// starts a new segment instead of freezing the picture inside a file.
static const double kMaxFrameGapSeconds = 1.0;

/// Book-keeping of one segmented recording (VideoOptions.segmentDurationMs).
@interface CASegmentedRecording : NSObject
@property(nonatomic, copy) NSString *recordingId;
@property(nonatomic, strong) dispatch_group_t finishGroup;
/// Event queue only.
@property(nonatomic, assign) BOOL anyUsable;
/// Event queue only.
@property(nonatomic, copy, nullable) NSDictionary *finalEvent;
/// Event queue only.
@property(nonatomic, assign) BOOL finalEventSent;
@end

@implementation CASegmentedRecording
@end

@implementation VideoController {
  /// Serial queue ordering segment results and completions.
  dispatch_queue_t _eventQueue;
  /// Recording in progress; accessed on the sample queue.
  CASegmentedRecording *_segmented;
  /// Last segmented recording, kept to answer a late stop request.
  CASegmentedRecording *_lastSegmented;
  NSString *_currentPath;
  NSInteger _segmentIndex;
  CMTime _segmentStartPTS;
  int64_t _segmentStartEpochMs;
  CMTime _lastAppendedVideoPTS;
  BOOL _hasAppendedVideo;
  CMTime _nominalFrameDuration;
  // Pre-warmed writer of the next segment.
  AVAssetWriter *_nextWriter;
  AVAssetWriterInput *_nextVideoInput;
  AVAssetWriterInputPixelBufferAdaptor *_nextAdaptor;
  AVAssetWriterInput *_nextAudioInput;
  NSString *_nextPath;
  CMTime _nextWriterRetryPTS;
}

- (instancetype)init {
  self = [super init];
  _isRecording = NO;
  _isAudioEnabled = YES;
  _isPaused = NO;
  _segmentDurationMs = 0;
  _eventQueue = dispatch_queue_create("camerawesome.video_segments", DISPATCH_QUEUE_SERIAL);
  
  return self;
}

- (bool)isSegmentedRecordingActive {
  return _segmented != nil;
}

# pragma mark - User video interactions

/// Start recording video at given path
- (void)recordVideoAtPath:(NSString *)path captureDevice:(AVCaptureDevice *)device orientation:(NSInteger)orientation audioSetupCallback:(OnAudioSetup)audioSetupCallback videoWriterCallback:(OnVideoWriterSetup)videoWriterCallback options:(CupertinoVideoOptions *)options quality:(VideoRecordingQuality)quality completion:(nonnull void (^)(FlutterError * _Nullable))completion {
  _options = options;
  _recordingQuality = quality;
  _orientation = orientation;
  _captureDevice = device;
  
  if (_segmentDurationMs > 0) {
    [self startSegmentedRecordingAtPath:path audioSetupCallback:audioSetupCallback videoWriterCallback:videoWriterCallback completion:completion];
    return;
  }
  
  // Create audio & video writer
  if (![self setupWriterForPath:path audioSetupCallback:audioSetupCallback options:options completion:completion]) {
    return;
  }
  // Call parent to add delegates for video & audio (if needed)
  videoWriterCallback();
  
  _isRecording = YES;
  _videoTimeOffset = CMTimeMake(0, 1);
  _audioTimeOffset = CMTimeMake(0, 1);
  _videoIsDisconnected = NO;
  _audioIsDisconnected = NO;
  
  // Change video FPS if provided
  if (_options && _options.fps != nil && _options.fps > 0) {
    [self adjustCameraFPS:_options.fps];
  }
}

/// Stop recording video
- (void)stopRecordingVideo:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  if (_segmentDurationMs > 0 || _segmented != nil) {
    [self stopSegmentedRecording:completion];
    return;
  }
  
  [self resetCameraFPSIfNeeded];
  
  if (_isRecording) {
    _isRecording = NO;
    if (_videoWriter.status == AVAssetWriterStatusWriting) {
      [_videoWriter finishWritingWithCompletionHandler:^{
        if (self->_videoWriter.status == AVAssetWriterStatusCompleted) {
          completion(@(YES), nil);
        } else {
          completion(@(NO), [FlutterError errorWithCode:@"VIDEO_ERROR" message:@"impossible to completely write video" details:@""]);
        }
      }];
    } else {
      // No sample was ever written (or the writer failed): finishWriting would
      // throw in these states, and the completion was never called before.
      completion(@(NO), [FlutterError errorWithCode:@"VIDEO_ERROR" message:@"no video data was written" details:_videoWriter.error.localizedDescription ?: @""]);
    }
  } else {
    completion(@(NO), [FlutterError errorWithCode:@"VIDEO_ERROR" message:@"video is not recording" details:@""]);
  }
}

- (void)pauseVideoRecording {
  _isPaused = YES;
}

- (void)resumeVideoRecording {
  _isPaused = NO;
}

- (void)resetCameraFPSIfNeeded {
  if (_options && _options.fps != nil && _options.fps > 0) {
    // Reset camera FPS
    [self adjustCameraFPS:@(30)];
  }
}

# pragma mark - Segmented recording

- (void)startSegmentedRecordingAtPath:(NSString *)path audioSetupCallback:(OnAudioSetup)audioSetupCallback videoWriterCallback:(OnVideoWriterSetup)videoWriterCallback completion:(nonnull void (^)(FlutterError * _Nullable))completion {
  if (path == nil) {
    completion([FlutterError errorWithCode:@"VIDEO_ERROR" message:@"impossible to write video at path" details:@""]);
    return;
  }
  if (_segmentDurationMs < kMinSegmentDurationMs) {
    _segmentDurationMs = kMinSegmentDurationMs;
  }
  if (_options == nil || _options.fileType != CupertinoFileTypeMpeg4) {
    NSLog(@"camerawesome: segmented recording writes %@ files; pass CupertinoVideoOptions(fileType: mpeg4) for .mp4 output", _options == nil ? @"QuickTime" : @"non-MPEG-4");
  }
  if (_isAudioEnabled && !_isAudioSetup) {
    audioSetupCallback();
  }
  
  // AVAssetWriter refuses to overwrite an existing file.
  [self removeFileAtPath:path];
  AVAssetWriter *writer = nil;
  AVAssetWriterInput *videoInput = nil;
  AVAssetWriterInputPixelBufferAdaptor *adaptor = nil;
  AVAssetWriterInput *audioInput = nil;
  NSError *error = nil;
  if (![self makeWriterForPath:path writer:&writer videoInput:&videoInput adaptor:&adaptor audioInput:&audioInput error:&error]) {
    completion([FlutterError errorWithCode:@"VIDEO_ERROR" message:@"impossible to create video writer, check your options" details:error.description ?: path]);
    return;
  }
  
  CASegmentedRecording *recording = [[CASegmentedRecording alloc] init];
  recording.recordingId = path;
  recording.finishGroup = dispatch_group_create();
  _segmented = recording;
  // Don't answer a later stop with the previous recording's outcome.
  _lastSegmented = nil;
  
  _videoWriter = writer;
  _videoWriterInput = videoInput;
  _videoAdaptor = adaptor;
  _audioWriterInput = audioInput;
  _currentPath = path;
  _segmentIndex = 0;
  _hasAppendedVideo = NO;
  _segmentStartPTS = kCMTimeInvalid;
  _lastAppendedVideoPTS = kCMTimeInvalid;
  _segmentStartEpochMs = 0;
  _nextWriterRetryPTS = kCMTimeInvalid;
  _nominalFrameDuration = [self nominalFrameDuration];
  
  _isPaused = NO;
  _videoTimeOffset = CMTimeMake(0, 1);
  _audioTimeOffset = CMTimeMake(0, 1);
  _videoIsDisconnected = NO;
  _audioIsDisconnected = NO;
  _isRecording = YES;
  
  // Call parent to add delegates for video & audio (if needed) and complete.
  videoWriterCallback();
  
  if (_options && _options.fps != nil && _options.fps > 0) {
    [self adjustCameraFPS:_options.fps];
  }
}

- (void)stopSegmentedRecording:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  CASegmentedRecording *recording = _segmented;
  if (recording == nil) {
    // Ended natively (writer failure) or already stopped: report its outcome.
    if (_lastSegmented != nil) {
      [self notifyWhenFinished:_lastSegmented completion:completion];
    } else {
      // No error: the Dart side must still leave its recording state.
      completion(@(NO), nil);
    }
    return;
  }
  [self endSegmentedRecording:recording reason:@"stopped" error:nil];
  [self notifyWhenFinished:recording completion:completion];
}

/// Closes the current segment as the final one. Must run on the sample queue.
- (void)endSegmentedRecording:(CASegmentedRecording *)recording reason:(NSString *)reason error:(nullable NSString *)errorDescription {
  _isRecording = NO;
  _segmented = nil;
  _lastSegmented = recording;
  [self resetCameraFPSIfNeeded];
  [self discardNextWriter];
  
  CMTime endTime = kCMTimeInvalid;
  int64_t durationMs = 0;
  if (_hasAppendedVideo) {
    endTime = CMTimeAdd(_lastAppendedVideoPTS, _nominalFrameDuration);
    durationMs = [self millisecondsFrom:_segmentStartPTS to:endTime];
  } else if (_videoWriter.status == AVAssetWriterStatusWriting) {
    // Started (pre-warmed) but no frame appended: nothing to keep.
    [_videoWriter cancelWriting];
  }
  
  [self finishWriter:_videoWriter
          videoInput:_videoWriterInput
          audioInput:_audioWriterInput
             endTime:endTime
                path:_currentPath
               index:_segmentIndex
        startEpochMs:_segmentStartEpochMs
          durationMs:durationMs
             isFinal:YES
              reason:reason
               error:errorDescription
           recording:recording];
  
  _videoWriter = nil;
  _videoWriterInput = nil;
  _videoAdaptor = nil;
  _audioWriterInput = nil;
  _hasAppendedVideo = NO;
}

/// The current writer failed: end the recording. Must run on the sample queue.
- (void)failSegmentedRecording:(nullable NSError *)error {
  CASegmentedRecording *recording = _segmented;
  if (recording == nil) {
    return;
  }
  NSLog(@"camerawesome: segmented recording failed: %@", error);
  [self endSegmentedRecording:recording reason:@"error" error:error.localizedDescription ?: @"writer failed"];
  [self notifyWhenFinished:recording completion:nil];
}

- (void)segmentedCaptureOutput:(AVCaptureOutput *)output sampleBuffer:(CMSampleBufferRef)sampleBuffer isVideo:(BOOL)isVideo {
  if (!_isRecording || _segmented == nil) {
    return;
  }
  
  CMTime rawTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  if (!CMTIME_IS_NUMERIC(rawTime)) {
    return;
  }
  
  if (isVideo) {
    if (_videoIsDisconnected) {
      // Unlike the single-file path, the gap is NOT compensated: it starts a
      // new segment instead (and audio, which is not compensated either,
      // stays in sync).
      _videoIsDisconnected = NO;
      return;
    }
    _lastVideoSampleTime = rawTime;
    CMTime time = CMTimeSubtract(rawTime, _videoTimeOffset);
    
    if (_videoWriter.status == AVAssetWriterStatusUnknown) {
      if (![_videoWriter startWriting]) {
        [self failSegmentedRecording:_videoWriter.error];
        return;
      }
      [_videoWriter startSessionAtSourceTime:time];
      _segmentStartPTS = time;
      _segmentStartEpochMs = [self epochMsForSampleTime:rawTime];
    } else if (_videoWriter.status == AVAssetWriterStatusWriting && _hasAppendedVideo) {
      double elapsedMs = CMTimeGetSeconds(CMTimeSubtract(time, _segmentStartPTS)) * 1000.0;
      double gapSeconds = CMTimeGetSeconds(CMTimeSubtract(time, _lastAppendedVideoPTS));
      if (_nextWriter == nil && elapsedMs >= _segmentDurationMs - kPrepareNextWriterAheadMs) {
        [self prepareNextWriterAtTime:time];
      }
      if (elapsedMs >= _segmentDurationMs || gapSeconds > kMaxFrameGapSeconds) {
        [self rolloverAtTime:time rawTime:rawTime gapSeconds:gapSeconds];
        if (_segmented == nil) {
          return;
        }
      }
    }
    
    if (_videoWriter.status != AVAssetWriterStatusWriting) {
      if (_videoWriter.status == AVAssetWriterStatusFailed) {
        [self failSegmentedRecording:_videoWriter.error];
      }
      return;
    }
    if (!_videoWriterInput.readyForMoreMediaData) {
      // The encoder is behind: drop this frame rather than blocking.
      return;
    }
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if ([_videoAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:time]) {
      _lastAppendedVideoPTS = time;
      _hasAppendedVideo = YES;
    } else if (_videoWriter.status == AVAssetWriterStatusFailed) {
      [self failSegmentedRecording:_videoWriter.error];
    }
    return;
  }
  
  // Audio: appended to the current segment once its session has started.
  // Samples earlier than a segment start are trimmed by AVAssetWriter.
  if (_audioWriterInput == nil || !_hasAppendedVideo || _videoWriter.status != AVAssetWriterStatusWriting) {
    return;
  }
  CMTime audioTime = rawTime;
  CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
  if (duration.value > 0) {
    audioTime = CMTimeAdd(audioTime, duration);
  }
  if (_audioIsDisconnected) {
    _audioIsDisconnected = NO;
    if (CMTIME_IS_NUMERIC(_lastAudioSampleTime)) {
      CMTime offset = CMTimeSubtract(audioTime, _lastAudioSampleTime);
      _audioTimeOffset = _audioTimeOffset.value == 0 ? offset : CMTimeAdd(_audioTimeOffset, offset);
    }
    return;
  }
  _lastAudioSampleTime = audioTime;
  if (!_audioWriterInput.readyForMoreMediaData) {
    return;
  }
  if (_audioTimeOffset.value != 0) {
    CMSampleBufferRef adjusted = [self adjustTime:sampleBuffer by:_audioTimeOffset];
    if (adjusted != NULL) {
      [_audioWriterInput appendSampleBuffer:adjusted];
      CFRelease(adjusted);
    }
  } else {
    [_audioWriterInput appendSampleBuffer:sampleBuffer];
  }
}

/// Creates and starts the writer of the next segment ahead of the boundary.
- (void)prepareNextWriterAtTime:(CMTime)time {
  if (_nextWriter != nil) {
    return;
  }
  if (CMTIME_IS_NUMERIC(_nextWriterRetryPTS) &&
      CMTimeGetSeconds(CMTimeSubtract(time, _nextWriterRetryPTS)) < kNextWriterRetrySeconds) {
    return;
  }
  _nextWriterRetryPTS = time;
  
  NSString *path = [self pathForSegmentIndex:_segmentIndex + 1];
  [self removeFileAtPath:path];
  AVAssetWriter *writer = nil;
  AVAssetWriterInput *videoInput = nil;
  AVAssetWriterInputPixelBufferAdaptor *adaptor = nil;
  AVAssetWriterInput *audioInput = nil;
  NSError *error = nil;
  if (![self makeWriterForPath:path writer:&writer videoInput:&videoInput adaptor:&adaptor audioInput:&audioInput error:&error]) {
    NSLog(@"camerawesome: could not create the next segment writer: %@", error);
    return;
  }
  if (![writer startWriting]) {
    NSLog(@"camerawesome: could not start the next segment writer: %@", writer.error);
    [self removeFileAtPath:path];
    return;
  }
  _nextWriter = writer;
  _nextVideoInput = videoInput;
  _nextAdaptor = adaptor;
  _nextAudioInput = audioInput;
  _nextPath = path;
}

- (void)discardNextWriter {
  if (_nextWriter == nil) {
    return;
  }
  if (_nextWriter.status == AVAssetWriterStatusWriting) {
    [_nextWriter cancelWriting];
  }
  [self removeFileAtPath:_nextPath];
  _nextWriter = nil;
  _nextVideoInput = nil;
  _nextAdaptor = nil;
  _nextAudioInput = nil;
  _nextPath = nil;
}

/// Switches to the next segment. The frame at [time] is the first frame of
/// the new file, so no frame is lost between two files.
- (void)rolloverAtTime:(CMTime)time rawTime:(CMTime)rawTime gapSeconds:(double)gapSeconds {
  if (_nextWriter == nil) {
    [self prepareNextWriterAtTime:time];
  }
  if (_nextWriter == nil) {
    // Keep writing into the current file and retry on a later frame.
    return;
  }
  if (_nextWriter.status != AVAssetWriterStatusWriting) {
    // It failed while waiting (background, media services reset): calling
    // startSessionAtSourceTime: on it would raise.
    NSLog(@"camerawesome: prepared segment writer is unusable: %@", _nextWriter.error);
    [self discardNextWriter];
    return;
  }
  
  CASegmentedRecording *recording = _segmented;
  AVAssetWriter *previousWriter = _videoWriter;
  AVAssetWriterInput *previousVideoInput = _videoWriterInput;
  AVAssetWriterInput *previousAudioInput = _audioWriterInput;
  NSString *previousPath = _currentPath;
  NSInteger previousIndex = _segmentIndex;
  int64_t previousStartEpochMs = _segmentStartEpochMs;
  // After an interruption, end the previous file on its last frame instead of
  // stretching that frame over the whole pause.
  CMTime endTime = gapSeconds > kMaxFrameGapSeconds
    ? CMTimeAdd(_lastAppendedVideoPTS, _nominalFrameDuration)
    : time;
  int64_t durationMs = [self millisecondsFrom:_segmentStartPTS to:endTime];
  
  _videoWriter = _nextWriter;
  _videoWriterInput = _nextVideoInput;
  _videoAdaptor = _nextAdaptor;
  _audioWriterInput = _nextAudioInput;
  _currentPath = _nextPath;
  _segmentIndex = previousIndex + 1;
  _nextWriter = nil;
  _nextVideoInput = nil;
  _nextAdaptor = nil;
  _nextAudioInput = nil;
  _nextPath = nil;
  _nextWriterRetryPTS = kCMTimeInvalid;
  
  [_videoWriter startSessionAtSourceTime:time];
  _segmentStartPTS = time;
  _segmentStartEpochMs = [self epochMsForSampleTime:rawTime];
  _hasAppendedVideo = NO;
  
  [self finishWriter:previousWriter
          videoInput:previousVideoInput
          audioInput:previousAudioInput
             endTime:endTime
                path:previousPath
               index:previousIndex
        startEpochMs:previousStartEpochMs
          durationMs:durationMs
             isFinal:NO
              reason:@"rollover"
               error:nil
           recording:recording];
}

/// Finalizes one segment file and reports it. Final segments are reported by
/// notifyWhenFinished:completion:, after every other segment.
- (void)finishWriter:(nullable AVAssetWriter *)writer
          videoInput:(nullable AVAssetWriterInput *)videoInput
          audioInput:(nullable AVAssetWriterInput *)audioInput
             endTime:(CMTime)endTime
                path:(NSString *)path
               index:(NSInteger)index
        startEpochMs:(int64_t)startEpochMs
          durationMs:(int64_t)durationMs
             isFinal:(BOOL)isFinal
              reason:(NSString *)reason
               error:(nullable NSString *)errorDescription
           recording:(CASegmentedRecording *)recording {
  NSString *recordingId = recording.recordingId;
  int64_t fallbackEpochMs = startEpochMs > 0 ? startEpochMs : [self nowEpochMs];
  NSDictionary *(^makeEvent)(BOOL, int64_t, NSString *) = ^NSDictionary *(BOOL usable, int64_t bytes, NSString *error) {
    return @{
      @"type": @"segment",
      @"recordingId": recordingId ?: @"",
      @"sensorIndex": @0,
      @"index": @(index),
      @"path": path ?: @"",
      @"startedAtEpochMs": @(fallbackEpochMs),
      @"durationMs": @(usable ? durationMs : 0),
      @"bytes": @(bytes),
      @"usable": @(usable),
      @"isFinal": @(isFinal),
      @"reason": reason,
      @"error": error ?: [NSNull null],
    };
  };
  
  if (writer == nil || writer.status != AVAssetWriterStatusWriting || !CMTIME_IS_NUMERIC(endTime)) {
    // Never started, cancelled or failed: there is no playable file.
    if (writer.status == AVAssetWriterStatusWriting) {
      [writer cancelWriting];
    }
    [self removeFileAtPath:path];
    NSString *error = errorDescription ?: writer.error.localizedDescription ?: @"no video frames";
    [self deliverEvent:makeEvent(NO, 0, error) usable:NO isFinal:isFinal recording:recording];
    return;
  }
  
  [writer endSessionAtSourceTime:endTime];
  [videoInput markAsFinished];
  [audioInput markAsFinished];
  dispatch_group_enter(recording.finishGroup);
  [writer finishWritingWithCompletionHandler:^{
    BOOL usable = writer.status == AVAssetWriterStatusCompleted;
    int64_t bytes = usable ? [self fileSizeAtPath:path] : 0;
    if (bytes <= 0) {
      usable = NO;
      bytes = 0;
    }
    if (!usable) {
      [self removeFileAtPath:path];
    }
    NSString *error = usable
      ? errorDescription
      : (errorDescription ?: writer.error.localizedDescription ?: @"could not finish writing");
    [self deliverEvent:makeEvent(usable, bytes, error) usable:usable isFinal:isFinal recording:recording];
    dispatch_group_leave(recording.finishGroup);
  }];
}

- (void)deliverEvent:(NSDictionary *)event usable:(BOOL)usable isFinal:(BOOL)isFinal recording:(CASegmentedRecording *)recording {
  dispatch_async(_eventQueue, ^{
    if (usable) {
      recording.anyUsable = YES;
    }
    if (isFinal) {
      recording.finalEvent = event;
    } else {
      [self sendEvent:event];
    }
  });
}

- (void)sendEvent:(NSDictionary *)event {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.onSegmentEvent != nil) {
      self.onSegmentEvent(event);
    }
  });
}

/// Once every segment of [recording] is finalized, sends the final segment
/// event (once) and then calls [completion] with whether any file is usable.
- (void)notifyWhenFinished:(CASegmentedRecording *)recording completion:(nullable void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  dispatch_group_notify(recording.finishGroup, _eventQueue, ^{
    NSDictionary *finalEvent = recording.finalEventSent ? nil : recording.finalEvent;
    if (finalEvent != nil) {
      recording.finalEventSent = YES;
    }
    BOOL anyUsable = recording.anyUsable;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (finalEvent != nil && self.onSegmentEvent != nil) {
        self.onSegmentEvent(finalEvent);
      }
      if (completion != nil) {
        completion(@(anyUsable), nil);
      }
    });
  });
}

- (NSString *)pathForSegmentIndex:(NSInteger)index {
  NSString *base = _segmented.recordingId ?: _currentPath;
  if (index == 0) {
    return base;
  }
  NSString *extension = base.pathExtension.length > 0 ? base.pathExtension : @"mp4";
  NSString *stem = [base stringByDeletingPathExtension];
  return [NSString stringWithFormat:@"%@_%03ld.%@", stem, (long)index, extension];
}

- (CMTime)nominalFrameDuration {
  if (_options && _options.fps != nil && _options.fps.intValue > 0) {
    return CMTimeMake(1, _options.fps.intValue);
  }
  if (_captureDevice != nil) {
    CMTime frameDuration = _captureDevice.activeVideoMinFrameDuration;
    if (CMTIME_IS_NUMERIC(frameDuration) && CMTimeGetSeconds(frameDuration) > 0) {
      return frameDuration;
    }
  }
  return CMTimeMake(1, 30);
}

- (int64_t)millisecondsFrom:(CMTime)start to:(CMTime)end {
  if (!CMTIME_IS_NUMERIC(start) || !CMTIME_IS_NUMERIC(end)) {
    return 0;
  }
  double seconds = CMTimeGetSeconds(CMTimeSubtract(end, start));
  return seconds > 0 ? (int64_t)llround(seconds * 1000.0) : 0;
}

- (int64_t)nowEpochMs {
  return (int64_t)llround([[NSDate date] timeIntervalSince1970] * 1000.0);
}

/// Converts a capture timestamp (session clock) to wall-clock milliseconds.
- (int64_t)epochMsForSampleTime:(CMTime)sampleTime {
  int64_t nowMs = [self nowEpochMs];
  if (_clockTimeProvider == nil) {
    return nowMs;
  }
  CMTime clockNow = _clockTimeProvider();
  if (!CMTIME_IS_NUMERIC(clockNow)) {
    return nowMs;
  }
  double ageSeconds = CMTimeGetSeconds(CMTimeSubtract(clockNow, sampleTime));
  if (!isfinite(ageSeconds) || ageSeconds < 0 || ageSeconds > 10) {
    return nowMs;
  }
  return nowMs - (int64_t)llround(ageSeconds * 1000.0);
}

- (int64_t)fileSizeAtPath:(NSString *)path {
  if (path == nil) {
    return 0;
  }
  NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  return attributes != nil ? (int64_t)[attributes fileSize] : 0;
}

- (void)removeFileAtPath:(nullable NSString *)path {
  if (path == nil) {
    return;
  }
  NSFileManager *fileManager = [NSFileManager defaultManager];
  if ([fileManager fileExistsAtPath:path]) {
    [fileManager removeItemAtPath:path error:nil];
  }
}

# pragma mark - Audio & Video writers

/// Setup video channel & write file on path
- (BOOL)setupWriterForPath:(NSString *)path audioSetupCallback:(OnAudioSetup)audioSetupCallback options:(CupertinoVideoOptions *)options completion:(nonnull void (^)(FlutterError * _Nullable))completion {
  if (path == nil) {
    completion([FlutterError errorWithCode:@"VIDEO_ERROR" message:@"impossible to write video at path" details:@""]);
    return NO;
  }
  if (_isAudioEnabled && !_isAudioSetup) {
    audioSetupCallback();
  }
  
  AVAssetWriter *writer = nil;
  AVAssetWriterInput *videoInput = nil;
  AVAssetWriterInputPixelBufferAdaptor *adaptor = nil;
  AVAssetWriterInput *audioInput = nil;
  NSError *error = nil;
  if (![self makeWriterForPath:path writer:&writer videoInput:&videoInput adaptor:&adaptor audioInput:&audioInput error:&error]) {
    completion([FlutterError errorWithCode:@"VIDEO_ERROR" message:@"impossible to create video writer, check your options" details:error.description ?: path]);
    return NO;
  }
  _videoWriter = writer;
  _videoWriterInput = videoInput;
  _videoAdaptor = adaptor;
  _audioWriterInput = audioInput;
  
  return YES;
}

/// Creates a writer (not started) with the video and, if enabled, audio inputs.
- (BOOL)makeWriterForPath:(NSString *)path
                   writer:(AVAssetWriter * _Nullable __autoreleasing *)outWriter
               videoInput:(AVAssetWriterInput * _Nullable __autoreleasing *)outVideoInput
                  adaptor:(AVAssetWriterInputPixelBufferAdaptor * _Nullable __autoreleasing *)outAdaptor
               audioInput:(AVAssetWriterInput * _Nullable __autoreleasing *)outAudioInput
                    error:(NSError * _Nullable __autoreleasing *)outError {
  NSURL *outputURL = [NSURL fileURLWithPath:path];
  
  // Read from options if available
  AVVideoCodecType codecType = [self getBestCodecTypeAccordingOptions:_options];
  AVFileType fileType = [self getBestFileTypeAccordingOptions:_options];
  CGSize videoSize = [self getBestVideoSizeAccordingQuality: _recordingQuality];
  
  NSMutableDictionary *videoSettings = [@{
    AVVideoCodecKey   : codecType,
    AVVideoWidthKey   : @(videoSize.height),
    AVVideoHeightKey  : @(videoSize.width),
  } mutableCopy];
  NSNumber *bitrate = (_options && _options != (id)[NSNull null]) ? _options.bitrate : nil;
  if (bitrate != nil && bitrate.longLongValue > 0 &&
      ([codecType isEqualToString:AVVideoCodecTypeH264] || [codecType isEqualToString:AVVideoCodecTypeHEVC])) {
    videoSettings[AVVideoCompressionPropertiesKey] = @{ AVVideoAverageBitRateKey: bitrate };
  }
  
  NSError *error = nil;
  AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:outputURL fileType:fileType error:&error];
  if (writer == nil || error != nil) {
    if (outError != NULL) {
      *outError = error;
    }
    return NO;
  }
  
  AVAssetWriterInput *videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
  [videoInput setTransform:[self getVideoOrientation]];
  videoInput.expectsMediaDataInRealTime = YES;
  AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
                                                   assetWriterInputPixelBufferAdaptorWithAssetWriterInput:videoInput
                                                   sourcePixelBufferAttributes:@{
    (NSString *)kCVPixelBufferPixelFormatTypeKey: @(videoFormat)
  }];
  if (![writer canAddInput:videoInput]) {
    if (outError != NULL) {
      *outError = [NSError errorWithDomain:@"camerawesome" code:1 userInfo:@{NSLocalizedDescriptionKey: @"cannot add video input"}];
    }
    return NO;
  }
  [writer addInput:videoInput];
  
  AVAssetWriterInput *audioInput = nil;
  if (_isAudioEnabled) {
    AudioChannelLayout acl;
    bzero(&acl, sizeof(acl));
    acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    NSDictionary *audioOutputSettings = [NSDictionary
                                         dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:kAudioFormatMPEG4AAC], AVFormatIDKey,
                                         [NSNumber numberWithFloat:44100.0], AVSampleRateKey,
                                         [NSNumber numberWithInt:1], AVNumberOfChannelsKey,
                                         [NSData dataWithBytes:&acl length:sizeof(acl)],
                                         AVChannelLayoutKey, nil];
    audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                    outputSettings:audioOutputSettings];
    audioInput.expectsMediaDataInRealTime = YES;
    if ([writer canAddInput:audioInput]) {
      [writer addInput:audioInput];
    } else {
      audioInput = nil;
    }
  }
  
  *outWriter = writer;
  *outVideoInput = videoInput;
  *outAdaptor = adaptor;
  *outAudioInput = audioInput;
  return YES;
}

- (CGAffineTransform)getVideoOrientation {
  CGAffineTransform transform;
  
  switch (_orientation) {
    case UIDeviceOrientationLandscapeLeft:
      transform = CGAffineTransformMakeRotation(M_PI_2);
      break;
    case UIDeviceOrientationLandscapeRight:
      transform = CGAffineTransformMakeRotation(-M_PI_2);
      break;
    case UIDeviceOrientationPortraitUpsideDown:
      transform = CGAffineTransformMakeRotation(M_PI);
      break;
    default:
      transform = CGAffineTransformIdentity;
      break;
  }
  
  return transform;
}

/// Append audio data
- (void)newAudioSample:(CMSampleBufferRef)sampleBuffer {
  if (_videoWriter.status != AVAssetWriterStatusWriting) {
    if (_videoWriter.status == AVAssetWriterStatusFailed) {
      //      *error = [FlutterError errorWithCode:@"VIDEO_ERROR" message:@"writing video failed" details:_videoWriter.error];
    }
    return;
  }
  if (_audioWriterInput.readyForMoreMediaData) {
    if (![_audioWriterInput appendSampleBuffer:sampleBuffer]) {
      //      *error = [FlutterError errorWithCode:@"VIDEO_ERROR" message:@"adding audio channel failed" details:_videoWriter.error];
    }
  }
}

/// Adjust time to sync audio & video
- (CMSampleBufferRef)adjustTime:(CMSampleBufferRef)sample by:(CMTime)offset CF_RETURNS_RETAINED {
  CMItemCount count;
  CMSampleBufferGetSampleTimingInfoArray(sample, 0, nil, &count);
  CMSampleTimingInfo *pInfo = malloc(sizeof(CMSampleTimingInfo) * count);
  CMSampleBufferGetSampleTimingInfoArray(sample, count, pInfo, &count);
  for (CMItemCount i = 0; i < count; i++) {
    pInfo[i].decodeTimeStamp = CMTimeSubtract(pInfo[i].decodeTimeStamp, offset);
    pInfo[i].presentationTimeStamp = CMTimeSubtract(pInfo[i].presentationTimeStamp, offset);
  }
  CMSampleBufferRef sout;
  CMSampleBufferCreateCopyWithNewTiming(nil, sample, count, pInfo, &sout);
  free(pInfo);
  return sout;
}

/// Adjust video preview & recording to specified FPS
- (void)adjustCameraFPS:(NSNumber *)fps {
  NSArray *frameRateRanges = _captureDevice.activeFormat.videoSupportedFrameRateRanges;
  
  if (frameRateRanges.count > 0) {
    AVFrameRateRange *frameRateRange = frameRateRanges.firstObject;
    NSError *error = nil;
    
    if ([_captureDevice lockForConfiguration:&error]) {
      CMTime frameDuration = CMTimeMake(1, [fps intValue]);
      if (CMTIME_COMPARE_INLINE(frameDuration, <=, frameRateRange.maxFrameDuration) && CMTIME_COMPARE_INLINE(frameDuration, >=, frameRateRange.minFrameDuration)) {
        _captureDevice.activeVideoMinFrameDuration = frameDuration;
      }
      [_captureDevice unlockForConfiguration];
    }
  }
}

# pragma mark - Camera Delegates
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection captureVideoOutput:(AVCaptureVideoDataOutput *)captureVideoOutput {
  if (_segmented != nil) {
    [self segmentedCaptureOutput:output sampleBuffer:sampleBuffer isVideo:(captureVideoOutput != nil && output == captureVideoOutput)];
    return;
  }
  
  if (self.isPaused) {
    return;
  }
  
  if (_videoWriter.status == AVAssetWriterStatusFailed) {
    //    _result([FlutterError errorWithCode:@"VIDEO_ERROR" message:@"impossible to write video " details:_videoWriter.error]);
    return;
  }
  
  CFRetain(sampleBuffer);
  CMTime currentSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  
  if (_videoWriter.status != AVAssetWriterStatusWriting) {
    [_videoWriter startWriting];
    [_videoWriter startSessionAtSourceTime:currentSampleTime];
  }
  
  if (output == captureVideoOutput) {
    if (_videoIsDisconnected) {
      _videoIsDisconnected = NO;
      
      if (_videoTimeOffset.value == 0) {
        _videoTimeOffset = CMTimeSubtract(currentSampleTime, _lastVideoSampleTime);
      } else {
        CMTime offset = CMTimeSubtract(currentSampleTime, _lastVideoSampleTime);
        _videoTimeOffset = CMTimeAdd(_videoTimeOffset, offset);
      }
      
      CFRelease(sampleBuffer);
      return;
    }
    
    _lastVideoSampleTime = currentSampleTime;
    
    CVPixelBufferRef nextBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CMTime nextSampleTime = CMTimeSubtract(_lastVideoSampleTime, _videoTimeOffset);
    [_videoAdaptor appendPixelBuffer:nextBuffer withPresentationTime:nextSampleTime];
  } else {
    CMTime dur = CMSampleBufferGetDuration(sampleBuffer);
    
    if (dur.value > 0) {
      currentSampleTime = CMTimeAdd(currentSampleTime, dur);
    }
    if (_audioIsDisconnected) {
      _audioIsDisconnected = NO;
      
      if (_audioTimeOffset.value == 0) {
        _audioTimeOffset = CMTimeSubtract(currentSampleTime, _lastAudioSampleTime);
      } else {
        CMTime offset = CMTimeSubtract(currentSampleTime, _lastAudioSampleTime);
        _audioTimeOffset = CMTimeAdd(_audioTimeOffset, offset);
      }
      
      CFRelease(sampleBuffer);
      return;
    }
    
    _lastAudioSampleTime = currentSampleTime;
    
    if (_audioTimeOffset.value != 0) {
      CFRelease(sampleBuffer);
      sampleBuffer = [self adjustTime:sampleBuffer by:_audioTimeOffset];
    }
    
    [self newAudioSample:sampleBuffer];
  }
  
  CFRelease(sampleBuffer);
}

# pragma mark - Settings converters

- (AVFileType)getBestFileTypeAccordingOptions:(CupertinoVideoOptions *)options {
  AVFileType fileType = AVFileTypeQuickTimeMovie;
  
  if (options && options != (id)[NSNull null]) {
    CupertinoFileType type = options.fileType;
    switch (type) {
      case CupertinoFileTypeQuickTimeMovie:
        fileType = AVFileTypeQuickTimeMovie;
        break;
      case CupertinoFileTypeMpeg4:
        fileType = AVFileTypeMPEG4;
        break;
      case CupertinoFileTypeAppleM4V:
        fileType = AVFileTypeAppleM4V;
        break;
      case CupertinoFileTypeType3GPP:
        fileType = AVFileType3GPP;
        break;
      case CupertinoFileTypeType3GPP2:
        fileType = AVFileType3GPP2;
        break;
      default:
        break;
    }
  }
  
  return fileType;
}

- (AVVideoCodecType)getBestCodecTypeAccordingOptions:(CupertinoVideoOptions *)options {
  AVVideoCodecType codecType = AVVideoCodecTypeH264;
  if (options && options != (id)[NSNull null]) {
    CupertinoCodecType codec = options.codec;
    switch (codec) {
      case CupertinoCodecTypeH264:
        codecType = AVVideoCodecTypeH264;
        break;
      case CupertinoCodecTypeHevc:
        codecType = AVVideoCodecTypeHEVC;
        break;
      case CupertinoCodecTypeHevcWithAlpha:
        codecType = AVVideoCodecTypeHEVCWithAlpha;
        break;
      case CupertinoCodecTypeJpeg:
        codecType = AVVideoCodecTypeJPEG;
        break;
      case CupertinoCodecTypeAppleProRes4444:
        codecType = AVVideoCodecTypeAppleProRes4444;
        break;
      case CupertinoCodecTypeAppleProRes422:
        codecType = AVVideoCodecTypeAppleProRes422;
        break;
      case CupertinoCodecTypeAppleProRes422HQ:
        codecType = AVVideoCodecTypeAppleProRes422HQ;
        break;
      case CupertinoCodecTypeAppleProRes422LT:
        codecType = AVVideoCodecTypeAppleProRes422LT;
        break;
      case CupertinoCodecTypeAppleProRes422Proxy:
        codecType = AVVideoCodecTypeAppleProRes422Proxy;
        break;
      default:
        break;
    }
  }
  return codecType;
}

- (CGSize)getBestVideoSizeAccordingQuality:(VideoRecordingQuality)quality {
  CGSize size;
  switch (quality) {
    case VideoRecordingQualityUhd:
    case VideoRecordingQualityHighest:
      if (@available(iOS 9.0, *)) {
        if ([_captureDevice supportsAVCaptureSessionPreset:AVCaptureSessionPreset3840x2160]) {
          size = CGSizeMake(3840, 2160);
        } else {
          size = CGSizeMake(1920, 1080);
        }
      } else {
        return CGSizeMake(1920, 1080);
      }
      break;
    case VideoRecordingQualityFhd:
      size = CGSizeMake(1920, 1080);
      break;
    case VideoRecordingQualityHd:
      size = CGSizeMake(1280, 720);
      break;
    case VideoRecordingQualitySd:
    case VideoRecordingQualityLowest:
      size = CGSizeMake(960, 540);
      break;
  }
    
  // ensure video output size does not exceed capture session size
  if (size.width > _previewSize.width) {
    size = _previewSize;
  }
  
  return size;
}

# pragma mark - Setter
- (void)setIsAudioEnabled:(bool)isAudioEnabled {
  _isAudioEnabled = isAudioEnabled;
}
- (void)setIsAudioSetup:(bool)isAudioSetup {
  _isAudioSetup = isAudioSetup;
}

- (void)setPreviewSize:(CGSize)previewSize {
  _previewSize = previewSize;
}

- (void)setVideoIsDisconnected:(bool)videoIsDisconnected {
  _videoIsDisconnected = videoIsDisconnected;
}

- (void)setAudioIsDisconnected:(bool)audioIsDisconnected {
  _audioIsDisconnected = audioIsDisconnected;
}

/// Update capture device reference and re-apply FPS if recording with custom FPS
/// This should be called after switching cameras during recording to ensure
/// the new camera device uses the same FPS as the original recording settings.
- (void)updateCaptureDevice:(AVCaptureDevice *)device {
  _captureDevice = device;

  // Re-apply custom FPS if recording is in progress and custom FPS was specified
  if (_isRecording && _options && _options.fps != nil && _options.fps.intValue > 0) {
    [self adjustCameraFPS:_options.fps];
  }
}

@end
