package com.campusflow.agent;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

import ohos.ace.adapter.capability.bridge.BridgeManager;
import ohos.ace.adapter.capability.bridge.BridgePlugin;

/** Wire v1. Reflection entry dispatch is retained by proguard-rules.pro. */
public final class CampusFlowPlatformBridge extends BridgePlugin {
    private static final int MICROPHONE_PERMISSION = 7301;
    private static final int NOTIFICATION_PERMISSION = 7302;
    private final Activity activity;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final CampusFlowReminderStore reminders;
    private boolean foreground;
    private boolean destroyed;
    private int permissionRequest;
    private long reminderRevision;
    private Request authorization;
    private long authorizationRevision;
    private boolean authorizationPermissionReady;

    private SpeechRecognizer recognizer;
    private String recognitionId = "";
    private long recognitionRevision;
    private Request recognitionStart;
    private boolean recognitionStarted;
    private boolean recognitionNotified;

    private TextToSpeech tts;
    private boolean ttsReady;
    private boolean ttsInitializing;
    private long ttsRevision;
    private final List<Runnable> ttsWaiters = new ArrayList<>();
    private String speechId = "";
    private long speechRevision;
    private String utteranceId = "";
    private List<String> chunks = new ArrayList<>();
    private int chunkIndex;
    private boolean speechNotified;
    private Request speechStart;
    private AudioFocusRequest focus;
    private long focusRevision;

    private static final class Request {
        final String id;
        final String op;
        final String operation;
        final String scope;
        final String text;
        final List<CampusFlowReminderStore.Item> items;
        boolean replied;
        Request(String id, String op, String operation, String scope, String text,
                List<CampusFlowReminderStore.Item> items) {
            this.id = id; this.op = op; this.operation = operation; this.scope = scope;
            this.text = text; this.items = items;
        }
    }

    public CampusFlowPlatformBridge(Activity activity, BridgeManager manager) {
        super(activity, "CampusFlowPlatform", manager, BridgeType.JSON_TYPE);
        this.activity = activity;
        this.reminders = new CampusFlowReminderStore(activity);
    }

    /** No OS work on the bridge worker. Even errors with a valid ID get one terminal event. */
    public String dispatch(String commandJSON) {
        try {
            Request request = parse(commandJSON);
            main.post(() -> execute(request));
            return "accepted";
        } catch (Exception ignored) {
            if (commandJSON != null && commandJSON.length() <= 262144) {
                try {
                    Object id = new JSONObject(commandJSON).opt("request_id");
                    if (id instanceof String && NativePolicy.requestId((String) id)) {
                        Request invalid = new Request((String) id, "", "", "", "", new ArrayList<>());
                        main.post(() -> reply(invalid, false, "INVALID_REQUEST", null));
                    }
                } catch (Exception malformed) { /* Unparseable input has no valid correlation ID. */ }
            }
            return "rejected";
        }
    }

    private Request parse(String raw) throws JSONException {
        if (raw == null || raw.length() > 262144) throw new JSONException("INVALID_REQUEST");
        JSONObject json = new JSONObject(raw);
        Object version = json.opt("v");
        if (!(version instanceof Number) || ((Number) version).doubleValue() != 1) throw new JSONException("INVALID_REQUEST");
        String id = string(json, "request_id", true);
        String op = string(json, "op", true);
        String operation = string(json, "operation_id", false);
        String scope = string(json, "scope", false);
        String text = string(json, "text", false);
        if (!NativePolicy.requestId(id) || (!operation.isEmpty() && !NativePolicy.requestId(operation))
                || (!scope.isEmpty() && !NativePolicy.scope(scope)) || text.length() > 32000) {
            throw new JSONException("INVALID_REQUEST");
        }
        boolean voiceOperation = op.equals("recognition.start") || op.equals("recognition.finish")
                || op.equals("recognition.cancel") || op.equals("speech.start");
        boolean scoped = op.equals("reminders.authorize") || op.equals("reminders.replace") || op.equals("reminders.clear");
        if ((voiceOperation && operation.isEmpty()) || (scoped && !NativePolicy.scope(scope))) throw new JSONException("INVALID_REQUEST");
        if (op.equals("speech.start") && text.trim().isEmpty()) throw new JSONException("INVALID_REQUEST");
        if (!(voiceOperation || scoped || op.equals("capabilities") || op.equals("speech.stop")
                || op.equals("voice.dispose") || op.equals("reminders.status"))) throw new JSONException("INVALID_REQUEST");
        List<CampusFlowReminderStore.Item> items = new ArrayList<>();
        if (op.equals("reminders.replace")) {
            Object rawItems = json.opt("reminders");
            if (!(rawItems instanceof JSONArray)) throw new JSONException("INVALID_REQUEST");
            JSONArray array = (JSONArray) rawItems;
            if (array.length() > NativePolicy.MAX_REMINDERS) throw new JSONException("INVALID_REQUEST");
            Set<String> ids = new HashSet<>();
            long now = System.currentTimeMillis();
            for (int i = 0; i < array.length(); i++) {
                JSONObject item = array.getJSONObject(i);
                String reminderId = string(item, "id", true);
                Object value = item.opt("fire_at_ms");
                if (!(value instanceof Number)) throw new JSONException("INVALID_REQUEST");
                double number = ((Number) value).doubleValue();
                if (!Double.isFinite(number) || number != Math.rint(number)
                        || !NativePolicy.futureTime(((Number) value).longValue(), now)
                        || !NativePolicy.reminderId(reminderId) || !ids.add(reminderId)) throw new JSONException("INVALID_REQUEST");
                items.add(new CampusFlowReminderStore.Item(reminderId, ((Number) value).longValue()));
            }
        } else if (json.has("reminders")) throw new JSONException("INVALID_REQUEST");
        return new Request(id, op, operation, scope, text, items);
    }

    private static String string(JSONObject json, String key, boolean required) throws JSONException {
        if (!json.has(key) && !required) return "";
        Object value = json.opt(key);
        if (!(value instanceof String)) throw new JSONException("INVALID_REQUEST");
        return (String) value;
    }

    private void execute(Request request) {
        if (destroyed) { reply(request, false, "OPERATION_CANCELLED", null); return; }
        try {
            switch (request.op) {
                case "capabilities":
                    ensureTts(() -> {
                        try {
                            reply(request, true, "", new JSONObject()
                                    .put("recognition", recognitionAvailable())
                                    .put("synthesis", ttsReady).put("reminders", reminders.available()));
                        } catch (Exception error) { reply(request, false, "UNAVAILABLE", null); }
                    });
                    break;
                case "recognition.start": startRecognition(request); break;
                case "recognition.finish":
                    if (request.operation.equals(recognitionId)) {
                        if (recognitionStarted && recognizer != null) {
                            try { recognizer.stopListening(); }
                            catch (Exception error) { cancelRecognition("SYSTEM_ERROR"); throw error; }
                        } else cancelRecognition("OPERATION_CANCELLED");
                    }
                    reply(request, true, "", null);
                    break;
                case "recognition.cancel":
                    if (request.operation.equals(recognitionId)) cancelRecognition("OPERATION_CANCELLED");
                    reply(request, true, "", null);
                    break;
                case "speech.start": startSpeech(request); break;
                case "speech.stop":
                    if (request.operation.isEmpty() || request.operation.equals(speechId)) stopSpeech("OPERATION_CANCELLED");
                    reply(request, true, "", null);
                    break;
                case "voice.dispose": stopVoice(); releaseTts(); reply(request, true, "", null); break;
                case "reminders.status": reply(request, true, "", reminders.status()); break;
                case "reminders.authorize": authorizeReminders(request); break;
                case "reminders.replace": reply(request, true, "", reminders.replace(request.scope, request.items)); break;
                case "reminders.clear":
                    // A delayed permission grant must never recreate consent after this account is cleared.
                    if (authorization != null && authorization.scope.equals(request.scope)) {
                        reminderRevision++;
                        reply(authorization, false, "OPERATION_CANCELLED", null);
                        authorization = null;
                        authorizationPermissionReady = false;
                    }
                    reply(request, true, "", reminders.clear(request.scope));
                    break;
                default: reply(request, false, "INVALID_REQUEST", null);
            }
        } catch (SecurityException denied) { reply(request, false, "PERMISSION_DENIED", null);
        } catch (IllegalArgumentException invalid) { reply(request, false, "INVALID_REQUEST", null);
        } catch (Exception error) { reply(request, false, "SYSTEM_ERROR", null); }
    }

    private void authorizeReminders(Request request) throws Exception {
        if (!foreground || permissionRequest != 0 || authorization != null) {
            reply(request, false, "OPERATION_CANCELLED", null); return;
        }
        String current = reminders.consentScope();
        if (!current.isEmpty() && !current.equals(request.scope)) {
            reply(request, false, "OPERATION_CANCELLED", null); return;
        }
        if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            authorization = request;
            authorizationRevision = ++reminderRevision;
            authorizationPermissionReady = false;
            reminders.markPermissionAsked();
            permissionRequest = NOTIFICATION_PERMISSION;
            try {
                activity.requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIFICATION_PERMISSION);
            } catch (Exception error) {
                permissionRequest = 0;
                authorization = null;
                reply(request, false, "SYSTEM_ERROR", null);
                return;
            }
            main.postDelayed(() -> {
                if (authorization == request) {
                    authorization = null;
                    authorizationPermissionReady = false;
                    reminderRevision++;
                    reply(request, false, "OPERATION_CANCELLED", null);
                }
            }, 55000);
        } else {
            reminders.authorize(request.scope);
            reply(request, true, "", reminders.status());
        }
    }

    void onPermissionResult(int code) {
        if (code != MICROPHONE_PERMISSION && code != NOTIFICATION_PERMISSION) return;
        if (permissionRequest == code) permissionRequest = 0;
        if (code == MICROPHONE_PERMISSION) {
            Request request = recognitionStart;
            if (request == null || !request.operation.equals(recognitionId)) return;
            if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                cancelRecognition("PERMISSION_DENIED");
            } else if (foreground) beginRecognition(request, recognitionRevision);
            // Android may deliver the permission callback before onResume. onStop invalidates it;
            // otherwise onForeground can finish this same explicit, still-current request.
        } else {
            authorizationPermissionReady = true;
            if (foreground) completeAuthorization();
        }
    }

    private void completeAuthorization() {
        Request request = authorization;
        authorization = null;
        authorizationPermissionReady = false;
        if (request == null) return;
        if (authorizationRevision != reminderRevision || !foreground) {
            reply(request, false, "OPERATION_CANCELLED", null); return;
        }
        try {
            reminders.authorize(request.scope);
            reply(request, true, "", reminders.status());
        } catch (SecurityException denied) { reply(request, false, "PERMISSION_DENIED", null);
        } catch (Exception error) { reply(request, false, "SYSTEM_ERROR", null); }
    }

    private void startRecognition(Request request) {
        if (!foreground || permissionRequest != 0) { reply(request, false, "OPERATION_CANCELLED", null); return; }
        cancelRecognition("OPERATION_CANCELLED");
        stopSpeech("OPERATION_CANCELLED");
        if (!recognitionAvailable()) { reply(request, false, "UNAVAILABLE", null); return; }
        recognitionId = request.operation;
        recognitionStart = request;
        recognitionStarted = false;
        recognitionNotified = false;
        long revision = ++recognitionRevision;
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            permissionRequest = MICROPHONE_PERMISSION;
            try { activity.requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, MICROPHONE_PERMISSION);
            } catch (Exception error) { permissionRequest = 0; cancelRecognition("SYSTEM_ERROR"); }
            main.postDelayed(() -> {
                if (recognitionRevision == revision && recognitionStart == request && !recognitionStarted) {
                    cancelRecognition("OPERATION_CANCELLED");
                }
            }, 55000);
        } else beginRecognition(request, revision);
    }

    private boolean currentRecognition(String id, long revision) {
        return !destroyed && foreground && id.equals(recognitionId) && revision == recognitionRevision;
    }

    private boolean recognitionAvailable() {
        return activity.getPackageManager().hasSystemFeature(PackageManager.FEATURE_MICROPHONE)
                && SpeechRecognizer.isRecognitionAvailable(activity);
    }

    private void beginRecognition(Request request, long revision) {
        if (!currentRecognition(request.operation, revision)) { reply(request, false, "OPERATION_CANCELLED", null); return; }
        try {
            if (!acquireFocus(true)) { cancelRecognition("UNAVAILABLE"); return; }
            recognizer = SpeechRecognizer.createSpeechRecognizer(activity);
            recognizer.setRecognitionListener(new RecognitionListener() {
                @Override public void onReadyForSpeech(Bundle params) {
                    if (currentRecognition(request.operation, revision) && !recognitionNotified) {
                        recognitionNotified = true;
                        voice(request.operation, "recognition_start", null, null);
                    }
                }
                @Override public void onPartialResults(Bundle results) {
                    if (currentRecognition(request.operation, revision)) emitRecognitionText(request.operation, results);
                }
                @Override public void onResults(Bundle results) {
                    if (!currentRecognition(request.operation, revision)) return;
                    if (!emitRecognitionText(request.operation, results)) { cancelRecognition("UNAVAILABLE"); return; }
                    voice(request.operation, "recognition_complete", null, null);
                    clearRecognition();
                }
                @Override public void onError(int error) {
                    if (currentRecognition(request.operation, revision)) {
                        cancelRecognition(error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ? "PERMISSION_DENIED" : "UNAVAILABLE");
                    }
                }
                @Override public void onBeginningOfSpeech() { }
                @Override public void onRmsChanged(float rmsdB) { }
                @Override public void onBufferReceived(byte[] buffer) { /* Never save or bridge PCM. */ }
                @Override public void onEndOfSpeech() { /* Await final onResults, not merely silence. */ }
                @Override public void onEvent(int eventType, Bundle params) { }
            });
            Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                    .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    .putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
                    .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
            recognitionStarted = true;
            recognizer.startListening(intent);
            reply(request, true, "", null);
            main.postDelayed(() -> {
                if (currentRecognition(request.operation, revision)) cancelRecognition("UNAVAILABLE");
            }, 60000);
        } catch (SecurityException denied) { cancelRecognition("PERMISSION_DENIED");
        } catch (Exception error) { cancelRecognition("UNAVAILABLE"); }
    }

    private boolean emitRecognitionText(String id, Bundle bundle) {
        ArrayList<String> values = bundle == null ? null : bundle.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
        if (values == null || values.isEmpty() || values.get(0) == null || values.get(0).isEmpty()) return false;
        String text = values.get(0);
        if (text.length() > 32000) { cancelRecognition("UNAVAILABLE"); return false; }
        voice(id, "recognition_result", text, null);
        return true;
    }

    private void cancelRecognition(String code) {
        if (!recognitionId.isEmpty()) voice(recognitionId, "recognition_error", null, code);
        if (recognitionStart != null) reply(recognitionStart, false, code, null);
        clearRecognition();
    }

    private void clearRecognition() {
        recognitionId = "";
        recognitionRevision++;
        recognitionStart = null;
        recognitionStarted = false;
        SpeechRecognizer previous = recognizer;
        recognizer = null;
        if (previous != null) {
            try { previous.cancel(); } catch (Exception ignored) { }
            try { previous.destroy(); } catch (Exception ignored) { }
        }
        releaseFocus();
    }

    private void ensureTts(Runnable completion) {
        if (ttsReady) { completion.run(); return; }
        ttsWaiters.add(completion);
        if (ttsInitializing) return;
        ttsInitializing = true;
        long revision = ++ttsRevision;
        try {
            tts = new TextToSpeech(activity, status -> main.post(() -> {
                if (revision != ttsRevision || destroyed) return;
                ttsInitializing = false;
                try {
                    int language = status == TextToSpeech.SUCCESS && tts != null
                            ? tts.setLanguage(Locale.SIMPLIFIED_CHINESE) : TextToSpeech.LANG_NOT_SUPPORTED;
                    ttsReady = language >= TextToSpeech.LANG_AVAILABLE;
                    if (ttsReady) tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
                        @Override public void onStart(String id) { main.post(() -> {
                            if (currentUtterance(id) && !speechNotified) {
                                speechNotified = true; voice(speechId, "speech_start", null, null);
                            }
                        }); }
                        @Override public void onDone(String id) { main.post(() -> {
                            if (!currentUtterance(id)) return;
                            chunkIndex++;
                            if (chunkIndex < chunks.size()) speakChunk();
                            else {
                                voice(speechId, "speech_complete", null, null);
                                speechId = ""; utteranceId = ""; chunks.clear(); speechStart = null; releaseFocus();
                            }
                        }); }
                        @Override public void onError(String id) { main.post(() -> {
                            if (currentUtterance(id)) stopSpeech("UNAVAILABLE");
                        }); }
                        @Override public void onError(String id, int code) { onError(id); }
                    });
                } catch (Exception error) { ttsReady = false; }
                finishTtsWaiters();
                if (!ttsReady && tts != null) { tts.shutdown(); tts = null; }
            }));
            main.postDelayed(() -> {
                if (revision == ttsRevision && ttsInitializing) releaseTts();
            }, 8000);
        } catch (Exception error) { releaseTts(); }
    }

    private void finishTtsWaiters() {
        List<Runnable> waiting = new ArrayList<>(ttsWaiters);
        ttsWaiters.clear();
        for (Runnable callback : waiting) callback.run();
    }

    private void startSpeech(Request request) {
        if (!foreground) { reply(request, false, "OPERATION_CANCELLED", null); return; }
        cancelRecognition("OPERATION_CANCELLED");
        stopSpeech("OPERATION_CANCELLED");
        speechId = request.operation;
        speechStart = request;
        speechNotified = false;
        long revision = ++speechRevision;
        ensureTts(() -> {
            if (destroyed || !foreground || revision != speechRevision || !request.operation.equals(speechId)) {
                reply(request, false, "OPERATION_CANCELLED", null); return;
            }
            if (!ttsReady) { stopSpeech("UNAVAILABLE"); return; }
            try {
                if (!acquireFocus(false)) { stopSpeech("UNAVAILABLE"); return; }
                chunks = NativePolicy.speechChunks(request.text, TextToSpeech.getMaxSpeechInputLength());
                chunkIndex = 0;
                speakChunk();
                if (!speechId.isEmpty()) reply(request, true, "", null);
            } catch (Exception error) { stopSpeech("UNAVAILABLE"); }
        });
    }

    private boolean currentUtterance(String id) {
        return !destroyed && foreground && !speechId.isEmpty() && id != null && id.equals(utteranceId);
    }

    private void speakChunk() {
        utteranceId = "CampusFlow-" + speechRevision + "-" + chunkIndex;
        if (tts == null || tts.speak(chunks.get(chunkIndex), TextToSpeech.QUEUE_FLUSH, null, utteranceId) == TextToSpeech.ERROR) {
            stopSpeech("UNAVAILABLE");
        }
    }

    private void stopSpeech(String code) {
        String old = speechId;
        speechId = ""; utteranceId = ""; speechRevision++; chunks.clear();
        if (!old.isEmpty()) voice(old, "speech_error", null, code);
        if (speechStart != null) reply(speechStart, false, code, null);
        speechStart = null;
        if (tts != null) try { tts.stop(); } catch (Exception ignored) { }
        releaseFocus();
    }

    private void releaseTts() {
        ttsRevision++;
        ttsInitializing = false;
        ttsReady = false;
        TextToSpeech previous = tts;
        tts = null;
        if (previous != null) try { previous.shutdown(); } catch (Exception ignored) { }
        finishTtsWaiters();
    }

    private boolean acquireFocus(boolean recording) {
        releaseFocus();
        AudioManager manager = activity.getSystemService(AudioManager.class);
        if (manager == null) return false;
        long revision = ++focusRevision;
        focus = new AudioFocusRequest.Builder(recording ? AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE : AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setOnAudioFocusChangeListener(change -> {
                    if (revision == focusRevision && change < 0) stopVoice();
                }, main).build();
        return manager.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
    }

    private void releaseFocus() {
        focusRevision++;
        if (focus == null) return;
        AudioFocusRequest previous = focus;
        focus = null;
        AudioManager manager = activity.getSystemService(AudioManager.class);
        if (manager != null) try { manager.abandonAudioFocusRequest(previous); } catch (Exception ignored) { }
    }

    void onForeground() {
        foreground = true;
        if (authorizationPermissionReady) completeAuthorization();
        if (recognitionStart != null && !recognitionStarted && permissionRequest == 0
                && activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            beginRecognition(recognitionStart, recognitionRevision);
        }
    }

    void onPaused() {
        foreground = false;
        // A permission sheet can pause Activity; never continue existing recording/playback.
        // A request awaiting that sheet is retained only until onStop or the same-sheet result.
        if (recognitionStarted) cancelRecognition("OPERATION_CANCELLED");
        stopSpeech("OPERATION_CANCELLED");
    }

    void onBackground() {
        foreground = false;
        stopVoice();
        if (authorization != null) reply(authorization, false, "OPERATION_CANCELLED", null);
        authorization = null;
        authorizationPermissionReady = false;
        reminderRevision++;
    }

    private void stopVoice() { cancelRecognition("OPERATION_CANCELLED"); stopSpeech("OPERATION_CANCELLED"); }

    void onHostDestroy() {
        foreground = false;
        stopVoice();
        releaseTts();
        if (authorization != null) reply(authorization, false, "OPERATION_CANCELLED", null);
        authorization = null;
        authorizationPermissionReady = false;
        reminderRevision++;
        destroyed = true;
        // Activity-owned bridge manager is released by StageActivity; reminders remain scheduled.
    }

    private void reply(Request request, boolean ok, String code, JSONObject result) {
        if (request.replied) return;
        request.replied = true;
        try {
            JSONObject event = new JSONObject().put("v", 1).put("kind", "reply")
                    .put("request_id", request.id).put("ok", ok).put("code", code);
            if (result != null) event.put("result", result);
            emit(event);
        } catch (JSONException ignored) { }
    }

    private void voice(String id, String eventName, String text, String code) {
        try {
            JSONObject event = new JSONObject().put("v", 1).put("kind", "voice")
                    .put("operation_id", id).put("event", eventName);
            if (text != null) event.put("text", text);
            if (code != null) event.put("code", code);
            emit(event);
        } catch (JSONException ignored) { }
    }

    private void emit(JSONObject event) {
        try { callMethod("onEvent", event.toString()); } catch (Exception ignored) { /* Caller uses timeout/status recovery. */ }
    }
}
