package com.campusflow.agent;

import java.util.List;

/** Exercises the production helper when a JDK already exists; needs no Android SDK/dependencies. */
public final class NativePolicyTest {
    private static int assertions;
    private static void check(boolean condition, String label) {
        assertions++;
        if (!condition) throw new AssertionError(label);
    }
    private static String repeat(String value, int count) {
        StringBuilder result = new StringBuilder();
        for (int i = 0; i < count; i++) result.append(value);
        return result.toString();
    }
    public static void main(String[] args) {
        check(NativePolicy.requestId("run-1.a_1"), "request id");
        check(!NativePolicy.requestId(""), "empty request");
        check(!NativePolicy.requestId("request\n1"), "control request");
        check(!NativePolicy.requestId("请求"), "non ASCII request");
        check(NativePolicy.requestId(repeat("a", 128)), "128 request");
        check(!NativePolicy.requestId(repeat("a", 129)), "129 request");
        check(NativePolicy.reminderId("scope.task-1_2"), "reminder id");
        check(!NativePolicy.reminderId("../path/1"), "path reminder");
        check(!NativePolicy.reminderId("task:1"), "non-whitelist reminder");
        check(!NativePolicy.reminderId(repeat("a", 181)), "oversize reminder");
        check(NativePolicy.scope("https://campusflow.example|local-user"), "scope");
        check(!NativePolicy.scope(""), "empty scope");
        check(!NativePolicy.scope("account\u0000token"), "control scope");
        check(!NativePolicy.scope(repeat("a", 513)), "oversize scope");
        long now = 1800000000000L;
        check(!NativePolicy.futureTime(now, now), "past trigger");
        check(!NativePolicy.futureTime(now - 1, now), "past time");
        check(NativePolicy.futureTime(now + 1, now), "next millisecond");
        check(NativePolicy.futureTime(now + NativePolicy.HORIZON_MS, now), "horizon inclusive");
        check(!NativePolicy.futureTime(now + NativePolicy.HORIZON_MS + 1, now), "over horizon");
        check(!NativePolicy.futureTime(Long.MAX_VALUE, now), "huge epoch");
        check(!NativePolicy.futureTime(Long.MIN_VALUE, now), "negative overflow");
        String text = repeat("中文😀abc", 2500);
        List<String> chunks = NativePolicy.speechChunks(text, 4000);
        StringBuilder restored = new StringBuilder();
        for (String chunk : chunks) {
            check(chunk.length() <= 4000 && !chunk.isEmpty(), "tts length");
            check(!Character.isHighSurrogate(chunk.charAt(chunk.length() - 1)), "surrogate end");
            check(!Character.isLowSurrogate(chunk.charAt(0)), "surrogate start");
            restored.append(chunk);
        }
        check(restored.toString().equals(text), "no truncation or duplication");
        check(NativePolicy.speechChunks("a😀b", 2).size() == 3, "tiny Unicode boundary");
        check(String.join("", NativePolicy.speechChunks(repeat("a", 32000), 4000)).length() == 32000, "max input");
        boolean rejected = false;
        try { NativePolicy.speechChunks(repeat("a", 32001), 4000); } catch (IllegalArgumentException expected) { rejected = true; }
        check(rejected, "reject overlong text");
        System.out.println("NativePolicy: " + assertions + " assertions passed (pure Java only)");
    }
}
