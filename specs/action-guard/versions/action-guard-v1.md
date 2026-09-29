# Action guard V1

> Catch consequential actions across browser interaction methods while reducing unnecessary confirmations.

## Scope and behavior

Include V0. Add contextual checking for ambiguous actions using the resolved target, surrounding form, intended destination and relevant page evidence. The agent's explanation is advisory. Page content cannot approve actions or change preferences.

Apply categories consistently to Enter-to-send, shortcuts, coordinate clicks, uploads, dialogs and immediate-save fields. Individually check effects in compound operations where supported. Unrestricted scripts whose effects cannot be inspected remain Unverified actions, with their full scope disclosed.

Distinguish existing-account authentication from signup, access grants and security changes. Distinguish draft preparation from sending or publishing. Ask once when several enabled categories overlap.

Judge intermediate form steps by their effect. Local Next steps proceed; transmitting personal details or changing an account follows the matching category settings. Unknown effects remain Unverified. Required-field questions stay separate from approvals: answering a title question supplies the value without consenting to submission.

## UI and edge cases

Keep the V0 card. Improve explanations to show verified recipients, message content, payment terms or affected items. Unknown facts stay visibly unknown. Cosmetic page changes do not trigger another card; changes to material action details do.

Personal-details cards name the fields and destination. Evidence must make the relevant fields and action control inspectable, without obstructing autofill popovers. Pending cards stay expanded; resolved cards collapse to an activity row with expandable evidence.

Other runs can continue while one waits, but cannot make its approval valid for changed page state. Settings changes never silently execute a pending action. Scheduled runs use the same decisions and waiting behavior. Clients without an approval channel receive an approval-required result.

## Not included

Site-wide trust lists, custom user-written policy rules, compliance dashboards, and claims of perfect website classification.

## Success criteria

Equivalent sends trigger the same category across supported input methods. Harmless confirmation labels do not produce warnings on their own. Disabling authentication prompts leaves enabled security and payment prompts intact. Approvals remain bound to reviewed facts, and uncertain execution never triggers a blind retry.
