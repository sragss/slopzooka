import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";

const home = process.env.CODEX_HOME;
const record = (value) =>
  fs.appendFileSync(
    path.join(home, "calls.jsonl"),
    JSON.stringify(value) + "\n",
  );
const args = process.argv.slice(2);
record({ args, cwd: process.cwd(), pid: process.pid });
if (process.env.SLOPZOOKA_SESSION_ID === "fresh-codex") {
  // Model the alternate-screen menu captured from Codex CLI 0.171.0.
  const stages = [
    {
      title: "Update available · 0.171.0 → 0.172.0",
      choices: [
        "Update now (runs `bun install -g @openai/codex`)",
        "Skip",
        "Skip until next version",
      ],
    },
    {
      title: "Welcome to Codex",
      choices: [
        "Sign in with ChatGPT",
        "Sign in with Device Code",
        "Provide your own API key",
      ],
    },
  ];
  let stage = 0;
  let selected = 0;
  const draw = () => {
    const { title, choices } = stages[stage];
    const options = choices.map((choice, index) =>
      index === selected
        ? `\x1b[7m› ${index + 1}. ${choice}\x1b[27m`
        : `  ${index + 1}. ${choice}`,
    );
    process.stdout.write(
      `\x1b[H\x1b[2J\x1b[1m${title}\x1b[22m\r\n\r\n${options.join("\r\n")}\r\n\r\nenter continue · esc skip`,
    );
  };
  process.stdin.setRawMode(true);
  process.stdout.write("\x1b[?1049h\x1b[?25l");
  draw();
  // Accept ordinary cursor keys and Return. No action occurs until Return.
  readline.emitKeypressEvents(process.stdin);
  process.stdin.on("keypress", (_text, key) => {
    if (stage === stages.length) return;
    if (key.name === "return") {
      if (stage === 0 && selected === 0) {
        process.stdout.write("FIXTURE_UPDATE_SELECTED");
        process.exit(1);
      }
      stage++;
      selected = 0;
      if (stage === stages.length) {
        process.stdout.write("\x1b[?25h\x1b[?1049lCODEX_READY\r\n");
        return;
      }
    }
    if (key.name === "up" || key.name === "down") {
      const count = stages[stage].choices.length;
      selected = (selected + (key.name === "up" ? -1 : 1) + count) % count;
    }
    draw();
  });
} else if (args.includes("resume")) {
  console.log("RESUMED_FIXTURE");
  process.stdin.on("data", () => process.exit(0));
} else if (args.includes("app-server")) {
  const mode = fs.existsSync(path.join(home, "mode"))
    ? fs.readFileSync(path.join(home, "mode"), "utf8")
    : "normal";
  if (mode === "exit") process.exit(1);
  const threads = Array.from({ length: 30 }, (_, index) => ({
    id: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
    name: index === 0 ? null : `Private thread ${index}`,
    preview: "Fallback title\nprivate conversation",
    cwd: path.join(home, index === 2 ? "missing" : "project"),
    updatedAt: 2000 - index,
    ephemeral: false,
    turns: [],
  }));
  const lines = readline.createInterface({ input: process.stdin });
  lines.on("line", (line) => {
    const message = JSON.parse(line);
    record({ method: message.method, params: message.params });
    if (mode === "hang" || message.id === undefined) return;
    if (mode === "oversize") {
      process.stdout.write("x".repeat(5 * 1024 * 1024));
      return;
    }
    if (mode === "malformed") {
      console.log(JSON.stringify({ id: message.id, result: { data: null } }));
      return;
    }
    let result;
    if (message.method === "initialize") result = {};
    if (message.method === "thread/list")
      result = { data: threads, nextCursor: "do-not-follow" };
    if (message.method === "thread/search")
      result = {
        data: [{ thread: threads[4], snippet: "paired fixture" }],
        nextCursor: "page-2",
      };
    if (message.method === "thread/turns/list")
      result = {
        data: [
          {
            items: [
              {
                type: "userMessage",
                content: [{ type: "text", text: "x".repeat(600) }],
              },
              { type: "commandExecution", aggregatedOutput: "PRIVATE_OUTPUT" },
              { type: "agentMessage", text: "y".repeat(500) },
            ],
          },
        ],
        nextCursor: "older",
      };
    if (message.method === "thread/read") {
      const thread = threads.find(
        (thread) => thread.id === message.params.threadId,
      );
      if (!thread) {
        console.log(
          JSON.stringify({
            id: message.id,
            error: { code: -32600, message: "private error" },
          }),
        );
        return;
      }
      result = { thread };
    }
    console.log(JSON.stringify({ id: message.id, result }));
  });
  lines.on("close", () => process.exit(0));
}
