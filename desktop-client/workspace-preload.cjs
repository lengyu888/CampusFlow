const { contextBridge, ipcRenderer } = require('electron');

if (process.isMainFrame && process.argv.includes(`--campusflow-origin=${location.origin}`)) {
  contextBridge.exposeInMainWorld('campusFlowDesktop', {
    session: (token, remember) => ipcRenderer.invoke('workspace:session', token, remember),
    clear: () => ipcRenderer.invoke('workspace:clear'),
    historyUseOwner: (owner) => ipcRenderer.invoke('workspace:history-use-owner', owner),
    historyList: () => ipcRenderer.invoke('workspace:history-list'),
    historyGet: (owner, sessionId) => ipcRenderer.invoke('workspace:history-get', owner, sessionId),
    historySave: (owner, value) => ipcRenderer.invoke('workspace:history-save', owner, value),
    historyDelete: (owner, sessionId) => ipcRenderer.invoke('workspace:history-delete', owner, sessionId),
    historyClear: () => ipcRenderer.invoke('workspace:history-clear'),
    voiceStart: (operation) => ipcRenderer.invoke('workspace:voice-start', operation),
    voiceStop: () => ipcRenderer.invoke('workspace:voice-stop'),
    voiceCancel: () => ipcRenderer.invoke('workspace:voice-cancel'),
    onVoiceEvent: (callback) => {
      if (typeof callback === 'function') ipcRenderer.on('workspace:voice-event', (_event, data) => callback(data));
    },
    reminders: (entries, background) => ipcRenderer.invoke('workspace:reminders', entries, background),
    openKnowledgeSource: (address) => ipcRenderer.invoke('workspace:knowledge-source', address),
    onReminder: (callback) => {
      if (typeof callback === 'function') ipcRenderer.on('workspace:reminder-due', (_event, title) => callback(title));
    },
  });
}
