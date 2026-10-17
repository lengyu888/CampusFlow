package com.campusflow.agent;

import android.os.Bundle;

import ohos.stage.ability.adapter.StageActivity;


/**
 * Example ace activity class, which will load ArkUI-X ability instance.
 * StageActivity is provided by ArkUI-X
 * @see <a href=
 * "https://gitee.com/arkui-crossplatform/doc/blob/master/contribute/tutorial/how-to-build-Android-app.md">
 * to build android library</a>
 */
public class EntryEntryAbilityActivity extends StageActivity {
    private CampusFlowPlatformBridge platformBridge;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        // Official API11 manager constructor: register before the shared ability starts.
        platformBridge = new CampusFlowPlatformBridge(this, getBridgeManager());
        setInstanceName("com.campusflow.agent:entry:EntryAbility:");
        super.onCreate(savedInstanceState);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (platformBridge != null) platformBridge.onForeground();
    }

    @Override
    protected void onPause() {
        if (platformBridge != null) platformBridge.onPaused();
        super.onPause();
    }

    @Override
    protected void onStop() {
        if (platformBridge != null) platformBridge.onBackground();
        super.onStop();
    }

    @Override
    protected void onDestroy() {
        if (platformBridge != null) platformBridge.onHostDestroy();
        super.onDestroy();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (platformBridge != null) platformBridge.onPermissionResult(requestCode);
    }
}
