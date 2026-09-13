# MenuSprite planning pack

Status: **Broader product reference; first personal build takes priority, 8 September 2026.**

**Current step:** [Permissions & Access](../permissions-page.md), one transparent
page before tool implementation or an MVP. Work through it gradually with Prerak.

Read [First personal build](../first-personal-build.md) for current work. Prerak
wants the important tools usable with very low memory use. Marketplace, social
features and public extension-platform design are deferred. The remaining
discussion should refine the fan/battery controls and CleanShot/Paste workflows
in his supplied daily-tool checklist, not finalize this entire pack.
The [8 September instruction](discussions/2026-09-08-personal-first.md) supersedes
earlier delivery prerequisites.

Prerak requested the complete product, feature, specification, and architecture
discussion before development. This pack preserves the agreed brief and makes
proposals concrete enough to review. It does **not** record unanswered questions
as decisions. No native implementation, technical experiment, or benchmark has
been performed. Development is not authorized by the existence of these files.

## Read in this order

After the current personal-build brief, consult [Sprite platform direction](sprite-platform.md)
only for broader product context and examples. The menu bar is no longer the
limit of intended utility scope. The original voice-typed clarification is saved
under [discussions](discussions/2026-09-07-sprite-platform.md).

1. [Product requirements](prd.md): product job, users, scope, workflows, success.
2. [Feature specification](features.md): feature inventory and observable behavior.
3. [Architecture](architecture.md): native structure, data model, execution,
   persistence, and extension boundaries.
4. [Feasibility evidence](feasibility.md): documented APIs, external evidence,
   limitations, and investigations required when development is authorized.
5. [Acceptance and delivery](acceptance.md): measurable quality targets,
   scenario checks, dependencies, and implementation sequence.
6. [Decisions and discussion](decisions.md): confirmed requirements, proposed
   defaults, unanswered questions, and how to resume.

## How to interpret the scope

- **Confirmed** means present in the existing product brief or requested by Prerak.
- **Proposed** means a recommendation in this pack, awaiting discussion.
- **Candidate** means a possible extension to decide on, not a committed feature.
- **Validation required** means a proposed implementation needs native evidence.

These describe different things: a confirmed product goal may still require
technical validation. A working website concept does not validate a native feature.
Feature IDs remain stable as wording or release sequencing changes.

## Completeness and readiness

This is an evolving specification, not a finalized PRD. Broad utilities,
customizable sprites, versioned installation, marketplace, likes and friends are
now part of the stated vision. Every sprite must have an identity icon, with
optional menu bar presence. Next resolve detailed surfaces, precise replacement
workflows, package/extension contracts and social
mechanics. Platform coverage and resource targets also need decisions. See
[the decision table](decisions.md).

Those are longer-term design questions. They no longer all need answers before
the first personal build. Use the short current brief to select daily workflows
and resolve only the implementation questions necessary for those workflows.

The [product brief](../product-brief.md) reflects the latest stated intent. The
deployed website still reflects the earlier narrower concept and has not changed.
