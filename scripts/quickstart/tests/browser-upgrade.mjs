// Real browser upgrade qualification. The parent supplies the mailbox link over
// stdin and upgrades images after the baseline-ready event. Tokens, TOTP secrets,
// recovery codes and authenticator private keys never leave process memory.
import { spawn } from 'node:child_process';
import { createHmac, randomBytes } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const origin = process.env.QS_BROWSER_ORIGIN;
const passwordOnly = process.env.QS_BROWSER_PASSWORD_ONLY === 'true';
const password = 'qualification-disposable-password-1';
const email = `browser-${randomBytes(8).toString('hex')}@example.test`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const messages = [], waiting = [];
createInterface({ input: process.stdin }).on('line', line => {
  const message = JSON.parse(line);
  if (waiting.length) waiting.shift()(message); else messages.push(message);
});
const receive = () => messages.length ? Promise.resolve(messages.shift()) :
  new Promise(resolve => waiting.push(resolve));
const event = (name, extra = {}) => process.stdout.write(JSON.stringify({ event: name, ...extra }) + '\n');
let websocket, chrome;
let totpSecret, lastTotpStep = -1;

async function main() {
  if (!/^https:\/\/localhost:\d+$/.test(origin ?? '')) throw new Error('explicit trusted browser origin required');
  chrome = spawn('chromium', ['--headless=new', '--no-sandbox', '--disable-gpu',
    '--no-first-run', '--remote-debugging-port=0', '--user-data-dir=/tmp/qualification-browser'],
    { stdio: 'ignore' });
  const portFile = '/tmp/qualification-browser/DevToolsActivePort';
  for (let i = 0; i < 100 && !existsSync(portFile); i++) await sleep(100);
  if (!existsSync(portFile)) throw new Error('Chromium debugging endpoint did not start');
  const port = readFileSync(portFile, 'utf8').split('\n')[0];
  const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  websocket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { websocket.onopen = resolve; websocket.onerror = reject; });
  let identifier = 0;
  const diagnostics = [];
  const pending = new Map();
  websocket.onmessage = ({ data }) => {
    const message = JSON.parse(data);
    if (message.method === 'Network.loadingFailed')
      diagnostics.push({ type: message.params.type, error: message.params.errorText });
    if (message.method === 'Network.responseReceived')
      diagnostics.push({ type: message.params.type, status: message.params.response.status,
        mime: message.params.response.mimeType });
    if (diagnostics.length > 30) diagnostics.shift();
    if (message.id && pending.has(message.id)) {
      const { resolve, reject, method } = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(new Error(`browser protocol failure in ${method}`));
      else resolve(message.result);
    }
  };
  const call = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++identifier;
    pending.set(id, { resolve, reject, method });
    websocket.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async (expression, userGesture = false) => {
    const reply = await call('Runtime.evaluate', { expression, userGesture, awaitPromise: true, returnByValue: true });
    if (reply.exceptionDetails) throw new Error('browser evaluation failed');
    return reply.result.value;
  };
  const wait = async (expression, label, timeout = 45000) => {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      try { const result = await evaluate(expression); if (result) return result; } catch {}
      await sleep(200);
    }
    const state = await evaluate(`({path: location.pathname, title: document.title,
      started: typeof window.wasmBindings !== 'undefined', ready: document.readyState})`);
    throw new Error(`browser timed out waiting for ${label}: ${JSON.stringify({state, diagnostics})}`);
  };
  const navigate = async path => {
    await call('Page.navigate', { url: path.startsWith('https:') ? path : origin + path });
    await sleep(200);
  };
  const click = async text => {
    const predicate = `Array.from(document.querySelectorAll('button')).find(b => b.textContent.trim() === ${JSON.stringify(text)} && !b.disabled)`;
    await wait(`Boolean(${predicate})`, 'button ' + text);
    await evaluate(`(${predicate}).click()`, true);
  };
  const fill = (selector, value) => evaluate(`(() => {
    const element = Array.from(document.querySelectorAll(${JSON.stringify(selector)})).at(-1);
    if (!element) throw new Error('missing input');
    element.value = ${JSON.stringify(value)};
    element.dispatchEvent(new Event('input', { bubbles: true }));
  })()`, true);
  const totp = async () => {
    while (Math.floor(Date.now() / 30000) <= lastTotpStep) await sleep(250);
    lastTotpStep = Math.floor(Date.now() / 30000);
    let bits = '';
    for (const character of totpSecret.replace(/=+$/, ''))
      bits += 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(character).toString(2).padStart(5, '0');
    const key = Buffer.from(bits.match(/.{8}/g).map(byte => parseInt(byte, 2)));
    const counter = Buffer.alloc(8); counter.writeBigUInt64BE(BigInt(lastTotpStep));
    const hash = createHmac('sha1', key).update(counter).digest();
    return ((hash.readUInt32BE(hash[19] & 15) & 0x7fffffff) % 1000000).toString().padStart(6, '0');
  };
  const finishChallenge = async () => {
    await wait(`location.pathname.startsWith('/console/')`, 'server-issued session navigation');
    if (await evaluate(`location.pathname.endsWith('/mfa/challenge')`)) {
      await wait(`Boolean(document.querySelector('input[type=text]'))`, 'MFA challenge');
      await fill('input[type=text]', await totp());
      await click('Verify');
    }
    await wait(`location.pathname.endsWith('/dashboard')`, 'full authenticated session');
  };
  const passwordLogin = async () => {
    await navigate('/login');
    await wait(`Boolean(document.querySelector('#email'))`, 'password login form');
    await fill('#email', email);
    await click('Use password instead');
    await fill('#password', password);
    await click('Continue with password');
    await wait(`location.pathname.startsWith('/console/')`, 'OPAQUE login');
  };

  await call('Page.enable');
  await call('Network.enable');
  await call('Network.setCacheDisabled', { cacheDisabled: true });
  await call('WebAuthn.enable');
  const { authenticatorId } = await call('WebAuthn.addVirtualAuthenticator', { options: {
    protocol: 'ctap2', transport: 'internal', hasResidentKey: true,
    hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true,
  }});
  await navigate('/signup');
  await wait(`Boolean(document.querySelector('#confirm_password'))`, 'trusted frontend WASM');
  await fill('#email', email); await fill('#password', password); await fill('#confirm_password', password);
  await evaluate(`document.querySelector('form').requestSubmit()`, true);
  await wait(`document.body.innerText.includes('Check your email to verify your account.')`, 'real OPAQUE signup');
  event('account-created', { email });
  const verification = await receive();
  await navigate(verification.verifyUrl);
  await wait(`document.body.innerText.includes('Email verified. You can sign in now.')`, 'mailbox verification');
  await passwordLogin();
  if (!await evaluate(`location.pathname.endsWith('/mfa/setup')`))
    await navigate('/console/mfa/setup');
  await wait(`/Secret:\\s*([A-Z2-7]+)/.test(document.body.innerText)`, 'MFA enrollment');
  totpSecret = await evaluate(`document.body.innerText.match(/Secret:\\s*([A-Z2-7]+)/)[1]`);
  await fill('input[type=text]', await totp());
  await click('Verify and Enable');
  await click("I've saved my codes - Continue");
  await wait(`location.pathname.endsWith('/dashboard')`, 'recovery-code acknowledgement');
  await navigate('/console/me/security');
  await wait(`document.body.innerText.includes('Create passkey')`, 'passkey settings');
  await sleep(1200);
  await click('Create passkey');
  await wait(`document.body.innerText.includes('Passkey created.')`, 'stored browser passkey');
  const baseline = await call('WebAuthn.getCredentials', { authenticatorId });
  if (baseline.credentials.length !== 1) throw new Error('baseline passkey was not registered');
  if (!passwordOnly && !baseline.credentials[0].isResidentCredential)
    throw new Error('published baseline registered a nonresident credential; discoverable passkey upgrade qualification is blocked');
  const credentialId = baseline.credentials[0].credentialId;
  const cookies = await call('Network.getCookies', { urls: [origin] });
  if (!cookies.cookies.some(cookie => cookie.httpOnly && cookie.secure && cookie.sameSite === 'Lax'))
    throw new Error('secure HttpOnly SameSite=Lax session missing');
  event('baseline-ready', { email });
  await receive();

  await call('Network.clearBrowserCookies');
  await passwordLogin();
  await finishChallenge();
  event('password-upgrade-passed');
  if (passwordOnly) return;
  await call('Network.clearBrowserCookies');
  await navigate('/login');
  await wait(`Boolean(document.querySelector('#email'))`, 'upgraded passkey login form');
  await click('Use passkey');
  await finishChallenge();
  const upgraded = await call('WebAuthn.getCredentials', { authenticatorId });
  if (upgraded.credentials.length !== 1 || upgraded.credentials[0].credentialId !== credentialId ||
      upgraded.credentials[0].signCount <= baseline.credentials[0].signCount)
    throw new Error('existing passkey did not authenticate after upgrade');
  event('passkey-upgrade-passed');
}

try { await main(); }
catch (error) { console.error(error.message); process.exitCode = 1; }
finally { websocket?.close(); chrome?.kill('SIGTERM'); process.exit(process.exitCode ?? 0); }
