import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

// Wiring assertions below are STATIC. They do not execute Android APIs or prove native compilation.
const root = new URL('../.arkui-x/android/app/', import.meta.url);
const javaRoot = new URL('src/main/java/com/campusflow/agent/', root);
const read = name => readFileSync(new URL(name, javaRoot), 'utf8');
const bridge = read('CampusFlowPlatformBridge.java');
const store = read('CampusFlowReminderStore.java');
const activity = read('EntryEntryAbilityActivity.java');
const receiver = read('CampusFlowReminderReceiver.java');
const manifest = readFileSync(new URL('src/main/AndroidManifest.xml', root), 'utf8');
const proguard = readFileSync(new URL('proguard-rules.pro', root), 'utf8');

function method(source, signature) {
  const start = source.indexOf(signature);
  assert.notEqual(start, -1, signature);
  const brace = source.indexOf('{', start);
  let depth = 1;
  let end = brace + 1;
  while (depth > 0 && end < source.length) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
    end++;
  }
  assert.equal(depth, 0, signature);
  return source.slice(brace + 1, end - 1);
}

test('static: official API11 JSON bridge and reflection name agree with wire v1', () => {
  assert.match(bridge, /super\(activity, "CampusFlowPlatform", manager, BridgeType\.JSON_TYPE\)/);
  assert.match(bridge, /public String dispatch\(String commandJSON\)/);
  assert.match(bridge, /callMethod\("onEvent", event\.toString\(\)\)/);
  assert.match(proguard, /public java\.lang\.String dispatch\(java\.lang\.String\)/);
  assert.ok(activity.indexOf('new CampusFlowPlatformBridge') < activity.indexOf('super.onCreate'));
});

test('static: all frozen operations dispatch through the main looper', () => {
  assert.match(bridge, /new Handler\(Looper\.getMainLooper\(\)\)/);
  assert.match(method(bridge, 'public String dispatch('), /main\.post\(\(\) -> execute\(request\)\)/);
  const operations = [...bridge.matchAll(/case "([^"]+)":/g)].map(match => match[1]);
  assert.deepEqual(operations.sort(), ['capabilities', 'clock.sample', 'recognition.start', 'recognition.finish',
    'recognition.cancel', 'speech.start', 'speech.stop', 'voice.dispose', 'reminders.status',
    'reminders.authorize', 'reminders.replace', 'reminders.clear'].sort());
  assert.match(method(bridge, 'private void reply('), /if \(request\.replied\) return;[\s\S]*request\.replied = true/);
});

test('static: manifest declares mic, API33 notification, reboot and service visibility', () => {
  for (const permission of ['RECORD_AUDIO', 'POST_NOTIFICATIONS', 'RECEIVE_BOOT_COMPLETED']) {
    assert.equal((manifest.match(new RegExp(`android.permission.${permission}`, 'g')) ?? []).length, 1);
  }
  assert.match(manifest, /<queries>[\s\S]*android\.speech\.RecognitionService[\s\S]*android\.intent\.action\.TTS_SERVICE[\s\S]*<\/queries>/);
  assert.match(manifest, /<receiver android:name="\.CampusFlowReminderReceiver" android:exported="false">/);
  assert.match(manifest, /android:name="android.hardware.microphone" android:required="false"/);
  assert.doesNotMatch(manifest, /SCHEDULE_EXACT_ALARM|USE_EXACT_ALARM|FOREGROUND_SERVICE/);
});

test('static: permission results, pause, background and destruction reach native lifecycle', () => {
  for (const hook of ['onPermissionResult(requestCode)', 'onForeground()', 'onPaused()', 'onBackground()', 'onHostDestroy()']) {
    assert.ok(activity.includes(`platformBridge.${hook}`), hook);
  }
  assert.match(method(bridge, 'void onBackground('), /stopVoice\(\)/);
  assert.match(method(bridge, 'void onBackground('), /authorization = null/);
  assert.match(method(bridge, 'void onForeground('), /recognitionStart != null[\s\S]*permissionRequest == 0/);
  assert.doesNotMatch(method(bridge, 'void onHostDestroy('), /reminders\.clear/);
});

test('static: late voice callbacks and audio-focus loss are generation guarded', () => {
  assert.match(method(bridge, 'private boolean currentRecognition('), /revision == recognitionRevision/);
  assert.match(method(bridge, 'private boolean currentUtterance('), /id\.equals\(utteranceId\)/);
  assert.match(bridge, /revision == focusRevision && change < 0/);
  assert.match(bridge, /if \(request\.operation\.equals\(recognitionId\)\)/);
  assert.match(bridge, /request\.operation\.isEmpty\(\) \|\| request\.operation\.equals\(speechId\)/);
  assert.match(bridge, /revision != speechRevision/);
  assert.match(bridge, /revision != ttsRevision/);
  assert.doesNotMatch(method(bridge, 'private void stopVoice('), /reminders/);
});

test('static: ASR waits for final results; TTS advances all chunks and ends on final onDone', () => {
  assert.match(bridge, /onResults\(Bundle results\)[\s\S]*"recognition_complete"/);
  assert.doesNotMatch(method(bridge, 'public void onEndOfSpeech('), /voice\(/);
  assert.match(bridge, /NativePolicy\.speechChunks\(request\.text, TextToSpeech\.getMaxSpeechInputLength\(\)\)/);
  const done = method(bridge, 'public void onDone(');
  assert.match(done, /chunkIndex\+\+[\s\S]*chunkIndex < chunks\.size\(\)[\s\S]*speakChunk\(\)[\s\S]*"speech_complete"/);
  assert.doesNotMatch(bridge, /FileOutputStream|MediaRecorder|HttpURLConnection|android\.util\.Log/);
});

test('static: full reminder batch validates before durable journal or OS mutation', () => {
  const replace = method(store, 'JSONObject replace(');
  assert.ok(replace.indexOf('NativePolicy.futureTime') < replace.indexOf('write(ledger)'));
  assert.ok(replace.indexOf('write(ledger)') < replace.indexOf('cancel(id)'));
  assert.ok(replace.indexOf('schedule(item)') < replace.lastIndexOf('write(ledger)'));
  assert.match(replace, /!ledger\.scope\.equals\(scope\) \|\| !ledger\.enabled/);
  assert.match(replace, /if \(ledger\.recovery\) throw/);
  assert.match(store, /getNoBackupFilesDir\(\)/);
  assert.match(store, /AtomicFile/);
});

test('static: cleanup never clears a different account; failed cleanup retains journal', () => {
  const clear = method(store, 'JSONObject clear(');
  assert.ok(clear.indexOf('!ledger.scope.equals(scope)') < clear.indexOf('cancel(id)'));
  assert.ok(clear.indexOf('ledger.enabled = false') < clear.indexOf('cancel(id)'));
  assert.ok(clear.indexOf('write(ledger)') < clear.indexOf('cancel(id)'));
  assert.ok(clear.indexOf('cancel(id)') < clear.indexOf('ledger.scope = ""'));
  assert.match(method(bridge, 'private void execute('), /authorization\.scope\.equals\(request\.scope\)[\s\S]*reminderRevision\+\+/);
});

test('static: valid recovery status exposes its cleanup scope without blocking disable, while corrupt storage still fails', () => {
  const status = method(store, 'JSONObject status(');
  assert.match(status, /Ledger ledger = read\(\)/);
  assert.doesNotMatch(status, /ledger\.recovery\) throw/);
  assert.match(status, /\.put\("cleanup_required", ledger\.recovery\)/);
  assert.match(status, /\.put\("scope", ledger\.scope\)/);
  assert.match(status, /ledger\.enabled && !ledger\.recovery/);
  assert.match(method(store, 'void authorize('), /ledger\.recovery/);
  assert.match(method(store, 'JSONObject replace('), /if \(ledger\.recovery\) throw/);
  assert.match(method(store, 'private Ledger read('), /throw new IOException\("SYSTEM_ERROR"\)/);
});

test('static: genuine inexact alarm, immutable stable intent and generic notification are wired', () => {
  assert.match(store, /setAndAllowWhileIdle\(AlarmManager\.RTC_WAKEUP, item\.time, alarm\(item\.id, item\.time\)\)/);
  assert.match(store, /appendPath\(id\)/);
  assert.match(store, /PendingIntent\.FLAG_UPDATE_CURRENT \| PendingIntent\.FLAG_IMMUTABLE/);
  assert.match(store, /\.setContentTitle\(NativePolicy\.NOTIFICATION_TITLE\)\.setContentText\(NativePolicy\.NOTIFICATION_BODY\)/);
  assert.match(store, /notifications\.cancel\("CampusFlow\." \+ id, 0\)/);
  assert.doesNotMatch(store, /cancelAll\(|setExact|startForegroundService/);
});

test('static: boot restores only enabled, authorized future records and delivery checks current ledger', () => {
  assert.match(receiver, /Intent\.ACTION_BOOT_COMPLETED[\s\S]*store\.restoreAfterBoot\(\)/);
  const restore = method(store, 'void restoreAfterBoot(');
  assert.match(restore, /ledger\.recovery/);
  assert.match(restore, /!ledger\.enabled \|\| ledger\.scope\.isEmpty\(\) \|\| !permissionGranted\(\)/);
  assert.match(restore, /NativePolicy\.futureTime\(item\.time, now\)/);
  const deliver = method(store, 'void deliver(');
  assert.match(deliver, /ledger\.recovery/);
  assert.match(deliver, /item\.id\.equals\(id\) && item\.time == fireAt/);
  assert.doesNotMatch(method(store, 'private void write('), /title|token|password|transcript|audio/);
});

const javac = spawnSync('javac', ['-version'], { encoding: 'utf8' });
test('pure Java: production NativePolicy bounds and complete Unicode chunking (not Android APIs)', {
  skip: javac.status !== 0 ? 'Existing JDK unavailable; no Java compilation was performed or installed.' : false,
}, () => {
  const temp = mkdtempSync(join(tmpdir(), 'campusflow-native-policy-'));
  try {
    const compile = spawnSync('javac', ['-encoding', 'UTF-8', '-d', temp, fileURLToPath(new URL('NativePolicy.java', javaRoot)),
      fileURLToPath(new URL('fixtures/NativePolicyTest.java', import.meta.url))], { encoding: 'utf8' });
    assert.equal(compile.status, 0, compile.stderr);
    const run = spawnSync('java', ['-cp', temp, 'com.campusflow.agent.NativePolicyTest'], { encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /assertions passed \(pure Java only\)/);
  } finally { rmSync(temp, { recursive: true, force: true }); }
});
