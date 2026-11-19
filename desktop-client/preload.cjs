const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('campusFlowConnection', {
  address: () => ipcRenderer.invoke('launcher:address'),
  connect: (address) => ipcRenderer.invoke('launcher:connect', address),
});
