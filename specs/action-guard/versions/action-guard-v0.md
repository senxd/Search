# Action guard V0

> Make the existing Guard mode configurable and its approvals useful enough to review.

## Scope and behavior

Reuse the existing pause and approval flow. Add persistent switches for Signing in, Destructive actions, Sending messages, Publishing and sharing, Purchases and payments, Account and security changes, and Unverified actions. Signing in defaults off; the others default on. Read and Full retain their behavior.

Classify well-understood actions using their resolved target and form context. Ask under Unverified actions when the effect cannot be established. Any enabled matching category requires one confirmation. Do not treat every "confirm" label as destructive.

Show an action-specific title, a short explanation, the destination host, inspectable material details, and a fitted page screenshot with enlargement. Provide an action-specific approval button, Cancel action, and correction through the composer. Category changes belong in Settings. Remove broad operation-and-host "Always" exemptions.

## Edge cases

Pause the whole owning run and later batch actions. No automatic approval or countdown. Revalidate material facts before executing once. Cancellation stops the proposed action. A correction discards the old batch. Changed facts require fresh approval. Restart, lost access and Stop cannot revive old approvals. Unknown execution outcomes require inspection before retry.

Redact credentials in screenshots. If capture or safe redaction fails, show the limitation and allow approval only when the action's material details remain verifiable. Opaque scripts receive an Unverified card disclosing their scope.

## Deferred

Contextual classification for ambiguous interfaces and detailed coverage of alternate action paths ship in V1. V0 conservatively asks on unresolved potentially consequential actions.

## Success criteria

Known existing-account sign-ins proceed with their category off. Known sends and deletions pause with their categories on. Screenshots remain legible, cancellation prevents execution, stale approvals cannot run, and opaque actions do not bypass the gate.
