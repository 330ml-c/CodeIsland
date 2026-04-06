# Session Title Support Design

## Goal

Make expanded session cards show real session titles instead of always using the project folder name. Codex sessions should read user-assigned titles from Codex's local session index, and the design should leave a clear extension point for future providers such as Claude Code.

## Problem Summary

Today the card header uses the session display name derived from `cwd`'s last path component. This works as a rough project label, but it breaks down when a user opens multiple sessions in the same repository. In that case every card shows the same title and the UI falls back to a short session ID suffix such as `#019d`, which is useful for debugging but not useful as a primary label.

Codex already persists user-defined session titles in `~/.codex/session_index.jsonl` under `thread_name`, but CodeIsland does not currently read that file.

## Desired UX

### Card Header

- Primary title shows the provider session title when available.
- If no provider session title exists, primary title falls back to the full session ID.
- Project name no longer occupies the primary title slot.
- Project/path context remains visible as secondary information.

### Session ID

- Session ID remains visible and useful.
- The old short duplicate suffix is replaced by a dedicated session-ID affordance.
- The session-ID affordance should be easy to copy from the UI.
- The initial implementation can show a compact truncated ID such as `#019d...` plus a copy button while keeping the full ID in the copy payload and tooltip.

### Consistency

- The UI should not special-case Codex inside the view layer.
- Session cards should consume a provider-agnostic "display title" model.

## Design Options Considered

### Option 1: Codex-only patch

Add a Codex title lookup directly in the card view and replace `#019d` with `thread_name`.

Pros:

- Fastest path.

Cons:

- Hard-codes provider logic in UI.
- Makes Claude and other providers harder to add later.
- Leaves naming rules spread across multiple files.

### Option 2: Provider-agnostic session title layer

Add a session-title abstraction in the model/state layer. Providers populate an optional `sessionTitle`, and UI reads a single `displayTitle`.

Pros:

- Cleanest long-term structure.
- Codex support lands now without blocking future Claude support.
- Keeps fallback rules centralized.

Cons:

- Slightly more code than a one-off patch.

### Option 3: Standalone title index watcher

Build a dedicated background service that watches provider title stores and continuously updates sessions.

Pros:

- Most flexible long term.

Cons:

- Too heavy for the current scope.
- Adds lifecycle and synchronization complexity before it is needed.

## Recommendation

Use Option 2.

It solves the immediate Codex problem while creating a clean seam for future providers. It also keeps the UI simple: the card reads one field for the title and one field for the session ID control.

## Proposed Architecture

### 1. Session title fields in shared state

Extend the session snapshot model with provider-agnostic title fields:

- `sessionTitle: String?`
  The best title sourced from the provider, if any.
- `sessionTitleSource: SessionTitleSource?`
  Optional enum to track where the title came from.

Add computed display helpers:

- `displayTitle`
  Returns `sessionTitle` when present and non-empty, otherwise returns the full session ID supplied by callers.
- `projectDisplayName`
  Keeps the current folder-derived naming behavior for secondary UI.

This separates "what is this session called?" from "which project folder is it in?"

### 2. Provider title resolver layer

Introduce a lightweight title resolver path in app state:

- `SessionTitleResolver` protocol or a small static helper namespace
- provider-specific lookup entry points, starting with Codex

The first provider implementation:

- `CodexSessionTitleStore`
  Reads `~/.codex/session_index.jsonl`
  maps session ID -> `thread_name`
  returns the latest matching title

This can start as on-demand file reads during discovery/event handling rather than a live file watcher. A watcher can be added later if needed.

### 3. Integration points

Codex titles should be applied in two places:

- During Codex session discovery, when a `SessionSnapshot` is first created from transcript files.
- During Codex event handling for known sessions, so a newly assigned title can be picked up after the session already exists.

The lookup should be cheap and isolated. If the index file is missing, malformed, or the session ID has no entry, the app should simply leave `sessionTitle` empty.

### 4. UI changes

Update the session card header to use:

- primary title: `session.sessionTitle` when present, otherwise full session ID
- secondary/project line: current project/folder-derived label

Replace the current duplicate-name suffix behavior:

- remove the "show first 4 chars only when names collide" rule
- always render a dedicated session-ID control
- allow copying the full session ID from that control

This makes the session ID consistently available instead of appearing only in duplicate cases.

## Data Flow

### Codex

1. CodeIsland discovers or updates a Codex session.
2. It extracts the Codex session ID as it does today.
3. It queries the Codex title store using that session ID.
4. If a `thread_name` exists, it stores it in `sessionTitle`.
5. The card view renders that as the primary title.
6. The session-ID control remains available for copy/debugging.

### Future providers

Each provider can later add its own resolver without changing card rendering rules.

## Error Handling

- Missing `~/.codex/session_index.jsonl`: no title, no error surfaced to user.
- Malformed JSON lines: skip bad lines, continue scanning.
- Duplicate entries for the same session ID: use the newest matching entry.
- Empty or whitespace-only titles: treat as no title.

## Testing Strategy

### Unit-level behavior

Add focused tests for:

- parsing `session_index.jsonl`
- selecting the latest `thread_name` for a matching session ID
- ignoring malformed lines
- ignoring blank titles
- fallback behavior when no title exists

### Model/UI behavior

Add tests for display helpers:

- title present -> title used as primary label
- title absent -> full session ID used as primary label
- project display name still available as secondary info

### Manual verification

Verify in a live Codex setup:

- named Codex sessions display their assigned names
- unnamed Codex sessions display session IDs instead of project name
- project/folder context is still visible
- session-ID control copies the full ID

## Non-goals

- Implementing Claude title support in this change
- Building a persistent background watcher for every provider title source
- Redesigning the whole session card layout beyond the title/id area

## Risks

- Codex index format may evolve. Mitigation: keep parser narrow and tolerant.
- Session index may lag behind transcript creation. Mitigation: refresh title lookup during later event handling, not discovery only.
- Full session IDs are visually long. Mitigation: show truncated text in UI, but copy the full ID.

## Implementation Outline

1. Add provider-agnostic title fields and display helpers to session state.
2. Add a Codex title reader for `session_index.jsonl`.
3. Populate Codex session titles during discovery and later updates.
4. Update session card rendering to use title-first semantics.
5. Replace duplicate-only `#019d` display with a consistent session-ID control and copy action.
6. Add tests around Codex title parsing and fallback behavior.
