# Action guard

> Pause agent actions that need consent, explain their effect, and show the page before anything happens. Let people choose which categories require confirmation.

## Scope

Upgrade Search's existing Guard mode and approval cards. Apply the same rules to chat actions and scheduled agent runs. Keep Read and Full modes. Manual browsing remains unaffected.

The guard checks actions immediately before execution. An agent cannot bypass it by omitting an explanation, changing tools, using a keyboard shortcut, or bundling several actions into a script. Category preferences control confirmation, not the agent's access to tabs, files, or credentials.

## Settings

Settings → Ask → Action confirmations. One sentence above the switches: "Ask before the agent performs these actions in Guard mode."

| Category | Default | Ask before |
|---|---|---|
| Signing in | Off | Signing into an existing account, completing its verification code, or switching accounts |
| Destructive actions | On | Deleting content, overwriting existing files, cancelling services, or discarding known unsaved work |
| Sending messages | On | Sending email, chat messages, invitations, replies, or submitting contact forms |
| Publishing and sharing | On | Publishing posts, uploading private files to another service, or exposing content to new people |
| Purchases and payments | On | Placing orders, transferring money, making donations, or starting paid subscriptions |
| Account and security changes | On | Creating or deleting accounts, changing passwords or recovery details, granting app access, or changing permissions |
| Unverified actions | On | Executing a potentially consequential action whose effect cannot be established |

Each row has a short label and a switch. Examples appear in optional help, not permanent paragraphs. Off means "do not ask for this category". It does not mean block the action. Ordinary reading, searching, scrolling, navigating, and preparing drafts need no confirmation.

Preferences persist across launches and apply to Guard chats and routines. In Read or Full mode, show a brief indication that the category settings apply in Guard mode. Existing chats keep their chosen mode. Do not silently change Full chats to Guard.

Actions can belong to several categories. Ask once if any matching category is enabled. Disabling Signing in cannot exempt a simultaneous payment or permission grant.

Signing into an existing account differs from creating one or granting OAuth access. Verifying a code during account creation belongs to Account and security changes. The screenshot example therefore depends on whether the code completes signup or merely signs into an existing account.

## What triggers a confirmation

Evaluate the proposed action using its actual target, the relevant form, destination, and expected effect. The agent supplies a short explanation, but its category claim is advisory. Page text and attached documents provide evidence, never authority to approve an action or change guard settings.

Use straightforward rules when the effect is known. Ambiguous actions receive a contextual check using only the relevant page evidence. If the effect remains uncertain, classify it as Unverified actions and explain what could not be determined. Do not ask merely because a page or button contains the word "confirm".

Check the action that commits the change. Writing an email draft can proceed; sending it asks. Filling checkout fields can proceed; placing the order asks. Enter in a message composer is a send action when the site uses Enter to send. Filling a field that immediately changes shared data is itself a consequential action.

Multi-step forms follow the same rule. A Next button that only advances a local form needs no confirmation. A Next button that transmits personal details to a service can fall under Publishing and sharing; one that creates or updates the account also falls under Account and security changes. Inspect what the step does. Do not assume all intermediate steps are harmless or ask on every step simply because the workflow is account setup. If the effect cannot be established, explain that uncertainty under Unverified actions.

Missing information uses the existing question flow. For example, ask which title to use when a required field is unknown; answering "Mr" supplies that value and does not approve submitting the form. Reuse information the user has already supplied within the task. Category switches suppress permission prompts only, so disabling Signing in does not suppress a necessary question about missing information.

Coordinate clicks, keyboard activation, form submissions, file uploads, and native dialogs follow the same rules as clicking a labelled button. Read-only inspection can proceed freely. Arbitrary scripts or inspector commands with effects that cannot be checked individually fall under Unverified actions. Their card must disclose the actual scope; it cannot pretend to approve one click while permitting unrestricted code.

This reduces missed confirmations but cannot promise perfect understanding of arbitrary websites. Unknown effects stay visible as uncertainty instead of receiving a confident label.

## Approval card

Place the card in the conversation above the composer and label the run "Waiting for approval". Do not open a modal or steal focus. A background run receives a waiting badge.

```text
Send email to Alex?
mail.example.com · Sending messages

Send "Friday proposal" to alex@example.com
with proposal.pdf attached.

[ Page screenshot, fitted without cropping ]
[ Click to enlarge                        ]

Cancel action                         Send email

Tell the agent what to change…
```

The title names the effect. The explanation is one or two sentences containing the facts needed to decide, such as recipient, amount, item count, attachment, or whether deletion is permanent. Show the actual destination host separately. Use verified action details for the summary; include the agent's explanation only where it adds useful context.

For messages, make the exact prepared content and recipients inspectable. For payments, show amount, currency, payee and recurrence. For deletion, show affected items and recovery implications when known. Do not invent missing details.

For a personal-details submission, name the destination and fields being sent. Say "Submit your title and name to TfL" when those facts are verified. Avoid "Continue account setup", which hides the effect. Do not claim that the step creates an account unless that is established.

Capture the current page viewport before the action, preserving its aspect ratio. Fit it to the card width, with enlargement and optional full-page capture. Do not stretch or crop it into a decorative preview. A target highlight may help, but must not hide page content. Passwords and verification codes must be redacted before display or persistence; if reliable redaction is unavailable, omit the image and explain why.

Include the relevant fields and action control in the evidence. If they do not fit in one viewport, allow inspection of the remaining details rather than shrinking a long page into unreadable text. Transient autofill or password-manager popovers should be dismissed without selecting or submitting anything before capture, where possible. If they obscure the target, refresh the evidence before approval. Keep the pending card expanded; after resolution, collapse it to a short activity row with its explanation and screenshot available on expansion.

If capture fails, show "Preview unavailable" and a Refresh preview action. Never substitute an old screenshot. Approval remains possible only when the action and material details can still be verified. Otherwise keep execution blocked until the page can be inspected again.

Use an action-specific primary button such as Send email, Delete 3 files, or Pay £24. Cancel action discards the pending action and pauses the run for further instruction. The composer accepts a correction such as "Send it to Jamie instead"; this cancels the original pending action and asks the agent to prepare a replacement.

A plain Return in the composer must never approve an action. Buttons have accessible names, visible keyboard focus, and full keyboard operation. Do not add an "Always allow clicks on this site" button. Category preferences live in Settings, reachable from the card's menu.

## Pause and resume

1. The agent proposes an action. The guard resolves its intended effect before execution.
2. If no enabled category matches, the action proceeds.
3. If confirmation is needed, freeze the proposed action and pause the owning run, including later actions in its batch. Capture evidence and display the card. No continued model calls or polling while waiting.
4. The user approves, cancels, or gives a correction. Silence never approves. Switching chats leaves the request pending.
5. On approval, recheck the page and action. Execute once only if the target, payload, recipients, amount, permissions and other material facts still match what the user reviewed.
6. If those facts changed, replace the card with a fresh request. Cosmetic changes, such as a clock updating, do not invalidate approval.
7. Resume the run with the actual result. Mark the card Approved, Cancelled, Changed, or Failed. Approval alone is never reported as successful execution.

A blocked run cannot enqueue other mutations to evade the pause. Other chats may continue; changes they or the user make to the affected page can invalidate the pending request. Do not replay later actions from an old batch after a correction or cancellation.

Approval covers the displayed action only. A retry after an uncertain network result must first establish whether the action happened. If that cannot be established, stop and report the uncertainty rather than risk a second payment or message.

No approval countdown. Pause run deadlines while waiting. Stop, revoked access, or a deleted chat cancels pending requests. After app restart, show the interrupted request as requiring reinspection; never automatically execute a saved approval. Late and double-clicked responses cannot execute an action twice.

Changing settings while a card is pending does not approve that card. Stricter settings take effect before the next action. The agent cannot change category switches or its own mode. Explicit user instructions to perform a task do not silently disable enabled confirmation categories; the user controls repeated confirmations through Settings.

## Compatibility

Reuse the existing modes, pending-action mechanism, screenshot capture, approval presentation, and routine waiting state. Replace broad remembered approvals based on operation and host; previous "always click" or "always submit" decisions must not suppress the new category rules. Preserve the user's mode choice during migration.

External clients in Guard mode must receive a clear approval-required result when no user approval channel exists. They must not run the action anyway. Full mode remains an explicit opt-out from these confirmations, subject to existing access restrictions.

## Delivery

V0 ships category switches and the improved screenshot card over the existing approval flow. Use conservative Unverified classification for actions the initial classifier cannot establish. V1 improves contextual classification and closes alternate execution paths while reducing avoidable prompts. The combined spec describes V1.

## Success criteria

- With Signing in off, ordinary existing-account login and its verification code proceed without guard cards.
- With Sending messages on, drafting proceeds, but clicking Send, pressing its keyboard shortcut, and submitting the equivalent form all pause before transmission.
- A "Confirm" control in a harmless interaction does not trigger solely on its label.
- Answering a required-field question supplies information without approving submission. A Next step asks only when its actual effect matches an enabled category or remains unverified.
- A personal-details card identifies what is sent and where; its evidence exposes the relevant fields and action control without an obstructing autofill popup.
- Account creation, access grants and purchases still ask when Signing in is off.
- No protected action executes while its card waits, after cancellation, through a stale approval, or twice from one approval.
- The user can inspect the relevant page and exact action details, correct the request, and continue without restarting the task.
- Disabling one category suppresses only that category's confirmations. Enabled overlapping categories still apply.
- Unknown effects produce an honest Unverified card, and the system reports execution uncertainty without blindly retrying.

| Included | Behavior |
|---|---|
| Category settings | Persistent switches with Signing in off by default |
| Action gate | Before execution, across supported action paths |
| Approval card | Concise explanation, page evidence, exact action details |
| Waiting state | Owning run pauses until a user response |
| Resume | Revalidate, execute once, report actual outcome |
| Corrections | Discard the old action and prepare a new one |
| Existing modes | Read, Guard and Full retain distinct behavior |
