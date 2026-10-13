// Launches mcpdemo's Streamable HTTP binding (`--http <port>`) on a free
// localhost port and resolves once the listener accepts connections.
// Shared by http-interop.mjs and tools/conformance/run.mjs; Node
// built-ins only, so callers need no npm install.

import { spawn } from 'node:child_process';
import { createServer, connect } from 'node:net';

// Ask the kernel for a free port, release it, hand it to mcpdemo.
export function freePort() {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.listen(0, '127.0.0.1', () => {
      const port = probe.address().port;
      probe.close(() => resolve(port));
    });
    probe.on('error', reject);
  });
}

// One connect attempt; resolves to whether the port accepted it.
function canConnect(port) {
  return new Promise((resolve) => {
    const socket = connect({ host: '127.0.0.1', port });
    const settle = (ok) => {
      socket.destroy();
      resolve(ok);
    };
    socket.once('connect', () => settle(true));
    socket.once('error', () => settle(false));
    socket.setTimeout(250, () => settle(false));
  });
}

// mcpdemo prints its banner BEFORE the listener binds, so the banner
// alone is not readiness: poll the port until a connection is accepted.
async function waitUntilListening(port, timeoutMs = 5000, intervalMs = 50) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (await canConnect(port)) return;
    if (Date.now() >= deadline)
      throw new Error(`mcpdemo never listened on 127.0.0.1:${port}`);
    await new Promise((resume) => setTimeout(resume, intervalMs));
  }
}

export function startDemo(demo, port) {
  return new Promise((resolve, reject) => {
    const child = spawn(demo, ['--http', String(port)], {
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    const timer = setTimeout(
      () => reject(new Error('mcpdemo startup timed out')),
      10000,
    );
    let banner = '';
    const onData = (chunk) => {
      banner += chunk.toString();
      if (!banner.includes('http://127.0.0.1:')) return;
      child.stderr.off('data', onData);
      waitUntilListening(port).then(
        () => {
          clearTimeout(timer);
          resolve(child);
        },
        (error) => {
          clearTimeout(timer);
          reject(error);
        },
      );
    };
    child.stderr.on('data', onData);
    child.on('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`mcpdemo exited early (code ${code})`));
    });
  });
}
