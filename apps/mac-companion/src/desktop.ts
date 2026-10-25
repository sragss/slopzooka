import { execFile } from "node:child_process";
import os from "node:os";
import { promisify } from "node:util";

/** Finder does not inherit Terminal's PATH (nvm, mise, pnpm, agent CLIs, etc.). */
export async function loadDesktopPath(): Promise<void> {
  if (process.env.SLOPZOOKA_DESKTOP !== "1") return;
  const shell = process.env.SHELL || os.userInfo().shell || "/bin/zsh";
  process.env.SHELL = shell;
  try {
    const { stdout } = await promisify(execFile)(
      shell,
      ["-ilc", "printf '\\000SLZ_PATH\\000%s\\000' \"$PATH\""],
      { timeout: 5000, maxBuffer: 1024 * 1024, cwd: os.homedir() },
    );
    const match = stdout.match(/\0SLZ_PATH\0([^\0]+)\0/);
    if (match) process.env.PATH = match[1];
  } catch {
    console.warn(
      "Could not load the login-shell PATH; using standard application locations.",
    );
  }
}
