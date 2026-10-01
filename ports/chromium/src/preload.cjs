const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('searchHost', Object.freeze({
  execute: request => ipcRenderer.invoke('search:command', request),
  chooseFolder: () => ipcRenderer.invoke('search:choose-folder'),
  shell: options => ipcRenderer.invoke('search:shell', options),
  onShortcut: listener => {
    const handler = (_event, action) => listener(action);
    ipcRenderer.on('search:shortcut', handler);
    return () => ipcRenderer.removeListener('search:shortcut', handler);
  },
}));
