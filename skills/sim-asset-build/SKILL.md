---
name: sim-asset-build
description: Drive an rFabric sim asset build - turn a prompt and a published robot description version into simulation assets (objects and an assembled OpenUSD or MJCF scene) - through the `rfabric mcp serve` tools or the `rfabric sim-asset-build` CLI. Use when asked to build, generate or plan a simulation environment, scene, course or objects for a robot on rFabric, to review or edit a build's plan, to review, rebuild or qualify its outputs, or to continue a build that ran out of budget.
---

# rFabric sim asset builds

A **sim asset build** (`smab_...`) turns a prompt, one published `robot_description` sim asset version per target format and the target formats (`mjcf` for MuJoCo, `openusd` for Isaac Sim) into simulation assets. rFabric runs each step as a digest-pinned builder image on its compute and records every input and output:

1. `plan` writes the **plan**: the robot brief, the course layout, a concept image, an inventory of items with reference crops, assumptions and the sources it read. The build waits in `awaiting_plan_approval`.
2. You review, optionally edit, and approve the plan by its `planSha256`.
3. One step per inventory item: `import:<key>` (a library item fetched at a pinned commit) or `object:<key>` (a generated object). Each registers one draft sim asset version per target format.
4. One `assemble:<format>` step per target format composes the **scene** from the robot and the item versions.
5. rFabric validates every output, renders a thumbnail and a turntable, and grants a qualification level up to `perception_eval`. The build waits in `awaiting_review`.
6. You review the outputs: qualify each at `interaction_eval`, or revise the build from the step whose output is wrong, with notes.

Every action is recorded on the build: its revisions, each step's compute task, model calls, fetched sources and usage against the budget.

## Connect

Install and sign in to the CLI (`rfabric auth login`, or `RFABRIC_CLIENT_ID` / `RFABRIC_CLIENT_SECRET` for a client credential), and set the workspace the builds run in:

```bash
rfabric config set workspace <workspace-id-or-slug>
```

Register the MCP server with your agent. It speaks MCP over stdio and calls the rFabric API as the active CLI profile:

```bash
claude mcp add rfabric -- rfabric mcp serve                     # Claude Code
claude mcp add rfabric -- rfabric mcp serve --profile staging   # pin a profile
```

Any other MCP client (`mcp.json`):

```json
{
  "mcpServers": {
    "rfabric": { "type": "stdio", "command": "rfabric", "args": ["mcp", "serve"] }
  }
}
```

Without MCP, every step below has a CLI command; add `--output json` to read what the API returned.

## Tools and commands

Each tool returns the API's response, `{"data": ...}` (`{"data": [...], "pagination": {...}}` for the list). An API refusal is a tool error whose text is `{"error": {"code", "message", "correlationId", "details", "hint"}}`: act on `code`, `details` and `hint`, and quote `correlationId` when you report a problem.

| Step | MCP tool | CLI |
| --- | --- | --- |
| Start a build | `sim_asset_build_create` | `rfabric sim-asset-build create ...` |
| Follow it | `sim_asset_build_get` | `rfabric sim-asset-build get <build-id>` |
| List builds | `sim_asset_build_list` | `rfabric sim-asset-build ls [--status <status>]` |
| Read the plan | `sim_asset_build_plan_get` | `rfabric sim-asset-build plan <build-id>` |
| Edit the plan | `sim_asset_build_plan_update` | `rfabric sim-asset-build plan <build-id> --file plan.json` |
| Approve the plan | `sim_asset_build_plan_approve` | `rfabric sim-asset-build approve-plan <build-id> --plan-sha256 <hex>` |
| List the outputs | `sim_asset_build_outputs` | `rfabric sim-asset-build outputs <build-id>` |
| Rebuild from a step | `sim_asset_build_revise` | `rfabric sim-asset-build revise <build-id> --from <step-key> --notes "..."` |
| Qualify a version | `sim_asset_qualify` | `rfabric sim-asset qualify <version-id> --level interaction_eval --checklist ...` |
| Continue after budget exhaustion | - | `rfabric sim-asset-build resume <build-id>` |
| Cancel | - | `rfabric sim-asset-build cancel <build-id>` |

## Workflow

### 1. Create

Find the robot: a published `robot_description` sim asset version of the workspace in each target format (`rfabric sim-asset ls --filter kind=robot_description`, then `rfabric sim-asset versions <asset-id>`).

`sim_asset_build_create` arguments:

```json
{
  "name": "Microduck obstacle course",
  "slug": "microduck-obstacle-course",
  "request": {
    "prompt": "An obstacle course for Microduck with two ramps, a platform and a rubber mat",
    "targetFormats": ["mjcf"],
    "robotAssetVersionIds": { "mjcf": "smav_..." }
  },
  "budget": { "modelInputTokens": 400000, "modelOutputTokens": 80000, "modelImages": 20, "computeHours": 6 }
}
```

- `robotAssetVersionIds` has exactly one key per target format.
- `workspace` (id or slug) is optional; it defaults to the profile's workspace.
- `builders` is optional: builder images resolve from the workspace's `simAssetBuild.builders` setting. Pass one only to try another builder image, pinned by digest (`repository@sha256:<64 hex>`).
- Every budget counter is a hard limit checked before each step and each model call.

### 2. Wait for the plan

Call `sim_asset_build_get` every 15-30 seconds until `status` is `awaiting_plan_approval`. The current revision's steps are in `data.steps`: each step's `status`, `classification` and `error`, the `sources` it fetched and the `modelCalls` it made. A failed step's attempt logs print with `rfabric compute-attempt logs <attemptId>`.

Statuses: `planning` -> `awaiting_plan_approval` -> `building` -> `awaiting_review`; or `failed`, `cancelled`, `budget_exhausted`.

Each revision (`data.revisions[]`) runs as one Operation (`operationId`). A `failed` build's reason, such as `plan_invalid` for a plan the API refused, is that Operation's `error`: `rfabric operation get <operationId>`.

### 3. Review and approve the plan

`sim_asset_build_plan_get` returns `data.planSha256` and `data.plan` (`protocol: sim-asset-plan/1`). Check against the prompt:

- `layout`: `extentM` (floor, metres), the `route` waypoints, `clearances`, and each `placements[]` entry (`position` in metres, `rotation` in degrees, z up).
- `items[]`: `key`, `label`, `quantity`, `dimensions` (`assumed: true` means estimated), `source` (`generate`, or `library` with `repo`, `revision`, `path`).
- `parameters[]`: the scene parameters scenarios and trainers will randomize.
- `assumptions` and `sources`: what the planner guessed and what it read.

To change the plan, send the whole edited document to `sim_asset_build_plan_update` (start from `data.plan`, keep `robot.assetVersionId`, `conceptImage` and every `referenceCropHash` as they are; a `library` item's `revision` must be a commit SHA). It returns the stored plan with a new `planSha256`.

Approve with `sim_asset_build_plan_approve` and the `planSha256` you last read. `plan_changed` (409) means the plan changed since you read it: read it again. Approval moves the build to `building` with one `import:<key>` / `object:<key>` step per item, then one `assemble:<format>` step per target format.

### 4. Review the outputs

Poll `sim_asset_build_get` until `awaiting_review`, then call `sim_asset_build_outputs`. Each output has `itemKey` (`scene` for an assembled scene), `asset`, `version` and `sources`. Validation and previews finish after the build reaches `awaiting_review`: a version with no `fail` check, no `previews.error` and `qualification` `null` is still settling unless its latest validation failed. Read that with `rfabric operation ls -f kind=simAsset.validate -f resourceType=simAssetVersion -f resourceId=<version-id> --sort createdAt:desc`: while the newest operation is `queued` or `running`, or `succeeded` with the previews still rendering, poll `sim_asset_build_outputs` again; when it `failed` (its `error.code`, e.g. `no_capable_pool` or `asset_validation_incomplete`), stop waiting, rerun it with `rfabric sim-asset validate <version-id> --wait` once the cause is fixed, or rebuild the version (step 5). Stop and report a version that has not settled after 15 minutes. For each version check:

- `validationResults.checks`: no `fail`; read every `warn`.
- `previews.thumbnailUrl` and `previews.turntableUrl`: look at them.
- `qualification`: `perception_eval` from validation; `interaction_eval` only after a review.
- `dependencies`: a scene depends on the robot and the item versions of its format.
- `license` and the step's `sources` for imported items.

### 5. Qualify, or rebuild

**Qualify** each version you reviewed with `sim_asset_qualify`:

```json
{
  "simAssetVersionId": "smav_...",
  "level": "interaction_eval",
  "checklist": { "collisionGeometry": true, "massInertia": true, "friction": true, "scale": true },
  "notes": "Collision boxes match the visual mesh; mass from PVC density"
}
```

- Confirm a checklist item only after checking it; all four must be true.
- Qualify dependencies first: the robot and the item versions before the scene. `asset_qualification_insufficient` (422) with `details.requiredLevel` `interaction_eval` lists in `details.assetVersionIds` the versions to qualify first; with `perception_eval` it names the version itself, which is not at `perception_eval`: wait while its validation or previews are still settling (step 4), and rebuild it (below) after a `fail` check, `visual_preview` or a `previews.error`.
- A version imported without license metadata needs a `License: <license>` line in `notes`.
- Needs the `simAsset.publish` permission. Gating evaluations and training launches stage only versions qualified at `interaction_eval`.

**Rebuild** an output that is wrong with `sim_asset_build_revise`: `fromStepKey` is the step that made it (`version.buildStepKey`: `object:<key>`, `import:<key>` or `assemble:<format>`, or `plan` to plan again) and `notes` say what to change. That step and every step depending on it rerun as a new revision; every other step is reused. Then go back to step 2 (from `plan`) or 4.

## Errors

| Code | Status | Do |
| --- | --- | --- |
| `no_capable_pool` | 422 | no compute pool on the workspace's compute target (`compute.defaultTargetId` setting) runs `simAssetBuild.step` at `details.resourceClass`: ask a workspace admin for a target with such a pool |
| `sim_asset_build_builders_unresolved` | 422 | `details.keys` resolve nowhere: set the `simAssetBuild.builders` setting or pass `builders` |
| `sim_asset_build_robot_invalid` | 422 | the robot version is not a published `robot_description` of the workspace in that format |
| `sim_asset_build_not_awaiting_plan_approval` | 409 | the build is not waiting for plan approval: read its status |
| `plan_changed` | 409 | read the plan again and approve its `planSha256` |
| `library_revision_unpinned` | 422 | pin the library item's `revision` to a commit SHA |
| `build_revision_running` | 409 | the current revision is still running: wait until the build settles |
| `budget_exhausted` | 409 | raise the budget (`rfabric api patch /api/sim-asset-builds/<build-id> --data '{"budget":{...}}'`, every counter, none below usage), then `rfabric sim-asset-build resume <build-id>` |
| `asset_qualification_insufficient` | 422 | `details.requiredLevel` `interaction_eval`: qualify `details.assetVersionIds` first; `perception_eval`: the version is not at `perception_eval` - wait while its validation or previews settle, rebuild it from its `buildStepKey` after a `fail` check, `visual_preview` or a `previews.error` |
| `VALIDATION_ERROR` | 422 | fix the argument named in `details` |

## Definition of Done

- [ ] The plan you approved is the build's current plan: its `planSha256` is the one `sim_asset_build_plan_approve` named, and it matches the prompt or your edits.
- [ ] The build is `awaiting_review` and every step of its current revision succeeded.
- [ ] Every output in `sim_asset_build_outputs` has no `fail` validation check, and you looked at its previews.
- [ ] Every output you accepted is qualified at `interaction_eval`, its dependencies before it, with notes on what you checked; every output you did not accept was rebuilt through `sim_asset_build_revise` with notes.
- [ ] You reported the build id and each output's version id and qualification.
