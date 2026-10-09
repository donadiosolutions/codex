# Configuration

For basic configuration instructions, see [this documentation](https://developers.openai.com/codex/config-basic).

For advanced configuration instructions, see [this documentation](https://developers.openai.com/codex/config-advanced).

For a full configuration reference, see [this documentation](https://developers.openai.com/codex/config-reference).

## Multi-agent v2 message delivery

This fork adds an opt-in delivery setting; encrypted delivery remains the default.
To send new delegation tasks,
follow-up tasks, and direct messages as readable plaintext, set:

```toml
[features.multi_agent_v2]
enabled = true
message_delivery = "plaintext"
```

Plaintext delivery also enables readable collaboration logs and is inherited by
subagents. It affects new messages only; it does not decrypt existing messages.
The tool namespace defaults to `agents` for plaintext delivery and `collaboration`
for encrypted delivery. A custom `tool_namespace` is allowed, but plaintext
delivery cannot use the reserved `collaboration` namespace. Omit `tool_namespace`
or set it to `agents` when switching to plaintext.

## Lifecycle hooks

Admins can set top-level `allow_managed_hooks_only = true` in
`requirements.toml` to ignore user, project, and session hook configs while
still allowing managed hooks from requirements and managed config layers. This
setting is only supported in `requirements.toml`; putting it in `config.toml`
does not enable managed-hooks-only mode.
