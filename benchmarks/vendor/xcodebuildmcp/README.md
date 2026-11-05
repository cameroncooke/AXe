# Local benchmark model runner

This directory owns the model-runner code used by the AXe benchmark suite. It has no code dependency on another XcodeBuildMCP checkout.

The 46 TypeScript files and Python transcript parser are exact copies from XcodeBuildMCP. The MIT license is included. See provenance.json for the source commit, the three copied files that had local changes, and the hash of each file. These copies preserve the runner behavior used by the original benchmarks. The dependency lock contains only their required npm packages and platform variants.

Use the main AXe benchmark command in ../../run. For this package alone:

    npm ci --ignore-scripts --no-audit --no-fund
    npm run check
    npm run runner -- --suite /absolute/path/to/generated-suite.yml --json

Node 20 or later and npm 10 or later are required. Live runs also require an installed, authenticated Claude Code CLI and the selected simulator/tool. Setup does not start a model job. The check verifies the copied file hashes and imports the full runner to show help. It does not start Claude or touch a simulator. Use node --import tsx to avoid the tsx CLI's extra IPC server.

The directory tree is retained so the source repoRoot resolves here. Raw artifacts are written to out.nosync/claude-benchmarks here. The main suite copies required evidence into its result directory. The parser is bundled at benchmarks/claude-ui/parse_claude_conversation.py.

The main suite supplies explicit YAML and prompt paths, an existing simulator, and useMcpServer: false. This package does not include the original XcodeBuildMCP MCP server, its release build, or its original named suite collection. It is a local copy of the model runner, not the XcodeBuildMCP product. The AXe suite's scenarios, rules, grading and baseline logic are in the parent benchmarks directory.

For an intentional vendor update, copy the source closure, update provenance.json and the pinned dependency lock, and run the offline checks. Record a new runner hash in benchmark results. Do not compare a changed harness as if it were the old baseline contract.
