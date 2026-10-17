package com.campusflow.agent;

import android.Manifest;
import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.util.AtomicFile;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;

/** Main-process, serialized OS scheduling and a durable cleanup journal. No network or audio. */
final class CampusFlowReminderStore {
    static final String ALARM_ACTION = "com.campusflow.agent.REMINDER";
    private static final String CHANNEL = "campusflow_plans";
    private static final Object LOCK = new Object();
    private final Context context;
    private final AtomicFile file;

    static final class Item {
        final String id;
        final long time;
        Item(String id, long time) { this.id = id; this.time = time; }
    }

    private static final class Ledger {
        String scope = "";
        boolean enabled;
        boolean asked;
        boolean recovery;
        List<Item> items = new ArrayList<>();
        List<String> cleanup = new ArrayList<>();
    }

    CampusFlowReminderStore(Context context) {
        this.context = context.getApplicationContext();
        this.file = new AtomicFile(new File(this.context.getNoBackupFilesDir(), "campusflow-reminders-v1.json"));
    }

    boolean available() {
        return context.getSystemService(AlarmManager.class) != null
                && context.getSystemService(NotificationManager.class) != null;
    }

    private void channel() {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) throw new IllegalStateException("UNAVAILABLE");
        manager.createNotificationChannel(new NotificationChannel(CHANNEL, "日程提醒", NotificationManager.IMPORTANCE_DEFAULT));
    }

    boolean permissionGranted() {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null || !manager.areNotificationsEnabled()) return false;
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) return false;
        NotificationChannel existing = manager.getNotificationChannel(CHANNEL);
        return existing == null || existing.getImportance() != NotificationManager.IMPORTANCE_NONE;
    }

    JSONObject status() throws IOException, JSONException {
        synchronized (LOCK) {
            Ledger ledger = read();
            int count = 0;
            // AlarmManager cannot enumerate its queue. A partial write has zero CONFIRMED records,
            // not proof of an empty system queue: cleanup_required takes precedence over the count.
            if (ledger.enabled && !ledger.recovery) {
                for (Item item : ledger.items) if (item.time > System.currentTimeMillis()) count++;
            }
            String permission = !available() ? "unsupported" : permissionGranted() ? "granted"
                    : (Build.VERSION.SDK_INT >= 33 && !ledger.asked ? "unknown" : "denied");
            return new JSONObject().put("permission", permission).put("scope", ledger.scope)
                    .put("scheduled", count).put("mode", "inexact").put("limited", false)
                    .put("cleanup_required", ledger.recovery);
        }
    }

    String consentScope() throws IOException, JSONException {
        synchronized (LOCK) { return read().scope; }
    }

    void markPermissionAsked() throws IOException, JSONException {
        synchronized (LOCK) {
            Ledger ledger = read();
            ledger.asked = true;
            write(ledger);
        }
    }

    void authorize(String scope) throws IOException, JSONException {
        synchronized (LOCK) {
            Ledger ledger = read();
            if (ledger.recovery || (!ledger.scope.isEmpty() && !ledger.scope.equals(scope))) {
                throw new IllegalStateException("OPERATION_CANCELLED");
            }
            channel();
            if (!permissionGranted()) throw new SecurityException("PERMISSION_DENIED");
            ledger.scope = scope;
            ledger.enabled = true;
            ledger.asked = true;
            write(ledger);
        }
    }

    JSONObject replace(String scope, List<Item> items) throws IOException, JSONException {
        synchronized (LOCK) {
            Ledger ledger = read();
            if (!ledger.scope.equals(scope) || !ledger.enabled) throw new SecurityException("PERMISSION_DENIED");
            if (ledger.recovery) throw new IOException("SYSTEM_ERROR");
            if (!permissionGranted()) throw new SecurityException("PERMISSION_DENIED");
            // Validate again immediately before any OS mutation, including elapsed queue time.
            long now = System.currentTimeMillis();
            LinkedHashSet<String> ids = new LinkedHashSet<>();
            if (items.size() > NativePolicy.MAX_REMINDERS) throw new IllegalArgumentException("INVALID_REQUEST");
            for (Item item : items) {
                if (!NativePolicy.reminderId(item.id) || !ids.add(item.id) || !NativePolicy.futureTime(item.time, now)) {
                    throw new IllegalArgumentException("INVALID_REQUEST");
                }
            }
            channel();
            LinkedHashSet<String> cleanup = allIds(ledger);
            cleanup.addAll(ids);
            ledger.cleanup = new ArrayList<>(cleanup);
            ledger.recovery = true;
            // Write the union BEFORE OS operations. Failure never loses IDs needed for logout cleanup.
            write(ledger);
            for (String id : cleanup) cancel(id);
            for (Item item : items) schedule(item);
            ledger.items = new ArrayList<>(items);
            ledger.cleanup.clear();
            ledger.recovery = false;
            write(ledger);
            return new JSONObject().put("scheduled", items.size()).put("mode", "inexact").put("limited", false);
        }
    }

    JSONObject clear(String scope) throws IOException, JSONException {
        synchronized (LOCK) {
            Ledger ledger = read();
            if (!ledger.scope.equals(scope)) return status();
            ledger.cleanup = new ArrayList<>(allIds(ledger));
            ledger.enabled = false;
            ledger.recovery = true;
            write(ledger);
            for (String id : ledger.cleanup) cancel(id);
            ledger.items.clear();
            ledger.cleanup.clear();
            ledger.scope = "";
            ledger.recovery = false;
            write(ledger);
            return status();
        }
    }

    /** Boot never restores an interrupted write or a disabled/permission-revoked account. */
    void restoreAfterBoot() throws IOException, JSONException {
        synchronized (LOCK) {
            Ledger ledger = read();
            if (ledger.recovery) {
                for (String id : allIds(ledger)) cancel(id);
                ledger.items.clear();
                ledger.cleanup.clear();
                ledger.recovery = false;
                if (!ledger.enabled) ledger.scope = "";
                write(ledger);
            }
            if (!ledger.enabled || ledger.scope.isEmpty() || !permissionGranted()) return;
            channel();
            long now = System.currentTimeMillis();
            for (Item item : ledger.items) if (NativePolicy.futureTime(item.time, now)) schedule(item);
        }
    }

    void deliver(String id, long fireAt) throws IOException, JSONException {
        synchronized (LOCK) {
            Ledger ledger = read();
            if (!ledger.enabled || ledger.recovery || ledger.scope.isEmpty() || !permissionGranted()) return;
            boolean matches = false;
            for (Item item : ledger.items) if (item.id.equals(id) && item.time == fireAt) matches = true;
            if (!matches || fireAt > System.currentTimeMillis()) return;
            channel();
            Intent open = new Intent(context, EntryEntryAbilityActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            PendingIntent tap = PendingIntent.getActivity(context, 0, open,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            Notification notification = new Notification.Builder(context, CHANNEL)
                    .setSmallIcon(com.campusflow.agent.R.drawable.ic_campusflow_notification)
                    .setContentTitle(NativePolicy.NOTIFICATION_TITLE).setContentText(NativePolicy.NOTIFICATION_BODY)
                    .setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true).setContentIntent(tap).build();
            context.getSystemService(NotificationManager.class).notify("CampusFlow." + id, 0, notification);
        }
    }

    private PendingIntent alarm(String id, long time) {
        Intent intent = new Intent(context, CampusFlowReminderReceiver.class).setAction(ALARM_ACTION)
                .setData(new Uri.Builder().scheme("campusflow").authority("reminder").appendPath(id).build())
                .putExtra("id", id).putExtra("fire_at_ms", time);
        return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private void schedule(Item item) {
        AlarmManager manager = context.getSystemService(AlarmManager.class);
        if (manager == null) throw new IllegalStateException("UNAVAILABLE");
        manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, item.time, alarm(item.id, item.time));
    }

    private void cancel(String id) {
        AlarmManager alarms = context.getSystemService(AlarmManager.class);
        NotificationManager notifications = context.getSystemService(NotificationManager.class);
        if (alarms == null || notifications == null) throw new IllegalStateException("UNAVAILABLE");
        PendingIntent pending = alarm(id, 0);
        alarms.cancel(pending);
        pending.cancel();
        notifications.cancel("CampusFlow." + id, 0);
    }

    private LinkedHashSet<String> allIds(Ledger ledger) {
        LinkedHashSet<String> ids = new LinkedHashSet<>(ledger.cleanup);
        for (Item item : ledger.items) ids.add(item.id);
        return ids;
    }

    private Ledger read() throws IOException, JSONException {
        Ledger ledger = new Ledger();
        if (!file.getBaseFile().exists() && !new File(file.getBaseFile().getPath() + ".bak").exists()) return ledger;
        byte[] bytes = file.readFully();
        if (bytes.length > 131072) throw new IOException("SYSTEM_ERROR");
        JSONObject json = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
        if (json.getInt("v") != 1) throw new IOException("SYSTEM_ERROR");
        ledger.scope = json.getString("scope");
        if (!ledger.scope.isEmpty() && !NativePolicy.scope(ledger.scope)) throw new IOException("SYSTEM_ERROR");
        ledger.enabled = json.getBoolean("enabled");
        ledger.asked = json.getBoolean("asked");
        ledger.recovery = json.getBoolean("recovery");
        JSONArray items = json.getJSONArray("items");
        JSONArray cleanup = json.getJSONArray("cleanup");
        if (items.length() > 60 || cleanup.length() > 120) throw new IOException("SYSTEM_ERROR");
        LinkedHashSet<String> ids = new LinkedHashSet<>();
        for (int i = 0; i < items.length(); i++) {
            JSONObject value = items.getJSONObject(i);
            String id = value.getString("id");
            long time = value.getLong("fire_at_ms");
            if (!NativePolicy.reminderId(id) || !ids.add(id) || time <= 0) throw new IOException("SYSTEM_ERROR");
            ledger.items.add(new Item(id, time));
        }
        for (int i = 0; i < cleanup.length(); i++) {
            String id = cleanup.getString(i);
            if (!NativePolicy.reminderId(id)) throw new IOException("SYSTEM_ERROR");
            ledger.cleanup.add(id);
        }
        return ledger;
    }

    private void write(Ledger ledger) throws IOException, JSONException {
        JSONArray items = new JSONArray();
        for (Item item : ledger.items) items.put(new JSONObject().put("id", item.id).put("fire_at_ms", item.time));
        JSONObject json = new JSONObject().put("v", 1).put("scope", ledger.scope).put("enabled", ledger.enabled)
                .put("asked", ledger.asked).put("recovery", ledger.recovery).put("items", items)
                .put("cleanup", new JSONArray(ledger.cleanup));
        FileOutputStream stream = null;
        try {
            stream = file.startWrite();
            stream.write(json.toString().getBytes(StandardCharsets.UTF_8));
            file.finishWrite(stream);
        } catch (IOException error) {
            if (stream != null) file.failWrite(stream);
            throw error;
        }
    }
}
