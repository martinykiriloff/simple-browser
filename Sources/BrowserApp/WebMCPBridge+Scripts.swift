import Foundation

/// The two scripts of the WebMCP bridge, kept in Swift so the package needs
/// no resources for them.
extension WebMCPBridge {

    /// Runs in the `KeelWebMCP` world: takes the page shim's nonce, forwards
    /// registrations to native code, and runs tools on native code's behalf.
    static let relaySource = #"""
    (() => {
      'use strict';
      if (window.top !== window || window.__keelWebMCP) return;
      const post = (message) => { try { webkit.messageHandlers.keelWebMCP.postMessage(message); } catch (_) {} };
      let nonce = null;
      let sequence = 0;
      const pending = new Map();
      const onHello = (event) => {
        if (nonce !== null || typeof event.detail !== 'string' || !/^[0-9a-f]{32}$/.test(event.detail)) return;
        nonce = event.detail;
        document.removeEventListener('keel-webmcp-hello', onHello, true);
        document.dispatchEvent(new CustomEvent(`keel-webmcp-${nonce}-ack`));
        document.addEventListener(`keel-webmcp-${nonce}-up`, (up) => {
          let message;
          try { message = JSON.parse(String(up.detail)); } catch (_) { return; }
          if (!message || typeof message !== 'object') return;
          if (message.kind === 'result') {
            const resolve = pending.get(message.id);
            if (resolve) { pending.delete(message.id); resolve(message); }
            return;
          }
          if (message.kind === 'register' && typeof message.tool === 'string') post({ kind: 'register', tool: message.tool });
          else if (message.kind === 'unregister' && typeof message.name === 'string') post({ kind: 'unregister', name: message.name });
          else if (message.kind === 'clear') post({ kind: 'clear' });
        }, true);
      };
      // Said by the page shim at document start, before any page script runs.
      // WebKit does not promise which world's scripts run first, so the
      // relay also says it is ready, and the shim says hello again then.
      document.addEventListener('keel-webmcp-hello', onHello, true);
      document.dispatchEvent(new CustomEvent('keel-webmcp-ready'));

      window.__keelWebMCP = {
        run(name, args, timeout) {
          if (nonce === null) return Promise.resolve({ ok: false, error: 'This page has no WebMCP tools.' });
          const id = ++sequence;
          return new Promise((resolve) => {
            const timer = setTimeout(() => { pending.delete(id); resolve({ ok: false, timeout: true, error: 'timed out' }); }, timeout);
            pending.set(id, (message) => {
              clearTimeout(timer);
              resolve(message.ok ? { ok: true, value: String(message.value ?? '') } : { ok: false, error: String(message.error ?? 'failed') });
            });
            document.dispatchEvent(new CustomEvent(`keel-webmcp-${nonce}-down`, { detail: JSON.stringify({ id, name, args }) }));
          });
        },
      };
    })();
    """#

    /// Runs in the page's own world: `document.modelContext` and
    /// `navigator.modelContext`. Tools' `execute` functions never leave it.
    /// Builtins are captured first, so a page script patching them later
    /// cannot read the nonce off the shim's calls.
    static let pageSource = #"""
    (() => {
      'use strict';
      if (window.top !== window || !window.isSecureContext || 'modelContext' in document) return;
      const apply = Reflect.apply;
      const dispatch = EventTarget.prototype.dispatchEvent;
      const listen = EventTarget.prototype.addEventListener;
      const unlisten = EventTarget.prototype.removeEventListener;
      const Custom = CustomEvent;
      const stringify = JSON.stringify;
      const parse = JSON.parse;
      const ObjectFreeze = Object.freeze;
      const define = Object.defineProperty;
      const isArray = Array.isArray;
      const Abort = AbortController;
      const DOMEx = DOMException;
      const MapCtor = Map;
      const mapGet = Map.prototype.get, mapSet = Map.prototype.set, mapHas = Map.prototype.has, mapDelete = Map.prototype.delete;
      const mapClear = Map.prototype.clear, mapValues = Map.prototype.values;
      const PromiseCtor = Promise;
      const resolved = (v) => apply(Promise.resolve, PromiseCtor, [v]);
      const rejected = (e) => apply(Promise.reject, PromiseCtor, [e]);
      const doc = document;
      const MAX_RESULT = 100 * 1024;

      const bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      let nonce = '';
      for (let i = 0; i < bytes.length; i++) nonce += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
      const send = (message) => apply(dispatch, doc, [new Custom(`keel-webmcp-${nonce}-up`, { detail: stringify(message) })]);
      const hello = () => apply(dispatch, doc, [new Custom('keel-webmcp-hello', { detail: nonce })]);
      // Whichever of the shim and the relay runs first, both run before any
      // page script: the relay acknowledges with an event only the nonce
      // names, and from then on nothing answers a "ready" a page might fake.
      const onReady = () => hello();
      const onAck = () => {
        apply(unlisten, doc, ['keel-webmcp-ready', onReady, true]);
        apply(unlisten, doc, [`keel-webmcp-${nonce}-ack`, onAck, true]);
      };
      apply(listen, doc, ['keel-webmcp-ready', onReady, true]);
      apply(listen, doc, [`keel-webmcp-${nonce}-ack`, onAck, true]);
      hello();

      const tools = new MapCtor();

      const describe = (tool) => {
        let schema;
        try { schema = tool.inputSchema === undefined ? undefined : parse(stringify(tool.inputSchema)); } catch (_) { schema = undefined; }
        const a = (tool.annotations && typeof tool.annotations === 'object') ? tool.annotations : {};
        const annotations = {};
        for (const key of ['readOnlyHint', 'consequentialHint', 'untrustedContentHint']) {
          if (typeof a[key] === 'boolean') annotations[key] = a[key];
        }
        return {
          name: String(tool.name),
          title: tool.title === undefined ? undefined : String(tool.title),
          description: String(tool.description ?? ''),
          inputSchema: schema,
          annotations,
        };
      };

      const add = (tool, options, replace) => {
        if (!tool || typeof tool !== 'object' || typeof tool.name !== 'string' || !tool.name || typeof tool.execute !== 'function') {
          throw new TypeError('registerTool needs { name, description, execute }');
        }
        const name = tool.name;
        if (!replace && apply(mapHas, tools, [name])) throw new DOMEx(`A tool named "${name}" is already registered.`, 'InvalidStateError');
        const signal = options && options.signal;
        if (signal && signal.aborted) return;
        const metadata = describe(tool);
        const entry = { metadata, execute: tool.execute, tool };
        apply(mapSet, tools, [name, entry]);
        send({ kind: 'register', tool: stringify(metadata) });
        if (signal && typeof signal.addEventListener === 'function') {
          signal.addEventListener('abort', () => { if (apply(mapGet, tools, [name]) === entry) remove(name); }, { once: true });
        }
      };

      const remove = (name) => {
        name = String(name);
        if (!apply(mapDelete, tools, [name])) return;
        send({ kind: 'unregister', name });
      };

      const clear = () => {
        apply(mapClear, tools, []);
        send({ kind: 'clear' });
      };

      const serialize = (value) => {
        if (value === undefined || value === null) return '';
        if (typeof value === 'string') return value;
        // The earlier drafts' MCP-shaped result: { content: [{ type: 'text', text }] }.
        if (typeof value === 'object' && isArray(value.content)) {
          const texts = [];
          for (const part of value.content) if (part && part.type === 'text') texts.push(String(part.text ?? ''));
          if (texts.length) return texts.join('\n');
        }
        const text = stringify(value);
        return text === undefined ? String(value) : text;
      };

      const modelContext = {
        registerTool(tool, options = {}) {
          try { add(tool, options, false); return resolved(undefined); } catch (error) { return rejected(error); }
        },
        unregisterTool(name) { remove(name); },
        provideContext(context = {}) {
          const list = context && isArray(context.tools) ? context.tools : [];
          clear();
          for (const tool of list) add(tool, {}, true);
        },
        clearContext() { clear(); },
        getTools() {
          const list = [];
          for (const entry of apply(mapValues, tools, [])) list.push({ ...entry.metadata, origin: location.origin, window });
          return resolved(list);
        },
      };
      ObjectFreeze(modelContext);
      define(document, 'modelContext', { value: modelContext, enumerable: true });
      try { define(navigator, 'modelContext', { value: modelContext, enumerable: true }); } catch (_) {}

      // A call from an agent, through the relay.
      apply(listen, doc, [`keel-webmcp-${nonce}-down`, async (event) => {
        let request;
        try { request = parse(String(event.detail)); } catch (_) { return; }
        const reply = (fields) => send({ kind: 'result', id: request.id, ...fields });
        const entry = apply(mapGet, tools, [String(request.name)]);
        if (!entry) { reply({ ok: false, error: `No tool named ${request.name} is registered.` }); return; }
        let args;
        try { args = parse(String(request.args || '{}')); } catch (_) { args = {}; }
        const controller = new Abort();
        try {
          const value = await apply(entry.execute, entry.tool, [args, {
            signal: controller.signal,
            // Earlier drafts: the person is at the browser, so the page may ask them.
            requestUserInteraction: async (callback) => callback(),
          }]);
          let text = serialize(value);
          if (text.length > MAX_RESULT) text = text.slice(0, MAX_RESULT) + '\n… (cut at 100 KB)';
          reply({ ok: true, value: text });
        } catch (error) {
          let message;
          try { message = String((error && error.message) || error); } catch (_) { message = 'error'; }
          reply({ ok: false, error: message.slice(0, 2000) });
        }
      }, true]);

      // Back from the back-forward cache: the commit cleared this page's tools.
      apply(listen, window, ['pageshow', (event) => {
        if (!event.persisted) return;
        for (const entry of apply(mapValues, tools, [])) send({ kind: 'register', tool: stringify(entry.metadata) });
      }]);
    })();
    """#
}
