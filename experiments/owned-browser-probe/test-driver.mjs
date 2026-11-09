// Independent fixture observer/simulated human. Never used by agent tools.
// Attaches ONLY to the third disposable tab; it does not attach to agent tabs.
export async function connectHumanFixture(endpoint, url) {
  const targets = await (await fetch(`${endpoint}/json/list`)).json();
  const target = targets.find(
    (entry) => entry.type === "page" && entry.url === url,
  );
  if (!target) throw new Error("Human fixture target not found");
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  const pending = new Map();
  let next = 0;
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    const entry = pending.get(message.id);
    if (!entry) return;
    clearTimeout(entry.timeout);
    pending.delete(message.id);
    if (message.error) entry.reject(new Error(message.error.message));
    else entry.resolve(message.result);
  });
  socket.addEventListener("close", () => {
    for (const entry of pending.values()) {
      clearTimeout(entry.timeout);
      entry.reject(new Error("Test observer disconnected"));
    }
    pending.clear();
  });
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  function call(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++next;
      const timeout = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`Observer timeout: ${method}`));
      }, 5000);
      pending.set(id, { resolve, reject, timeout });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async function state() {
    const reply = await call("Runtime.evaluate", {
      expression:
        "({url:location.href, visible:document.visibilityState, focused:document.hasFocus(), value:document.querySelector('input').value, caret:document.querySelector('input').selectionStart})",
      returnByValue: true,
    });
    return reply.result.value;
  }
  return {
    state,
    async type(text) {
      await call("Runtime.evaluate", {
        expression: "document.querySelector('input').focus()",
      });
      for (const character of text) {
        await call("Input.insertText", { text: character });
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      return state();
    },
    async closeTab() {
      await call("Page.close");
    },
    close() {
      socket.close();
    },
  };
}
