# Example sprites

Complete sprite specs (`docs/agent-authoring.md`) to start from. Each one compiles without a single warning and
draws in both appearances; `ExampleSpecsTests` keeps it that way. Apply one with
`menusprite apply examples/sprites/<name>.json --preview <dir>`, or read it with `menusprite examples <name>`. Agents
with only the MCP server read them through `list_examples` and `get_example`: they are compiled into the
`menusprite` command by `scripts/embed-agent-examples.py`, which reads the table below for each one's summary. Run
it after changing any example.

| Example | What it shows |
|---|---|
| `ai-usage-board` | Claude and Codex limits: two pace-coloured face lines, gauges with reset clock times, a signed-out state |
| `docker-containers` | Running containers on the face; a board of containers, each with a switch that starts or stops it |
| `git-repo-status` | Repositories with uncommitted work: one scan feeds the face and a board of clickable rows |
| `github-prs` | Pull requests waiting for your review; a board of clickable PR rows from gh, and a failure state |
| `homebrew-outdated` | Outdated Homebrew packages: a Check now button with a long timeout, and an upgrade that reports back |
| `network-switches` | Switches for Tailscale and Wi-Fi; three values that read one tailscale call; a copyable address |
| `system-dashboard` | CPU and memory on two face lines; tiles, charts, a disk gauge and the process list, from readings only |
| `weather` | Temperature and a sky icon from one wttr.in request; a forecast board with an icon per day |
