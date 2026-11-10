import { config } from "./config.js";

// One lease/queue owner, next to the CDP transport. Nothing is durable.
// This prototype admits only its disposable fixture origin, not arbitrary sites.
const leases = new Map();
const stoppedOwners = new Set();
let port;
let resetting = Promise.resolve();

function allowed(url) {
  try {
    return new URL(url).origin === config.origin;
  } catch {
    return false;
  }
}
function assertOwner(owner) {
  if (typeof owner !== "string" || stoppedOwners.has(owner))
    throw new Error("Owner stopped");
}
function invalidate(lease) {
  lease.revision++;
  lease.refs.clear();
}
function emit(message) {
  try {
    port?.postMessage(message);
  } catch {
    /* disconnect handler revokes leases */
  }
}
async function release(lease, reason) {
  if (!lease.active) return lease.cleanup;
  lease.active = false; // Before any await: queued work must fail immediately.
  invalidate(lease);
  clearTimeout(lease.media?.pending?.timer);
  lease.media = undefined;
  emit({ event: "revoked", tabId: lease.tabId, target: lease.target, reason });
  // Retain the reservation until detach finishes; a new owner cannot race it.
  lease.cleanup = (async () => {
    // Stop can arrive during attachment. Do not leave a late attachment orphaned.
    await lease.attaching?.catch(() => {});
    try {
      await chrome.debugger.detach({ tabId: lease.tabId });
    } catch {
      /* already detached */
    }
    if (leases.get(lease.tabId) === lease) leases.delete(lease.tabId);
    await chrome.action
      .setBadgeText({ tabId: lease.tabId, text: "" })
      .catch(() => {});
  })();
  return lease.cleanup;
}
function guard(lease, revision) {
  assertOwner(lease.owner);
  if (!lease.active || leases.get(lease.tabId) !== lease)
    throw new Error("Target revoked; reclaim and observe");
  if (revision !== undefined && revision !== lease.revision)
    throw new Error("Stale observation; observe again");
}
async function cdp(lease, method, params = {}, revision) {
  guard(lease, revision);
  const tab = await chrome.tabs.get(lease.tabId);
  guard(lease, revision);
  if (!allowed(tab.url)) {
    void release(lease, "outside fixture origin");
    throw new Error("Target left permitted origin");
  }
  emit({ event: "dispatch", tabId: lease.tabId, method });
  return chrome.debugger.sendCommand({ tabId: lease.tabId }, method, params);
}
async function claim(owner, tabId) {
  assertOwner(owner);
  if (!Number.isInteger(tabId)) throw new Error("Invalid tab ID");
  const tab = await chrome.tabs.get(tabId);
  assertOwner(owner);
  if (!allowed(tab.url))
    throw new Error("Only the disposable fixture origin is allowed");
  if (leases.has(tabId))
    throw new Error("Tab already claimed; release it first");
  const lease = {
    tabId,
    owner,
    target: crypto.randomUUID(),
    revision: 0,
    refs: new Map(),
    active: true,
    queue: Promise.resolve(),
  };
  leases.set(tabId, lease);
  try {
    lease.attaching = chrome.debugger.attach({ tabId }, "1.3");
    await lease.attaching;
    await cdp(lease, "Page.enable");
    await cdp(lease, "DOM.enable");
    await cdp(lease, "Accessibility.enable");
    // Headed Chrome accepted mouse commands without delivering clicks until this
    // was enabled. Emulates page focus/visibility without activating the Mac tab.
    await cdp(lease, "Emulation.setFocusEmulationEnabled", { enabled: true });
    await chrome.action.setBadgeText({ tabId, text: "ON" });
    await chrome.action.setTitle({
      tabId,
      title: `Probe owner ${owner.slice(0, 8)} — click to stop this tab`,
    });
    guard(lease);
    return { target: lease.target, tabId, url: tab.url };
  } catch (error) {
    await release(lease, "claim failed");
    throw error;
  }
}
function targetFor(owner, target) {
  assertOwner(owner);
  const lease = [...leases.values()].find(
    (entry) => entry.target === target && entry.owner === owner,
  );
  if (!lease)
    throw new Error("Unknown target for this owner; reclaim and observe");
  guard(lease);
  return lease;
}
function serialize(lease, action) {
  const queuedRevision = lease.revision;
  const result = lease.queue
    .catch(() => {})
    .then(() => {
      guard(lease, queuedRevision);
      return action();
    });
  lease.queue = result.catch(() => {});
  return result;
}
async function observe(lease) {
  const revision = lease.revision;
  const { nodes } = await cdp(
    lease,
    "Accessibility.getFullAXTree",
    {},
    revision,
  );
  guard(lease, revision);
  lease.refs.clear();
  const observation = crypto.randomUUID().slice(0, 8);
  const elements = nodes
    .filter(
      (node) =>
        !node.ignored &&
        (node.name?.value ||
          node.value?.value ||
          node.role?.value === "textbox"),
    )
    .slice(0, 400)
    .map((node, index) => {
      const ref = `${observation}:${revision}:${index}`;
      if (node.backendDOMNodeId)
        lease.refs.set(ref, { backendNodeId: node.backendDOMNodeId, revision });
      return {
        ...(node.backendDOMNodeId ? { ref } : {}),
        role: node.role?.value,
        name: node.name?.value,
        value: node.value?.value,
      };
    });
  return {
    target: lease.target,
    tabId: lease.tabId,
    revision,
    elements,
    truncated: nodes.length > 400,
    frameScope: "main document only",
  };
}
async function withRef(lease, ref, action) {
  const element = lease.refs.get(ref);
  if (!element) throw new Error("Stale or unknown ref; observe again");
  guard(lease, element.revision);
  return action(element);
}
async function click(lease, ref) {
  return withRef(lease, ref, async ({ backendNodeId, revision }) => {
    await cdp(lease, "DOM.scrollIntoViewIfNeeded", { backendNodeId }, revision);
    const { quads } = await cdp(
      lease,
      "DOM.getContentQuads",
      { backendNodeId },
      revision,
    );
    if (!quads?.length) throw new Error("Element has no clickable quad");
    const q = quads[0];
    const x = (q[0] + q[2] + q[4] + q[6]) / 4;
    const y = (q[1] + q[3] + q[5] + q[7]) / 4;
    // Do not silently click a covering element if the layout changed since AX.
    const { object } = await cdp(
      lease,
      "DOM.resolveNode",
      { backendNodeId },
      revision,
    );
    try {
      const hit = await cdp(
        lease,
        "Runtime.callFunctionOn",
        {
          objectId: object.objectId,
          functionDeclaration:
            "function(x,y) { const hit = document.elementFromPoint(x,y); return this === hit || this.contains(hit); }",
          arguments: [{ value: x }, { value: y }],
          returnByValue: true,
        },
        revision,
      );
      if (hit.exceptionDetails || hit.result?.value !== true)
        throw new Error(
          "Element is covered or outside viewport; observe again",
        );
    } finally {
      if (lease.active)
        void chrome.debugger
          .sendCommand({ tabId: lease.tabId }, "Runtime.releaseObject", {
            objectId: object.objectId,
          })
          .catch(() => {});
    }
    await cdp(
      lease,
      "Input.dispatchMouseEvent",
      { type: "mousePressed", x, y, button: "left", clickCount: 1 },
      revision,
    );
    await cdp(
      lease,
      "Input.dispatchMouseEvent",
      { type: "mouseReleased", x, y, button: "left", clickCount: 1 },
      revision,
    );
    return { dispatched: true, effects: "Verify with a fresh observation" };
  });
}
async function fill(lease, ref, text) {
  if (typeof text !== "string" || text.length > 4096)
    throw new Error("Text must be at most 4096 characters");
  return withRef(lease, ref, async ({ backendNodeId, revision }) => {
    const { object } = await cdp(
      lease,
      "DOM.resolveNode",
      { backendNodeId },
      revision,
    );
    try {
      // Only our fixed implementation runs script; callers cannot supply JS.
      const selected = await cdp(
        lease,
        "Runtime.callFunctionOn",
        {
          objectId: object.objectId,
          functionDeclaration:
            "function() { if (!(this instanceof HTMLInputElement || this instanceof HTMLTextAreaElement) || this.disabled || this.readOnly) throw new Error('Not an editable input'); this.focus(); this.select(); return document.activeElement === this; }",
          returnByValue: true,
        },
        revision,
      );
      if (selected.exceptionDetails || selected.result?.value !== true)
        throw new Error("Input could not be selected");
      await cdp(lease, "Input.insertText", { text }, revision);
      return { dispatched: true, effects: "Verify with a fresh observation" };
    } finally {
      // Resource cleanup only, never input after revocation.
      if (lease.active)
        void chrome.debugger
          .sendCommand({ tabId: lease.tabId }, "Runtime.releaseObject", {
            objectId: object.objectId,
          })
          .catch(() => {});
    }
  });
}

async function handle(owner, tool, args) {
  if (tool === "browser_stop") {
    stoppedOwners.add(owner);
    await Promise.all(
      [...leases.values()]
        .filter((lease) => lease.owner === owner)
        .map((lease) => release(lease, "owner stopped")),
    );
    return {
      stopped: true,
      effects:
        "Already dispatched input cannot be undone; queued input revoked. Connect a new client to resume.",
    };
  }
  assertOwner(owner);
  if (tool === "browser_tabs") {
    return (await chrome.tabs.query({}))
      .filter((tab) => allowed(tab.url))
      .map((tab) => ({
        tabId: tab.id,
        url: tab.url,
        title: tab.title,
        active: tab.active,
        claimed: leases.has(tab.id),
      }));
  }
  if (tool === "browser_claim") return claim(owner, args.tabId);
  if (tool === "browser_open") {
    if (!allowed(args.url))
      throw new Error("Only the disposable fixture origin is allowed");
    const tab = await chrome.tabs.create({ url: args.url, active: false });
    // Creation can return pendingUrl before a document exists; never attach to
    // an unrelated old document or loosen the origin check to accommodate it.
    for (let i = 0; i < 100; i++) {
      assertOwner(owner);
      const current = await chrome.tabs.get(tab.id);
      if (allowed(current.url) && current.status === "complete") break;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    return claim(owner, tab.id);
  }
  const lease = targetFor(owner, args.target);
  if (tool === "browser_release") {
    await release(lease, "released");
    return { released: true };
  }
  return serialize(lease, async () => {
    switch (tool) {
      case "browser_observe":
        return observe(lease);
      case "browser_click":
        return click(lease, args.ref);
      case "browser_fill":
        return fill(lease, args.ref, args.text);
      case "browser_navigate": {
        if (!allowed(args.url))
          throw new Error("Only the disposable fixture origin is allowed");
        invalidate(lease);
        const result = await cdp(lease, "Page.navigate", { url: args.url });
        return {
          ...result,
          guidance:
            "Navigation dispatched; observe the loaded page before acting",
        };
      }
      case "browser_stream_start": {
        if (lease.media)
          return { target: lease.target, streamId: lease.media.id };
        const media = { id: crypto.randomUUID(), sequence: 0, pending: null };
        lease.media = media;
        try {
          await cdp(lease, "Page.startScreencast", {
            format: "jpeg",
            quality: 65,
            maxWidth: 1280,
            maxHeight: 960,
            everyNthFrame: 3,
          });
          guard(lease);
          return { target: lease.target, streamId: media.id };
        } catch (error) {
          lease.media = undefined;
          throw error;
        }
      }
      case "browser_stream_stop": {
        clearTimeout(lease.media?.pending?.timer);
        lease.media = undefined;
        await cdp(lease, "Page.stopScreencast");
        emit({ event: "media-stopped", target: lease.target });
        return { stopped: true };
      }
      case "browser_screenshot": {
        const revision = lease.revision;
        const result = await cdp(
          lease,
          "Page.captureScreenshot",
          { format: "jpeg", quality: 65, captureBeyondViewport: false },
          revision,
        );
        guard(lease, revision);
        if (result.data.length > 4 * 1024 * 1024)
          throw new Error("Screenshot exceeds probe limit");
        return {
          mimeType: "image/jpeg",
          data: result.data,
          target: lease.target,
          revision,
        };
      }
      default:
        throw new Error("Unsupported browser tool");
    }
  });
}

chrome.debugger.onEvent.addListener((source, method, params) => {
  const lease = leases.get(source.tabId);
  if (!lease) return;
  if (method === "Page.screencastFrame") {
    const ack = () =>
      chrome.debugger
        .sendCommand(source, "Page.screencastFrameAck", {
          sessionId: params.sessionId,
        })
        .catch(() => {});
    const media = lease.media;
    if (
      !lease.active ||
      !media ||
      media.pending ||
      params.data.length > 4 * 1024 * 1024
    ) {
      void ack();
      return;
    }
    const sequence = ++media.sequence;
    media.pending = {
      sequence,
      ack,
      timer: setTimeout(() => {
        if (lease.media === media && media.pending?.sequence === sequence) {
          media.pending = null;
          void ack();
        }
      }, 1500),
    };
    emit({
      event: "media-frame",
      target: lease.target,
      tabId: lease.tabId,
      streamId: media.id,
      revision: lease.revision,
      sequence,
      metadata: params.metadata,
      data: params.data,
    });
    return;
  }
  if (
    method === "Page.frameNavigated" &&
    !params.frame.parentId &&
    !allowed(params.frame.url)
  ) {
    void release(lease, "outside fixture origin");
    return;
  }
  if (
    (method === "Page.frameNavigated" && !params.frame.parentId) ||
    method === "Page.navigatedWithinDocument" ||
    method === "DOM.documentUpdated"
  )
    invalidate(lease);
});
chrome.debugger.onDetach.addListener((source, reason) => {
  const lease = leases.get(source.tabId);
  if (lease) void release(lease, `debugger detached: ${reason}`);
});
chrome.tabs.onRemoved.addListener((tabId) => {
  const lease = leases.get(tabId);
  if (lease) void release(lease, "tab closed");
});
chrome.action.onClicked.addListener((tab) => {
  const lease = leases.get(tab.id);
  if (lease) void release(lease, "human takeover");
});

function connect() {
  const connection = chrome.runtime.connectNative(config.hostName);
  port = connection;
  connection.onMessage.addListener((message) => {
    if (message.mediaAck) {
      const { target, streamId, sequence } = message.mediaAck;
      const lease = [...leases.values()].find(
        (entry) => entry.target === target,
      );
      const media = lease?.media;
      if (media?.id === streamId && media.pending?.sequence === sequence) {
        const pending = media.pending;
        media.pending = null;
        clearTimeout(pending.timer);
        void pending.ack();
      }
      return;
    }
    void resetting
      .then(() => {
        if (connection !== port) throw new Error("Obsolete bridge connection");
        return handle(message.owner, message.tool, message.args ?? {});
      })
      .then(
        (result) => {
          if (connection === port) emit({ id: message.id, result });
        },
        (error) => {
          if (connection === port)
            emit({ id: message.id, error: error.message });
        },
      );
  });
  connection.onDisconnect.addListener(() => {
    console.warn(
      "Native bridge disconnected",
      chrome.runtime.lastError?.message ?? "closed",
    );
    if (port !== connection) return;
    port = undefined;
    resetting = Promise.all(
      [...leases.values()].map((lease) => release(lease, "bridge lost")),
    );
    // No mutation replay, no lease restoration. Reconnection only restores transport.
    setTimeout(connect, 500);
  });
  emit({ event: "ready", origin: config.origin });
}
connect();
