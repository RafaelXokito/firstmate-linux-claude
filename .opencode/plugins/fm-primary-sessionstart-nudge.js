import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

const handledSessions = new Set();

function runProcess(command, args) {
  return new Promise((resolveResult) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "ignore"] });
    let stdout = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stdout: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stdout }));
  });
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

export const FmPrimarySessionstartNudge = async ({ client, directory, worktree }) => {
  const derived = worktree ? resolvePath(worktree) : await resolveRoot(directory);
  // In a per-project firstmate home the project directory OpenCode reports is
  // the HOME, which has no bin/ of its own, so the derived root would aim every
  // spawn at a path that does not exist - and this plugin swallows that spawn
  // error, so the guard would simply go quiet. bin/fm-launch.sh exports
  // FM_ROOT_OVERRIDE to name the shared clone; same precedence as
  // fm-primary-watch-arm.js's effectivePaths().
  const root = process.env.FM_ROOT_OVERRIDE || derived;

  return {
    event: async ({ event }) => {
      if (event.type !== "session.created") return;
      const sessionID = event.properties?.info?.id ?? event.properties?.sessionID;
      if (!sessionID || handledSessions.has(sessionID) || !root) return;
      handledSessions.add(sessionID);

      const result = await runProcess(`${root}/bin/fm-sessionstart-nudge.sh`, []);
      const nudge = result.code === 0 ? result.stdout.trim() : "";
      if (!nudge) return;

      try {
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text: nudge }],
          },
        });
      } catch {
      }
    },
  };
};
