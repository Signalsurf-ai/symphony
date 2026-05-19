# Global Agent Rules

## Repository Context

- This repository is evaluating Surfer, a Linear-native agent product currently built from the Symphony codebase.
- Current local planning and research findings live in ignored docs such as `docs/surfer-v0.1-prd.md`.
- That PRD is the source of truth for Surfer v0.1 Linear Agent work and must be read before implementation changes in this area.

## Surfer Planning

- The docs record current findings about Linear custom agents, Multica, Warp/Oz, and the earlier Kepler/Symphony experiment.
- Surfer v0.1 is VPS-owned. Warp/Oz is reference material only, not a deployment target or runtime dependency.
- Treat Linear's official custom-agent model as webhook-first: `AgentSessionEvent` enters Surfer, and progress is reported back through Linear agent activities. Do not make Surfer depend on Linear project polling by default; keep the legacy Symphony poller opt-in fallback only.
- Treat Discord, GitHub, and Linear as first-class Surfer surfaces. Discord support is required, while Linear is the canonical state machine and source of truth for durable coding tasks.
- Treat Company Brain as optional on-demand retrieval from `Signalsurf-ai/signalsurf-company-brain`, not context that must be loaded for every run.
- Use Multica as design input for trigger semantics, task lineage, and repo scoping, not as a control-plane template to copy wholesale.
- Use Warp/Oz as design input for VPS orchestration, shared sessions, artifacts, reusable skills, and multi-entrypoint triggers.
- Treat Kepler as evidence that the approach can work, but not as best practice. Avoid importing Kepler's hosted control plane, dual workpad state, and broad config system unless the PRD explicitly calls for it.

## Implementation Guardrails

- Keep Surfer v0.1 narrow: preserve the existing Symphony runner/workspace model under Surfer and add the smallest Linear-native ingress needed to trigger it.
- Do not add OAuth install UI, GitHub App auth, Oz hosting, durable run storage as the workflow source of truth, or a multi-repo routing database unless the PRD is updated first.
- If implementation facts contradict the PRD, update the PRD in the same change or stop and surface the contradiction.
