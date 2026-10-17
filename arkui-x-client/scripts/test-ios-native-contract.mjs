import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';

// Offline source/wiring contracts ONLY. These checks do not execute Objective-C,
// compile against an Apple/ArkUI-X SDK, grant permissions or prove device delivery.
const native = new URL('../.arkui-x/ios/', import.meta.url);
const read = (file) => readFileSync(new URL(file, native), 'utf8');
const bridge = read('app/CFPlatformBridge.m');
const reminders = read('app/CFReminderService.m');
const protocol = read('app/CFNativeProtocol.m');
const project = read('app.xcodeproj/project.pbxproj');
const controller = read('app/EntryEntryAbilityViewController.m');
const plist = read('app/Info.plist');

// Extract actual method text through the next Objective-C method, not duplicated JS logic.
function method(source, name) {
  const lines = source.split('\n');
  const start = lines.findIndex((line) => /^[+-] \(/.test(line) && line.includes(name));
  assert.notEqual(start, -1, `missing native method ${name}`);
  let end = start + 1;
  while (end < lines.length && !/^[+-] \(/.test(lines[end]) && lines[end] !== '@end') end++;
  return lines.slice(start, end).join('\n');
}
function ordered(source, ...pieces) {
  let offset = 0;
  for (const piece of pieces) {
    const found = source.indexOf(piece, offset);
    assert.notEqual(found, -1, `missing/out-of-order ${piece}`);
    offset = found + piece.length;
  }
}

test('iOS registers API 11 BridgeManager JSON channel before mounting the ArkUI view', () => {
  assert.match(bridge, /initBridgePlugin:@"CampusFlowPlatform" bridgeManager:manager bridgeType:JSON_TYPE/);
  assert.doesNotMatch(bridge, /initBridgePlugin:[^;]*instanceId:/);
  assert.match(controller, /initWithInstanceName[\s\S]*initWithManager:\[self getBridgeManager\]/);
  assert.match(bridge, /initMethodWithName:@"onEvent" parameter:@\[json\]/);
  assert.match(read('app/CFPlatformBridge.h'), /NSString \*\)dispatch:\(NSString \*\)commandJSON/);
});

test('wire rejects nonnumeric/boolean version, malformed IDs, unknown ops and oversized text before execution', () => {
  assert.match(protocol, /CFBooleanGetTypeID/);
  assert.match(protocol, /CFNativeNumber\(command\[@"v"\]\)/);
  assert.match(protocol, /doubleValue\] != 1/);
  assert.match(protocol, /CFNativeIdentifier\(command\[@"request_id"\], 128\)/);
  assert.match(protocol, /CFNativeIdentifier\(command\[@"operation_id"\], 128\)/);
  assert.match(protocol, /\[ops containsObject:op\]/);
  assert.match(protocol, /\[text length\] > 32000/);
  ordered(method(bridge, 'dispatch:'), 'CFNativeCommand(', 'dispatch_async(dispatch_get_main_queue()', '[self handleVoice:command]');
});

test('full reminder batch validates uniqueness, integral finite future bounds, scope and 60 cap', () => {
  for (const pattern of [/\[items count\] > 60/, /CFNativeIdentifier\(item\[@"id"\], 180\)/,
    /!isfinite\(value\)/, /floor\(value\) != value/, /value <= nowMS/, /366\.0 \* 24 \* 60 \* 60 \* 1000/,
    /\[ids containsObject:item\[@"id"\]\]/, /\[scope length\] > 512/, /controlCharacterSet/]) assert.match(protocol, pattern);
  assert.match(method(reminders, 'replace:'), /CFNativeReminderBatch\(job.command\[@"reminders"\], NSDate/);
});

test('replies are correlated and single terminal while native errors stay safe', () => {
  const reply = method(bridge, 'reply:');
  ordered(reply, 'containsObject:requestID', 'removeObject:requestID', '@"kind": @"reply"', '[self emit:event]');
  assert.match(method(reminders, 'reply:'), /if \(job.replied\) return/);
  assert.match(bridge, /@"INVALID_REQUEST"/);
  assert.doesNotMatch(bridge + reminders, /NSLog\(|localizedDescription|error\.userInfo|recognitionError\.description/);
});

test('capabilities/status probes never trigger OS permission prompts', () => {
  const capabilities = method(bridge, 'handleVoice:').split('else if')[0];
  assert.doesNotMatch(capabilities, /requestAuthorization|requestRecordPermission/);
  assert.match(capabilities, /recognizer.available/);
  assert.match(capabilities, /voiceWithLanguage:@"zh-CN"/);
  assert.doesNotMatch(method(reminders, 'status:'), /requestAuthorization/);
  assert.match(method(reminders, 'authorize:'), /requestAuthorizationWithOptions/);
});

test('permission grants are checked against operation+epoch before microphone startup', () => {
  const start = method(bridge, 'startRecognition:');
  ordered(start, 'requestAuthorization:', 'recognitionCurrent:operation epoch:epoch', 'requestRecordPermission:',
    'recognitionCurrent:operation epoch:epoch', '[self beginRecording:operation epoch:epoch]');
  assert.match(method(bridge, 'recognitionCurrent:'), /epoch == self.recognitionEpoch && \[operation isEqualToString:self.recognitionID\]/);
  assert.match(method(bridge, 'releaseRecognition'), /self.recognitionEpoch \+= 1/);
});

test('ASR uses live in-memory buffers with partial text; only actual final emits complete', () => {
  const start = method(bridge, 'beginRecording:');
  assert.match(start, /SFSpeechAudioBufferRecognitionRequest new/);
  assert.match(start, /shouldReportPartialResults = YES/);
  assert.match(start, /appendAudioPCMBuffer:buffer/);
  ordered(start, 'recognitionCurrent:operation epoch:epoch', '@"recognition_result"', 'if (result.isFinal)', '@"recognition_complete"');
  assert.doesNotMatch(bridge, /SFSpeechURLRecognitionRequest|AVAudioRecorder|writeToFile|writeToURL/);
  assert.doesNotMatch(method(bridge, 'finishRecognition'), /@"recognition_complete"/);
});

test('finish/cancel are ID-scoped and release stops audio before cancelling task', () => {
  const handling = method(bridge, 'handleVoice:');
  assert.match(handling, /!\[operation isEqualToString:self.recognitionID\]/);
  assert.match(handling, /if \(\[operation isEqualToString:self.recognitionID\]\) \[self cancelRecognition/);
  ordered(method(bridge, 'releaseRecognition'), 'self.recognitionID = nil', '[self stopRecordingAudio]', '[self.recognitionTask cancel]');
  const stop = method(bridge, 'stopRecordingAudio');
  assert.match(stop, /removeTapOnBus:0/);
  assert.match(stop, /endAudio/);
  assert.match(method(bridge, 'finishRecognition'), /8 \* NSEC_PER_SEC/);
});

test('speech chunks preserve Unicode and only the last real utterance completion finishes playback', () => {
  const chunks = method(bridge, 'chunksForText:');
  assert.match(chunks, /NSStringEnumerationByComposedCharacterSequences/);
  assert.match(chunks, /chunk.length >= 500/);
  assert.doesNotMatch(chunks, /substringToIndex/);
  const complete = method(bridge, 'didFinishSpeechUtterance:');
  ordered(complete, 'synthesizer != self.synthesizer', 'utterance != self.utterance', 'self.speechIndex += 1',
    'self.speechIndex < self.speechChunks.count', '[self speakNext]', '@"speech_complete"');
  ordered(method(bridge, 'releaseSpeech'), 'self.speechID = nil', 'old.delegate = nil', 'stopSpeakingAtBoundary:AVSpeechBoundaryImmediate');
});

test('audio background/interruption cleanup never cancels persisted reminders', () => {
  assert.match(bridge, /UIApplicationDidEnterBackgroundNotification/);
  assert.doesNotMatch(bridge, /UIApplicationWillResignActiveNotification/); // permission dialogs also resign active
  assert.match(bridge, /AVAudioSessionInterruptionNotification/);
  assert.match(bridge, /AVAudioSessionMediaServicesWereResetNotification/);
  assert.match(controller, /viewDidDisappear[\s\S]*stopVoiceForBackground/);
  assert.doesNotMatch(method(bridge, 'stopVoiceForBackground'), /reminders\.clear|removePending|saveLedger/);
});

test('a process-wide serial reminder queue prevents separate abilities racing the same ledger', () => {
  assert.match(method(reminders, 'sharedService'), /dispatch_once/);
  ordered(method(reminders, 'drain'), 'if (self.current || self.jobs.count == 0) return', 'self.current = job', '[self replace:job]');
  assert.match(method(reminders, 'finish:'), /if \(self.current != job\) return/);
  assert.match(method(reminders, 'isCurrent:'), /self.current == job && !job.cancelled && job.epoch == self.epoch/);
});

test('clear invalidates delayed authorization before entering queue; its late callback cannot save consent', () => {
  ordered(method(reminders, 'handle:'), '@"reminders.clear"', 'self.epoch += 1', 'self.current.cancelled = YES', '[self.jobs addObject:job]');
  ordered(method(reminders, 'authorize:'), 'requestAuthorizationWithOptions', 'if (![self isCurrent:job])', 'saveLedger:');
  assert.match(method(reminders, 'authorize:'), /oldScope.length && !\[oldScope isEqualToString:scope\]/);
});

test('replace requires same persisted consent and OS permission, then journals all cleanup IDs before any add', () => {
  const replace = method(reminders, 'replace:');
  ordered(replace, 'self.ledger[@"consent"]', 'self.ledger[@"scope"]', 'getNotificationSettingsWithCompletionHandler',
    '@"granted"', 'addEntriesFromDictionary:desired', 'saveLedger:', '[self addItems:desired');
  assert.match(method(reminders, 'saveLedger:'), /NSDataWritingAtomic/);
  assert.match(method(reminders, 'saveLedger:'), /NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication/);
  assert.match(method(reminders, 'init'), /Never overwrite an unreadable cleanup ledger/);
  assert.match(method(reminders, 'init'), /NSURLIsExcludedFromBackupKey/);
});

test('clear affects matching scope IDs only; asynchronous removals are verified before ledger clears', () => {
  const clear = method(reminders, 'clear:');
  ordered(clear, 'oldScope.length && ![oldScope isEqualToString:scope]', '@"recovery": @YES', 'removeIDs:ids', 'if (![self isCurrent:job])', '@"recovery": @NO');
  assert.doesNotMatch(reminders, /removeAllPendingNotificationRequests|removeAllDeliveredNotifications/);
  const verify = method(reminders, 'verifyRemoved:');
  assert.match(verify, /getPendingNotificationRequestsWithCompletionHandler/);
  assert.match(verify, /getDeliveredNotificationsWithCompletionHandler/);
  assert.match(verify, /completion\(!remains\)/);
});

test('late add completion after clear cleans registered IDs before the serial queue advances', () => {
  const add = method(reminders, 'addItems:');
  assert.match(add, /if \(!\[self isCurrent:job\]\) \{ \[self abortReplace:job\]/);
  ordered(add, 'addNotificationRequest:request withCompletionHandler:', 'error || ![self isCurrent:job]', '[self abortReplace:job]', 'index:index + 1');
  ordered(method(reminders, 'abortReplace:'), 'removeIDs:[self.ledger[@"items"] allKeys]', 'if (removed)', '[self finish:job');
  assert.match(method(reminders, 'handle:'), /A timed-out add retains the ledger/);
});

test('interrupted native journal stays queryable for cleanup and cannot silently authorize or replace', () => {
  const status = method(reminders, 'status:');
  assert.match(status, /self.ledger\[@"recovery"\]/);
  assert.match(status, /@"cleanup_required": @YES/);
  assert.match(status, /@"scope": self.ledger\[@"scope"\]/);
  assert.match(method(reminders, 'authorize:'), /self.ledger\[@"recovery"\] boolValue/);
  assert.match(method(reminders, 'replace:'), /self.ledger\[@"recovery"\] boolValue/);
  assert.match(method(reminders, 'clear:'), /@"recovery": @YES/);
  assert.match(method(reminders, 'clear:'), /@"recovery": @NO/);
  ordered(method(reminders, 'clear:'), 'if (!oldScope.length && ids.count == 0)', '[self status:job]; return;', '@"recovery": @YES');
});

test('system notifications contain generic lock-screen text and no account/task/transcript payload', () => {
  const add = method(reminders, 'addItems:');
  assert.match(add, /content.title = @"行简提醒"/);
  assert.match(add, /content.body = @"你有一项安排即将开始，打开应用查看。"/);
  assert.doesNotMatch(add, /content\.userInfo\s*=|content\.(title|body)\s*=\s*(job|desired|self|command)/);
  assert.match(add, /triggerWithTimeInterval:delay repeats:NO/);
  assert.match(method(reminders, 'identifier:'), /CC_SHA256/);
});

test('Objective-C sources and required system frameworks are wired into Xcode build phases', () => {
  for (const name of ['CFNativeProtocol', 'CFReminderService', 'CFPlatformBridge']) {
    read(`app/${name}.m`); read(`app/${name}.h`);
    assert.match(project, new RegExp(`${name}\\.m in Sources \\*/ = \\{isa = PBXBuildFile;`));
    assert.match(project, new RegExp(`${name}\\.m in Sources \\*/,`));
  }
  for (const name of ['Speech', 'AVFoundation', 'UserNotifications']) {
    assert.match(project, new RegExp(`${name}\\.framework in Frameworks \\*/,`));
    assert.match(project, new RegExp(`System/Library/Frameworks/${name}\\.framework`));
  }
});

test('permission descriptions disclose system speech processing without background recording entitlement', () => {
  assert.match(plist, /NSMicrophoneUsageDescription/);
  assert.match(plist, /NSSpeechRecognitionUsageDescription/);
  assert.match(plist, /系统服务可能联网处理音频/);
  assert.doesNotMatch(plist, /UIBackgroundModes/);
  assert.doesNotMatch(project, /DEVELOPMENT_TEAM\s*=|PROVISIONING_PROFILE_SPECIFIER\s*=|CODE_SIGN_IDENTITY\s*=/);
  assert.equal((project.match(/CODE_SIGN_STYLE = Automatic;/g) ?? []).length, 2);
  assert.match(read('app/AppDelegate.m'), /@available\(iOS 13\.0, \*\)/);
  assert.doesNotMatch(read('app/AppDelegate.m'), /NSLog/);
});

test('available host plist parser validates plist and pbxproj syntax without invoking Xcode', { skip: process.platform !== 'darwin' }, () => {
  for (const path of ['app/Info.plist', 'app.xcodeproj/project.pbxproj']) {
    const result = spawnSync('/usr/bin/plutil', ['-lint', new URL(path, native).pathname], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stdout + result.stderr);
  }
});
