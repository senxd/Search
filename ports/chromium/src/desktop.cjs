// Electron expects a CommonJS entry; the portable core is ESM.
import('./desktop.js').catch(error => { console.error(error); process.exit(1); });
