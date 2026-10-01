export function installNativeShim() {
  if (!globalThis.chrome?.runtime || !globalThis.searchNativeHost) return;
  const event = () => {
    const listeners = new Set();
    return { addListener: listener => listeners.add(listener), removeListener: listener => listeners.delete(listener), hasListener: listener => listeners.has(listener), emit: (...args) => { for (const listener of listeners) listener(...args); } };
  };
  chrome.runtime.connectNative = host => {
    let closed = false; let timer;
    const port = { name: host, onMessage: event(), onDisconnect: event() };
    const connected = searchNativeHost.invoke({ do: 'native-connect', host });
    const end = error => { if (closed) return; closed = true; clearInterval(timer); port.error = error || null; port.onDisconnect.emit(port); };
    connected.then(({ id }) => {
      if (closed) { searchNativeHost.invoke({ do: 'native-disconnect', connection: id }); return; }
      timer = setInterval(async () => {
        try {
          const result = await searchNativeHost.invoke({ do: 'native-poll', connection: id });
          for (const message of result.messages) port.onMessage.emit(message, port);
          if (result.closed) end(result.error);
        } catch (error) { end(error.message); }
      }, 100);
    }).catch(error => end(error.message));
    port.postMessage = message => connected.then(({ id }) => {
      if (closed) throw new Error('Native port is disconnected');
      return searchNativeHost.invoke({ do: 'native-post', connection: id, message });
    }).catch(error => end(error.message));
    port.disconnect = () => { end(); connected.then(({ id }) => searchNativeHost.invoke({ do: 'native-disconnect', connection: id })).catch(() => {}); };
    return port;
  };
  chrome.runtime.sendNativeMessage = (host, message, callback) => {
    const result = new Promise((resolve, reject) => {
      const port = chrome.runtime.connectNative(host);
      let timeout;
      port.onMessage.addListener(message => { clearTimeout(timeout); resolve(message); port.disconnect(); });
      port.onDisconnect.addListener(() => { if (port.error) { clearTimeout(timeout); reject(new Error(port.error)); } });
      port.postMessage(message);
      timeout = setTimeout(() => { port.disconnect(); reject(new Error('Native host did not reply')); }, 30000);
    });
    if (callback) { result.then(value => callback(value)).catch(() => callback()); return; }
    return result;
  };
}
