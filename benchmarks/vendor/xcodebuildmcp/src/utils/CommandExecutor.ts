import { ChildProcess } from 'child_process';

// Runtime marker to prevent empty output in unbundled builds
export const _typeModule = true as const;

export interface CommandExecOptions {
  env?: Record<string, string>;
  cwd?: string;
  onStdout?: (chunk: string) => void;
  onStderr?: (chunk: string) => void;
  /**
   * Milliseconds to wait for the command to finish. When omitted the command is unbounded.
   * On expiry the child is killed with SIGKILL and the promise resolves (it does not reject)
   * with `success: false`, no `exitCode`, and a timeout message in `error`.
   * Ignored for detached commands, which resolve as soon as the process is spawned.
   */
  timeout?: number;
}

/**
 * NOTE: `detached` only changes when the promise resolves; it does not detach/unref
 * the OS process. Callers must still manage lifecycle and open streams.
 */
export type CommandExecutor = (
  command: string[],
  logPrefix?: string,
  useShell?: boolean,
  opts?: CommandExecOptions,
  detached?: boolean,
) => Promise<CommandResponse>;

export interface CommandResponse {
  success: boolean;
  output: string;
  error?: string;
  process: ChildProcess;
  exitCode?: number;
}
