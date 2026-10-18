#import "CFPlatformBridge.h"
#import "CFNativeProtocol.h"
#import "CFReminderService.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <math.h>

@interface CFPlatformBridge () <AVSpeechSynthesizerDelegate, IMethodResult>
@property(nonatomic, strong) NSMutableSet<NSString *> *pendingReplies;
@property(nonatomic, strong) SFSpeechRecognizer *recognizer;
@property(nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *recognitionRequest;
@property(nonatomic, strong) SFSpeechRecognitionTask *recognitionTask;
@property(nonatomic, strong) AVAudioEngine *audioEngine;
@property(nonatomic, copy) NSString *recognitionID;
@property(nonatomic, copy) NSString *recognitionStartRequest;
@property(nonatomic) NSUInteger recognitionEpoch;
@property(nonatomic) BOOL tapInstalled;
@property(nonatomic) BOOL finishing;
@property(nonatomic, strong) AVSpeechSynthesizer *synthesizer;
@property(nonatomic, strong) AVSpeechUtterance *utterance;
@property(nonatomic, copy) NSArray<NSString *> *speechChunks;
@property(nonatomic, copy) NSString *speechID;
@property(nonatomic) NSUInteger speechIndex;
@property(nonatomic) BOOL speechStarted;
@end

@implementation CFPlatformBridge
- (instancetype)initWithManager:(BridgePluginManager *)manager {
    // Official ArkUI-X API 11 initializer; no instanceId or API 22-only overload.
    self = [super initBridgePlugin:@"CampusFlowPlatform" bridgeManager:manager bridgeType:JSON_TYPE];
    if (self) {
        _pendingReplies = [NSMutableSet set];
        self.methodResult = self;
        _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];
        _recognizer.queue = NSOperationQueue.mainQueue;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:)
            name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(interrupted:)
            name:AVAudioSessionInterruptionNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(audioReset:)
            name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    }
    return self;
}

- (NSString *)dispatch:(NSString *)commandJSON {
    NSDictionary *command = CFNativeCommand(commandJSON, NSDate.date.timeIntervalSince1970 * 1000);
    if (!command) {
        // Malformed JSON has no usable reply correlation. Valid IDs still receive one safe failure.
        if ([commandJSON isKindOfClass:NSString.class] && commandJSON.length <= 100000) {
            NSData *data = [commandJSON dataUsingEncoding:NSUTF8StringEncoding];
            id raw = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([raw isKindOfClass:NSDictionary.class] && CFNativeIdentifier(raw[@"request_id"], 128)) {
                NSString *requestID = raw[@"request_id"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([self.pendingReplies containsObject:requestID]) return;
                    [self.pendingReplies addObject:requestID];
                    [self reply:requestID ok:NO code:@"INVALID_REQUEST" result:nil];
                });
            }
        }
        return @"rejected";
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *requestID = command[@"request_id"];
        // A duplicate transport ID cannot execute a second mutation or complete a newer command.
        if ([self.pendingReplies containsObject:requestID]) return;
        [self.pendingReplies addObject:requestID];
        NSString *op = command[@"op"];
        if ([op isEqualToString:@"clock.sample"]) {
            // Only interval differences leave the device. The raw uptime stays in local checkpoints.
            [self reply:requestID ok:YES code:@"" result:@{
                @"wall_ms": @(floor(NSDate.date.timeIntervalSince1970 * 1000.0)),
                @"monotonic_ms": @(floor(NSProcessInfo.processInfo.systemUptime * 1000.0))
            }];
            return;
        }
        if ([op hasPrefix:@"reminders."]) {
            [[CFReminderService sharedService] handle:command completion:^(BOOL ok, NSString *code, NSDictionary *result) {
                [self reply:requestID ok:ok code:code result:result];
            }];
            return;
        }
        NSTimeInterval timeout = [op isEqualToString:@"recognition.start"] ? 55 : 12;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (![self.pendingReplies containsObject:requestID]) return;
            if ([self.recognitionStartRequest isEqualToString:requestID]) [self cancelRecognition:@"SYSTEM_ERROR"];
            [self reply:requestID ok:NO code:@"SYSTEM_ERROR" result:nil];
        });
        [self handleVoice:command];
    });
    return @"accepted";
}

- (void)emit:(NSDictionary *)event {
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!data) return;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    MethodData *method = [[MethodData alloc] initMethodWithName:@"onEvent" parameter:@[json]];
    [self callMethod:method];
}

- (void)reply:(NSString *)requestID ok:(BOOL)ok code:(NSString *)code result:(NSDictionary *)result {
    if (![self.pendingReplies containsObject:requestID]) return;
    [self.pendingReplies removeObject:requestID];
    NSMutableDictionary *event = [@{@"v": @1, @"kind": @"reply", @"request_id": requestID,
        @"ok": @(ok), @"code": code} mutableCopy];
    if (result) event[@"result"] = result;
    [self emit:event];
}

- (void)voice:(NSString *)event operation:(NSString *)operation text:(NSString *)text code:(NSString *)code {
    if (!operation) return;
    NSMutableDictionary *value = [@{@"v": @1, @"kind": @"voice", @"operation_id": operation, @"event": event} mutableCopy];
    if (text) value[@"text"] = text;
    if (code) value[@"code"] = code;
    [self emit:value];
}

- (void)handleVoice:(NSDictionary *)command {
    NSString *op = command[@"op"];
    NSString *requestID = command[@"request_id"];
    NSString *operation = command[@"operation_id"];
    if ([op isEqualToString:@"capabilities"]) {
        BOOL recognition = self.recognizer != nil && self.recognizer.available &&
            SFSpeechRecognizer.authorizationStatus != SFSpeechRecognizerAuthorizationStatusDenied &&
            SFSpeechRecognizer.authorizationStatus != SFSpeechRecognizerAuthorizationStatusRestricted &&
            AVAudioSession.sharedInstance.recordPermission != AVAudioSessionRecordPermissionDenied;
        [self reply:requestID ok:YES code:@"OK" result:@{@"recognition": @(recognition),
            @"synthesis": @([AVSpeechSynthesisVoice voiceWithLanguage:@"zh-CN"] != nil), @"reminders": @YES}];
    } else if ([op isEqualToString:@"recognition.start"]) {
        [self startRecognition:operation request:requestID];
    } else if ([op isEqualToString:@"recognition.finish"]) {
        if (![operation isEqualToString:self.recognitionID]) {
            [self reply:requestID ok:NO code:@"OPERATION_CANCELLED" result:nil]; return;
        }
        if (!self.recognitionTask) [self cancelRecognition:@"OPERATION_CANCELLED"];
        else [self finishRecognition];
        [self reply:requestID ok:YES code:@"OK" result:@{}];
    } else if ([op isEqualToString:@"recognition.cancel"]) {
        if ([operation isEqualToString:self.recognitionID]) [self cancelRecognition:@"OPERATION_CANCELLED"];
        [self reply:requestID ok:YES code:@"OK" result:@{}];
    } else if ([op isEqualToString:@"speech.start"]) {
        [self startSpeech:command[@"text"] operation:operation request:requestID];
    } else if ([op isEqualToString:@"speech.stop"]) {
        // A tagged stale stop never stops a newer utterance. Untagged stop explicitly means all voice output.
        if (!operation || [operation isEqualToString:self.speechID]) [self stopSpeech:@"OPERATION_CANCELLED"];
        [self reply:requestID ok:YES code:@"OK" result:@{}];
    } else if ([op isEqualToString:@"voice.dispose"]) {
        [self cancelRecognition:@"OPERATION_CANCELLED"];
        [self stopSpeech:@"OPERATION_CANCELLED"];
        [self reply:requestID ok:YES code:@"OK" result:@{}];
    }
}

- (BOOL)recognitionCurrent:(NSString *)operation epoch:(NSUInteger)epoch {
    return epoch == self.recognitionEpoch && [operation isEqualToString:self.recognitionID];
}

- (void)startRecognition:(NSString *)operation request:(NSString *)requestID {
    [self cancelRecognition:@"OPERATION_CANCELLED"];
    [self stopSpeech:@"OPERATION_CANCELLED"];
    self.recognitionID = operation;
    self.recognitionStartRequest = requestID;
    NSUInteger epoch = ++self.recognitionEpoch;
    if (!self.recognizer || !self.recognizer.available ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self cancelRecognition:@"UNAVAILABLE"]; return;
    }
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self recognitionCurrent:operation epoch:epoch]) return;
            if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                [self cancelRecognition:@"PERMISSION_DENIED"]; return;
            }
            [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (![self recognitionCurrent:operation epoch:epoch]) return;
                    if (!granted) { [self cancelRecognition:@"PERMISSION_DENIED"]; return; }
                    [self beginRecording:operation epoch:epoch];
                });
            }];
        });
    }];
}

- (void)beginRecording:(NSString *)operation epoch:(NSUInteger)epoch {
    if (![self recognitionCurrent:operation epoch:epoch]) return;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground || !self.recognizer.available) {
        [self cancelRecognition:@"UNAVAILABLE"]; return;
    }
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryRecord mode:AVAudioSessionModeMeasurement
        options:0 error:&error] || ![session setActive:YES error:&error]) {
        [self cancelRecognition:@"SYSTEM_ERROR"]; return;
    }
    self.audioEngine = [AVAudioEngine new];
    AVAudioInputNode *input = self.audioEngine.inputNode;
    AVAudioFormat *format = [input outputFormatForBus:0];
    if (format.channelCount == 0 || format.sampleRate <= 0) { [self cancelRecognition:@"UNAVAILABLE"]; return; }
    self.recognitionRequest = [SFSpeechAudioBufferRecognitionRequest new];
    self.recognitionRequest.shouldReportPartialResults = YES;
    SFSpeechAudioBufferRecognitionRequest *audioRequest = self.recognitionRequest;
    // System audio buffers stay in memory and go only to Speech; never recorded to disk or our backend.
    [input installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        [audioRequest appendAudioPCMBuffer:buffer];
    }];
    self.tapInstalled = YES;
    __weak typeof(self) weakSelf = self;
    self.recognitionTask = [self.recognizer recognitionTaskWithRequest:audioRequest
        resultHandler:^(SFSpeechRecognitionResult *result, NSError *recognitionError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            CFPlatformBridge *strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf recognitionCurrent:operation epoch:epoch]) return;
            if (result) {
                NSString *text = result.bestTranscription.formattedString;
                if (text.length > 32000) { [strongSelf cancelRecognition:@"SYSTEM_ERROR"]; return; }
                [strongSelf voice:@"recognition_result" operation:operation text:text code:nil];
                if (result.isFinal) {
                    [strongSelf voice:@"recognition_complete" operation:operation text:nil code:nil];
                    [strongSelf releaseRecognition];
                    return;
                }
            }
            if (recognitionError) [strongSelf cancelRecognition:@"SYSTEM_ERROR"];
        });
    }];
    [self.audioEngine prepare];
    if (![self.audioEngine startAndReturnError:&error]) { [self cancelRecognition:@"SYSTEM_ERROR"]; return; }
    [self voice:@"recognition_start" operation:operation text:nil code:nil];
    [self reply:self.recognitionStartRequest ok:YES code:@"OK" result:@{}];
    self.recognitionStartRequest = nil;
    // Apple's service has duration limits; end audio and wait for a real final result.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 55 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([self recognitionCurrent:operation epoch:epoch]) [self finishRecognition];
    });
}

- (void)stopRecordingAudio {
    [self.audioEngine stop];
    if (self.tapInstalled) {
        [self.audioEngine.inputNode removeTapOnBus:0];
        self.tapInstalled = NO;
    }
    [self.recognitionRequest endAudio];
    [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}

- (void)finishRecognition {
    if (self.finishing) return;
    self.finishing = YES;
    NSString *operation = self.recognitionID;
    NSUInteger epoch = self.recognitionEpoch;
    [self stopRecordingAudio];
    // endAudio lets the recognizer finish naturally; cancellation never masquerades as completion.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([self recognitionCurrent:operation epoch:epoch]) [self cancelRecognition:@"SYSTEM_ERROR"];
    });
}

- (void)releaseRecognition {
    self.recognitionEpoch += 1;
    self.recognitionID = nil;
    self.recognitionStartRequest = nil;
    [self stopRecordingAudio];
    [self.recognitionTask cancel];
    self.recognitionTask = nil;
    self.recognitionRequest = nil;
    self.audioEngine = nil;
    self.finishing = NO;
}

- (void)cancelRecognition:(NSString *)code {
    NSString *operation = self.recognitionID;
    NSString *requestID = self.recognitionStartRequest;
    if (!operation) return;
    if (requestID) [self reply:requestID ok:NO code:code result:nil];
    else [self voice:@"recognition_error" operation:operation text:nil code:code];
    [self releaseRecognition];
}

- (NSArray<NSString *> *)chunksForText:(NSString *)text {
    NSMutableArray *chunks = [NSMutableArray array];
    NSMutableString *chunk = [NSMutableString string];
    NSCharacterSet *sentenceEnds = [NSCharacterSet characterSetWithCharactersInString:@"。！？!?\n"];
    // Preserve all composed characters and punctuation; cap each utterance without splitting emoji.
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
        options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(NSString *substring, NSRange range, NSRange enclosingRange, BOOL *stop) {
        [chunk appendString:substring];
        if ((chunk.length >= 500 || [substring rangeOfCharacterFromSet:sentenceEnds].location != NSNotFound) &&
            [chunk stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0) {
            [chunks addObject:[chunk copy]];
            [chunk setString:@""];
        }
    }];
    if (chunk.length) {
        if ([chunk stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0 && chunks.count)
            chunks[chunks.count - 1] = [chunks.lastObject stringByAppendingString:chunk];
        else [chunks addObject:[chunk copy]];
    }
    return chunks;
}

- (void)startSpeech:(NSString *)text operation:(NSString *)operation request:(NSString *)requestID {
    [self cancelRecognition:@"OPERATION_CANCELLED"];
    [self stopSpeech:@"OPERATION_CANCELLED"];
    AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"zh-CN"];
    if (!voice || UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
        [self reply:requestID ok:NO code:@"UNAVAILABLE" result:nil]; return;
    }
    NSError *error = nil;
    if (![AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback
        mode:AVAudioSessionModeSpokenAudio options:AVAudioSessionCategoryOptionDuckOthers error:&error] ||
        ![AVAudioSession.sharedInstance setActive:YES error:&error]) {
        [AVAudioSession.sharedInstance setActive:NO error:nil];
        [self reply:requestID ok:NO code:@"SYSTEM_ERROR" result:nil]; return;
    }
    self.speechID = operation;
    self.speechChunks = [self chunksForText:text];
    self.speechIndex = 0;
    self.speechStarted = NO;
    // A fresh synthesizer gives late delegates an object identity that cannot match the next run.
    self.synthesizer = [AVSpeechSynthesizer new];
    self.synthesizer.delegate = self;
    [self speakNext];
    [self reply:requestID ok:YES code:@"OK" result:@{}];
}

- (void)speakNext {
    if (!self.speechID || self.speechIndex >= self.speechChunks.count) return;
    self.utterance = [AVSpeechUtterance speechUtteranceWithString:self.speechChunks[self.speechIndex]];
    self.utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"zh-CN"];
    [self.synthesizer speakUtterance:self.utterance];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didStartSpeechUtterance:(AVSpeechUtterance *)utterance {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self speechSynthesizer:synthesizer didStartSpeechUtterance:utterance]; });
        return;
    }
    if (synthesizer != self.synthesizer || utterance != self.utterance || !self.speechID) return;
    if (!self.speechStarted) {
        self.speechStarted = YES;
        [self voice:@"speech_start" operation:self.speechID text:nil code:nil];
    }
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self speechSynthesizer:synthesizer didFinishSpeechUtterance:utterance]; });
        return;
    }
    if (synthesizer != self.synthesizer || utterance != self.utterance || !self.speechID) return;
    self.speechIndex += 1;
    if (self.speechIndex < self.speechChunks.count) { [self speakNext]; return; }
    [self voice:@"speech_complete" operation:self.speechID text:nil code:nil];
    [self releaseSpeech];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self speechSynthesizer:synthesizer didCancelSpeechUtterance:utterance]; });
        return;
    }
    if (synthesizer != self.synthesizer || utterance != self.utterance || !self.speechID) return;
    [self stopSpeech:@"OPERATION_CANCELLED"];
}

- (void)releaseSpeech {
    AVSpeechSynthesizer *old = self.synthesizer;
    self.speechID = nil;
    self.synthesizer = nil;
    self.utterance = nil;
    self.speechChunks = nil;
    old.delegate = nil;
    [old stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    if (!self.recognitionID) [AVAudioSession.sharedInstance setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}

- (void)stopSpeech:(NSString *)code {
    if (self.speechID) [self voice:@"speech_error" operation:self.speechID text:nil code:code];
    [self releaseSpeech];
}

- (void)stopVoiceForBackground {
    [self cancelRecognition:@"OPERATION_CANCELLED"];
    [self stopSpeech:@"OPERATION_CANCELLED"];
    // Reminder consent and scheduled notifications intentionally survive background / tab changes.
}
- (void)background:(NSNotification *)notification { [self stopVoiceForBackground]; }
- (void)interrupted:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan)
            [self stopVoiceForBackground];
    });
}
- (void)audioReset:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{ [self stopVoiceForBackground]; });
}

// Required official callMethod result delegate: diagnostics must not expose transcript or native errors.
- (void)onSuccess:(NSString *)methodName resultValue:(id)resultValue {}
- (void)onError:(NSString *)methodName errorCode:(ErrorCode)errorCode errorMessage:(NSString *)errorMessage {}
- (void)onMethodCancel:(NSString *)methodName {}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.methodResult = nil;
    [self.audioEngine stop];
    if (self.tapInstalled) [self.audioEngine.inputNode removeTapOnBus:0];
    [self.recognitionTask cancel];
    self.synthesizer.delegate = nil;
    [self.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
}
@end
