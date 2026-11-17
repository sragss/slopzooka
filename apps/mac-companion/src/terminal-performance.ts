import type { Terminal } from "@xterm/xterm";
import type { EventLogger } from "./log-events.js";

/** Bounded, payload-free summaries. All durations use this document's clock. */
export class TerminalPerformance {
  private fields: Record<string, number> = {};
  private pendingFrames = 0;
  private pendingCharacters = 0;
  private eventAt?: number;
  private parsedAt?: number;
  private probe?: { id: number; started: number };
  private sequence = 0;
  private lastProbe = -Infinity;
  private lastTick = performance.now();
  private readonly timer: ReturnType<typeof setInterval>;
  private readonly renderSubscription: { dispose(): void };
  private readonly input: HTMLTextAreaElement | undefined;
  private readonly eventRoot: Window | null | undefined;
  constructor(
    terminal: Terminal,
    private readonly log: () => EventLogger | undefined,
  ) {
    this.input = terminal.textarea;
    // Observe before the document's native-key normalizer synthesizes an event
    // with a fresh timestamp, otherwise dispatch delay would be hidden.
    this.eventRoot = this.input?.ownerDocument.defaultView;
    for (const type of ["keydown", "beforeinput", "input"])
      this.eventRoot?.addEventListener(type, this.observeInput, true);
    for (const type of ["keyup", "blur"])
      this.eventRoot?.addEventListener(type, this.clearInput, true);
    this.renderSubscription = terminal.onRender(() => {
      if (this.parsedAt !== undefined) {
        this.max("parseToRenderMaxMs", performance.now() - this.parsedAt);
        this.parsedAt = undefined;
      }
    });
    this.timer = setInterval(() => {
      const now = performance.now();
      if (!document.hidden)
        this.max("eventLoopDelayMaxMs", now - this.lastTick - 1000);
      this.lastTick = now;
      this.expireProbe(now);
      if (now - this.lastReport >= 10_000) this.flush();
    }, 1000);
  }
  private lastReport = performance.now();
  private readonly observeInput = (event: Event) => {
    if (event.target !== this.input) return;
    const now = performance.now();
    this.eventAt = now;
    const delay = now - event.timeStamp;
    // Older WebKit timestamps can have a different origin. Do not mix clocks.
    if (delay >= 0 && delay < 60_000) this.max("eventDispatchMaxMs", delay);
  };
  private readonly clearInput = (event: Event) => {
    if (event.target === this.input) this.eventAt = undefined;
  };
  submitted(supportsInputAck: boolean): number | undefined {
    const now = performance.now();
    this.count("inputs");
    if (this.eventAt !== undefined) {
      this.max("eventToSendMaxMs", now - this.eventAt);
      this.eventAt = undefined;
    }
    this.expireProbe(now);
    if (!supportsInputAck || this.probe || now - this.lastProbe < 1000) return;
    const id = ++this.sequence;
    this.lastProbe = now;
    this.probe = { id, started: now };
    this.count("inputProbes");
    return id;
  }
  acknowledged(id: number): void {
    if (this.probe?.id !== id) return;
    this.max("inputAckMaxMs", performance.now() - this.probe.started);
    this.count("inputAcks");
    this.probe = undefined;
  }
  disconnected(): void {
    if (this.probe) this.count("inputProbesInterrupted");
    this.probe = undefined;
    this.eventAt = undefined;
  }
  queued(characters: number): void {
    this.pendingFrames++;
    this.pendingCharacters += characters;
    this.count("outputFrames");
    this.max("queuedFramesMax", this.pendingFrames);
    this.max("queuedCharactersMax", this.pendingCharacters);
  }
  started(frames: number, characters: number, receivedAt: number): void {
    this.pendingFrames -= frames;
    this.pendingCharacters -= characters;
    this.max("queueWaitMaxMs", performance.now() - receivedAt);
    this.count("outputBatches");
  }
  parsed(started: number): void {
    this.max("parseMaxMs", performance.now() - started);
    this.parsedAt ??= performance.now();
  }
  private expireProbe(now: number): void {
    if (this.probe && now - this.probe.started >= 10_000) {
      this.count("inputAckTimeouts");
      this.probe = undefined;
    }
  }
  private count(field: string): void {
    this.fields[field] = (this.fields[field] ?? 0) + 1;
  }
  private max(field: string, value: number): void {
    this.fields[field] = Math.max(this.fields[field] ?? 0, Math.round(value));
  }
  flush(): void {
    if (Object.keys(this.fields).some((key) => key !== "eventLoopDelayMaxMs"))
      this.log()?.info("latency.summary", {
        ...this.fields,
        intervalMs: Math.round(performance.now() - this.lastReport),
        pendingFrames: this.pendingFrames,
        pendingCharacters: this.pendingCharacters,
      });
    this.fields = {};
    this.lastReport = performance.now();
  }
  dispose(): void {
    clearInterval(this.timer);
    this.disconnected();
    this.flush();
    this.renderSubscription.dispose();
    for (const type of ["keydown", "beforeinput", "input"])
      this.eventRoot?.removeEventListener(type, this.observeInput, true);
    for (const type of ["keyup", "blur"])
      this.eventRoot?.removeEventListener(type, this.clearInput, true);
  }
}
