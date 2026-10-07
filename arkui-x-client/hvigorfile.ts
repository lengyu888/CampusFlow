// DevEco Studio 6.1 records the ArkUI-X SDK location in its own settings, but
// HarmonyOS-mode Hvigor builds expect the SDK locations as environment
// variables. Supply portable Windows defaults before loading the ArkUI-X
// plugin so IDE sync also works when those variables were not inherited.
if (process.platform === 'win32') {
  if (!process.env.ARKUIX_SDK_HOME && process.env.LOCALAPPDATA) {
    process.env.ARKUIX_SDK_HOME = `${process.env.LOCALAPPDATA}\\ArkUI-X\\Sdk`;
  }
  if (!process.env.DEVECO_SDK_HOME && process.env.ProgramFiles) {
    process.env.DEVECO_SDK_HOME = `${process.env.ProgramFiles}\\Huawei\\DevEco Studio\\sdk`;
  }
}

// A static re-export is evaluated before the code above, so load the plugin
// only after the environment has been prepared.
const arkUIXPlugin = require('@ohos/hvigor-ohos-arkui-x-plugin');
export const AppTasksForArkUIX = arkUIXPlugin.AppTasksForArkUIX;
