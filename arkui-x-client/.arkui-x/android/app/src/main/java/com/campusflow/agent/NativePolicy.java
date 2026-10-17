package com.campusflow.agent;

import java.util.ArrayList;
import java.util.List;

/** Platform-independent bounds; no task titles or account values enter notifications. */
final class NativePolicy {
    static final int MAX_REMINDERS = 60;
    static final long HORIZON_MS = 366L * 24 * 60 * 60 * 1000;
    static final String NOTIFICATION_TITLE = "行简提醒";
    static final String NOTIFICATION_BODY = "你有一项安排即将开始，打开应用查看。";

    private NativePolicy() { }

    static boolean requestId(String value) {
        return value != null && value.matches("[\\x21-\\x7E]{1,128}");
    }

    static boolean reminderId(String value) {
        return value != null && value.matches("[A-Za-z0-9._-]{1,180}");
    }

    static boolean scope(String value) {
        if (value == null || value.isEmpty() || value.length() > 512) return false;
        for (int i = 0; i < value.length(); i++) {
            if (Character.isISOControl(value.charAt(i))) return false;
        }
        return true;
    }

    static boolean futureTime(long value, long now) {
        return value > now && value - now <= HORIZON_MS;
    }

    static List<String> speechChunks(String text, int limit) {
        if (text == null || text.isEmpty() || text.length() > 32000 || limit < 2) {
            throw new IllegalArgumentException("INVALID_REQUEST");
        }
        ArrayList<String> result = new ArrayList<>();
        int start = 0;
        while (start < text.length()) {
            int end = Math.min(start + limit, text.length());
            if (end < text.length() && Character.isHighSurrogate(text.charAt(end - 1))
                    && Character.isLowSurrogate(text.charAt(end))) end--;
            result.add(text.substring(start, end));
            start = end;
        }
        return result;
    }
}
