# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Surfer v0.1

This repository also contains the Surfer v0.1 product layer being developed from the Symphony
runner. Surfer is an internal, VPS-hosted organization coding agent:

- Linear is the canonical state machine for durable coding tasks.
- Linear Agent sessions are webhook/direct-dispatch based; the legacy Symphony
  Linear project poller is disabled in the Surfer workflow example unless an
  operator explicitly enables it as fallback.
- Discord is a required invocation and notification surface.
- GitHub owns repositories, branches, PRs, and optional on-demand Company Brain
  retrieval from `Signalsurf-ai/signalsurf-company-brain`.
- Codex is the backend executor, authenticated through an operator-owned OpenAI Pro OAuth session.
- Storage stays local and lightweight: structured logs plus a SQLite run/event ledger.

Surfer does not use Oz, does not introduce a public SaaS install flow, and does not replace Linear
with SQLite as the task source of truth.

The current implementation lives in [`elixir/`](elixir/). Start with
[`elixir/README.md`](elixir/README.md#surfer-v01-vps-deployment) for the VPS/Docker setup and
[`elixir/SURFER_WORKFLOW.example.md`](elixir/SURFER_WORKFLOW.example.md) for the workflow contract.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
