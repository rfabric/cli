---
name: sim-asset-build
description: Drive an rFabric sim asset build - turn a prompt and a published robot description version into simulation assets (objects and an assembled OpenUSD or MJCF scene) - through the `call_operation` tool of rFabric's remote MCP endpoint or the `rfabric sim-asset-build` CLI. Use when asked to build, generate or plan a simulation environment, scene, course or objects for a robot on rFabric, to review or edit a build's plan, to review, reject, rebuild or qualify its outputs, or to continue a build that ran out of budget.
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

Register rFabric's MCP endpoint with your agent. It is a remote Model Context Protocol server at `https://api.rfabric.io/mcp`; on first use your agent opens the browser for you to sign in to rFabric with OAuth and authorize it, and every call runs as you in the organization you authorized:

```bash
claude mcp add --transport http rfabric https://api.rfabric.io/mcp   # Claude Code
```

Any other MCP client (`mcp.json`):

```json
{
  "mcpServers": {
    "rfabric": { "type": "http", "url": "https://api.rfabric.io/mcp" }
  }
}
```

Its tools reach every rFabric API operation: `search_operations` finds an operation, `describe_operation` returns its parameters, body and response schemas, and `call_operation` calls it by `operationId` with `pathParameters`, `query` and `body`.

For the CLI, install it and sign in (`rfabric auth login`, or `RFABRIC_CLIENT_ID` / `RFABRIC_CLIENT_SECRET` for a client credential), and set the workspace the builds run in:

```bash
rfabric config set workspace <workspace-id-or-slug>
```

Every step below has a CLI command; add `--output json` to read what the API returned.

## Operations and commands

`call_operation` returns `{"status", "body"}` with the API's response as `body`: `{"data": ...}` (`{"data": [...], "pagination": {...}}` for the list). An API refusal is a tool error whose `body` is `{"error": {"code", "message", "correlationId", "details", "hint"}}`: act on `code`, `details` and `hint`, and quote `correlationId` when you report a problem. Call `describe_operation` for an operation's exact arguments.

| Step | `call_operation` operationId | CLI |
| --- | --- | --- |
| Upload a reference image | `sim-asset-builds.reference-images` | `rfabric sim-asset-build create ... --reference-image <file>` |
| Start a build | `sim-asset-builds.create` | `rfabric sim-asset-build create ...` |
| Follow it | `sim-asset-builds.get` | `rfabric sim-asset-build get <build-id>` |
| List builds | `sim-asset-builds.list` | `rfabric sim-asset-build ls [--status <status>]` |
| Read the plan | `sim-asset-builds.list-plan` | `rfabric sim-asset-build plan <build-id>` |
| Edit the plan | `sim-asset-builds.replace-plan` | `rfabric sim-asset-build plan <build-id> --file plan.json` |
| Approve the plan | `sim-asset-builds.plan-approve` | `rfabric sim-asset-build approve-plan <build-id> --plan-sha256 <hex>` |
| List the outputs | `sim-asset-builds.outputs` | `rfabric sim-asset-build outputs <build-id>` |
| Reject an output | `sim-asset-builds.outputs-reject` | `rfabric api post /api/sim-asset-builds/<build-id>/outputs/<version-id>/reject --data '{"notes":"..."}'` |
| Rebuild from a step | `sim-asset-builds.revisions` | `rfabric sim-asset-build revise <build-id> --from <step-key> --notes "..."` |
| Qualify a version | `sim-assets.versions-qualify` | `rfabric sim-asset qualify <version-id> --level interaction_eval --checklist ...` |
| Continue after budget exhaustion | `sim-asset-builds.resume` | `rfabric sim-asset-build resume <build-id>` |
| Cancel | `sim-asset-builds.cancel` | `rfabric sim-asset-build cancel <build-id>` |

Every build operation takes the build id as `pathParameters.id`.

## Workflow

### 1. Create

Find the robot: a published `robot_description` sim asset version of the workspace in each target format (`sim-assets.list` with `query.kind` `robot_description`, then `sim-assets.list-versions`; or `rfabric sim-asset ls --filter kind=robot_description`, then `rfabric sim-asset versions <asset-id>`).

`sim-asset-builds.create` body:

```json
{
  "workspaceId": "wks_...",
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

- `workspaceId` is the workspace's id (`workspaces.list` finds it by slug).
- `robotAssetVersionIds` has exactly one key per target format.
- `request.referenceImageHashes` is optional: up to 8 images, each first uploaded with `sim-asset-builds.reference-images` (`workspaceId`, the image's lowercase hex `sha256`, `size` in bytes, `contentType`); PUT the bytes with the `upload` grant it returns, nothing when `upload` is `null`.
- `builders` is optional: builder images resolve from the workspace's `simAssetBuild.builders` setting. Pass one only to try another builder image, pinned by digest (`repository@sha256:<64 hex>`).
- Every budget counter is a hard limit checked before each step and each model call.

### 2. Wait for the plan

Call `sim-asset-builds.get` every 15-30 seconds until `status` is `awaiting_plan_approval`. The current revision's steps are in `data.steps`: each step's `status`, `classification` and `error`, the `sources` it fetched and the `modelCalls` it made. A failed step's attempt logs are `compute-attempts.logs` with its `attemptId` (`rfabric compute-attempt logs <attemptId>`).

Statuses: `planning` -> `awaiting_plan_approval` -> `building` -> `awaiting_review`; or `failed`, `cancelled`, `budget_exhausted`.

Each revision (`data.revisions[]`) runs as one Operation (`operationId`). A `failed` build's reason, such as `plan_invalid` for a plan the API refused, is that Operation's `error`: `operations.get` (`rfabric operation get <operationId>`).

### 3. Review and approve the plan

`sim-asset-builds.list-plan` returns `data.planSha256` and `data.plan` (`protocol: sim-asset-plan/1`). Check against the prompt:

- `layout`: `extentM` (floor, metres), the `route` waypoints, `clearances`, and each `placements[]` entry (`position` in metres, `rotation` in degrees, z up).
- `items[]`: `key`, `label`, `quantity`, `dimensions` (`assumed: true` means estimated), `source` (`generate`, or `library` with `repo`, `revision`, `path`).
- `parameters[]`: the scene parameters scenarios and trainers will randomize.
- `assumptions` and `sources`: what the planner guessed and what it read.

To change the plan, send the whole edited document as the body of `sim-asset-builds.replace-plan` (start from `data.plan`, keep `robot.assetVersionId`, `conceptImage` and every `referenceCropHash` as they are; a `library` item's `revision` must be a commit SHA). It returns the stored plan with a new `planSha256`.

Approve with `sim-asset-builds.plan-approve` and body `{"planSha256": "<hex>"}`, the `planSha256` you last read. `plan_changed` (409) means the plan changed since you read it: read it again. Approval moves the build to `building` with one `import:<key>` / `object:<key>` step per item, then one `assemble:<format>` step per target format.

### 4. Review the outputs

Poll `sim-asset-builds.get` until `awaiting_review`, then call `sim-asset-builds.outputs`. Each output has `itemKey` (`scene` for an assembled scene), `asset`, `version` and `sources`. Validation and previews finish after the build reaches `awaiting_review`: a version with no `fail` check, no `previews.error` and `qualification` `null` is still settling unless its latest validation failed. Read that with `operations.list` and `query` `{"kind": "simAsset.validate", "resourceType": "simAssetVersion", "resourceId": "<version-id>", "sort": "createdAt:desc"}` (`rfabric operation ls -f kind=simAsset.validate -f resourceType=simAssetVersion -f resourceId=<version-id> --sort createdAt:desc`): while the newest operation is `queued` or `running`, or `succeeded` with the previews still rendering, poll `sim-asset-builds.outputs` again; when it `failed` (its `error.code`, e.g. `no_capable_pool` or `asset_validation_incomplete`), stop waiting, rerun it with `sim-assets.versions-validate` (`rfabric sim-asset validate <version-id> --wait`) once the cause is fixed, or rebuild the version (step 5). Stop and report a version that has not settled after 15 minutes. For each version check:

- `validationResults.checks`: no `fail`; read every `warn`.
- `previews.thumbnailUrl` and `previews.turntableUrl`: look at them.
- `qualification`: `perception_eval` from validation; `interaction_eval` only after a review.
- `dependencies`: a scene depends on the robot and the item versions of its format.
- `license` and the step's `sources` for imported items.

### 5. Qualify, reject, or rebuild

**Qualify** each version you reviewed with `sim-assets.versions-qualify`, the version id as `pathParameters.id`:

```json
{
  "level": "interaction_eval",
  "checklist": { "collisionGeometry": true, "massInertia": true, "friction": true, "scale": true },
  "notes": "Collision boxes match the visual mesh; mass from PVC density"
}
```

- Confirm a checklist item only after checking it; all four must be true.
- Qualify dependencies first: the robot and the item versions before the scene. `asset_qualification_insufficient` (422) with `details.requiredLevel` `interaction_eval` lists in `details.assetVersionIds` the versions to qualify first; with `perception_eval` it names the version itself, which is not at `perception_eval`: wait while its validation or previews are still settling (step 4), and rebuild it (below) after a `fail` check, `visual_preview` or a `previews.error`.
- A version imported without license metadata needs a `License: <license>` line in `notes`.
- Needs the `simAsset.publish` permission. Gating evaluations and training launches stage only versions qualified at `interaction_eval`.

**Reject** a draft output you will not use with `sim-asset-builds.outputs-reject`: `pathParameters` `{"id": "smab_...", "versionId": "smav_..."}` and body `{"notes": "..."}` saying why. The version becomes `deprecated` with your notes.

**Rebuild** an output that is wrong with `sim-asset-builds.revisions` and body `{"fromStepKey": "...", "notes": "..."}`: `fromStepKey` is the step that made it (`version.buildStepKey`: `object:<key>`, `import:<key>` or `assemble:<format>`, or `plan` to plan again) and `notes` say what to change. That step and every step depending on it rerun as a new revision; every other step is reused. Then go back to step 2 (from `plan`) or 4.

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
| `budget_exhausted` | 409 | raise the budget with `sim-asset-builds.update` and body `{"budget": {...}}` (`rfabric api patch /api/sim-asset-builds/<build-id> --data '{"budget":{...}}'`), every counter, none below usage, then `sim-asset-builds.resume` (`rfabric sim-asset-build resume <build-id>`) |
| `asset_qualification_insufficient` | 422 | `details.requiredLevel` `interaction_eval`: qualify `details.assetVersionIds` first; `perception_eval`: the version is not at `perception_eval` - wait while its validation or previews settle, rebuild it from its `buildStepKey` after a `fail` check, `visual_preview` or a `previews.error` |
| `VALIDATION_ERROR` | 422 | fix the argument named in `details` |

## Definition of Done

- [ ] The plan you approved is the build's current plan: its `planSha256` is the one `sim-asset-builds.plan-approve` named, and it matches the prompt or your edits.
- [ ] The build is `awaiting_review` and every step of its current revision succeeded.
- [ ] Every output in `sim-asset-builds.outputs` has no `fail` validation check, and you looked at its previews.
- [ ] Every output you accepted is qualified at `interaction_eval`, its dependencies before it, with notes on what you checked; every output you did not accept was rejected through `sim-asset-builds.outputs-reject` or rebuilt through `sim-asset-builds.revisions`, with notes.
- [ ] You reported the build id and each output's version id and qualification.
