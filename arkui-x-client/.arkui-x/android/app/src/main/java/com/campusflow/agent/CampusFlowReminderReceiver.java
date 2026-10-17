package com.campusflow.agent;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Explicit, non-exported alarm target; BOOT_COMPLETED is a protected system broadcast. */
public final class CampusFlowReminderReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null) return;
        CampusFlowReminderStore store = new CampusFlowReminderStore(context);
        try {
            if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
                store.restoreAfterBoot();
            } else if (CampusFlowReminderStore.ALARM_ACTION.equals(intent.getAction())) {
                String id = intent.getStringExtra("id");
                if (NativePolicy.reminderId(id)) store.deliver(id, intent.getLongExtra("fire_at_ms", -1));
            }
        } catch (Exception ignored) {
            // Durable cleanup journal remains; no scope, task, or platform diagnostic is logged.
        }
    }
}
