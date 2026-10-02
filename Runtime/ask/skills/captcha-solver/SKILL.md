---
name: captcha-solver
description: Interact with a visible CAPTCHA or verification checkbox encountered while completing the user's browser task.
---

# CAPTCHA interaction

When the user's task encounters a CAPTCHA, Turnstile, reCAPTCHA, hCaptcha, or "Verify you are human" checkbox in a tab you can drive, inspect it and use the browser tools to complete the visible interaction.

Take a `snapshot` first. Verification controls often live in cross-origin frames or closed shadow roots and are absent from the snapshot. An empty tree does not mean the checkbox is unavailable. Take a `screenshot` to see it.

For a visible verification checkbox, call `captcha_click` with the tab and the checkbox center in CSS viewport coordinates. This sends a native mouse click, including inside frames. Screenshot coordinates match CSS coordinates at scale 1; otherwise divide image coordinates by the returned scale. Use `click` or `check` when a usable ref exists. For other visible challenges, use the existing screenshot, click, drag, and type tools as appropriate.

Wait for verification, then take a fresh snapshot or screenshot. Confirm a success indicator or the destination page before reporting completion. If the click missed, inspect a fresh screenshot and correct the coordinates. If verification fails repeatedly or requires information you lack, report the observed blocker and ask the user for help. Preserve tool denials and tab permissions. Do not change challenge code, inject verification tokens, or claim success without observing it.
