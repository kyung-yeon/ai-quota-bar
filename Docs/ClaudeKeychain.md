# Claude Keychain prompts

AiQuotaBar reads Claude Code's existing generic-password item, `Claude Code-credentials` (or the configured-directory-specific service), with the current macOS username. It requests only that item's data. The environment token override and Claude Code's existing `.credentials.json` fallback remain unchanged. No credentials are copied to a new store and no Keychain item or access-control list is written.

## Why prompts could repeat

The app reads the credential at launch, every five minutes, on wake, and on manual Refresh. These paths already passed `allowKeychainPrompt: false`; only **Allow Claude Code Keychain access…** passed true. The defect was in enforcing that policy: the query supplied a new `LAContext` with `interactionNotAllowed`, but Claude's traditional login-keychain item uses a legacy application ACL. Local Authentication context settings are not sufficient to suppress that legacy dialog. Apple documents the distinction in the Security SDK's `SecItem.h`; the legacy Security implementation does not interpret `kSecUseAuthenticationContext` as an ACL-dialog policy.

Permission can also need renewal independently of polling. Apple's [ACL documentation](https://developer.apple.com/documentation/security/access-control-lists) explains that **Allow** permits access while **Always Allow** adds the application to the item's trusted list. Local AiQuotaBar packaging uses ad-hoc signing. Read-only inspection of the installed app's designated requirement showed a `cdhash`, so a rebuilt binary can have a different identity. Changes to the credential item or its ACL can also invalidate a previous allowance. This investigation did not read the user's item, inspect its ACL, or establish which of these caused an individual permission reset.

## Prompt policy

All in-process Keychain reads now share a lock. A noninteractive read saves the legacy interaction state, disables it with `SecKeychainSetUserInteractionAllowed(false)`, performs the exact same `SecItemCopyMatching`, and restores the prior state before releasing the lock. The existing `LAContext.interactionNotAllowed` protection remains. If the interaction policy cannot be read or disabled, the protected Keychain read is skipped; existing fallback/error handling applies.

The legacy switch is process-wide, so the explicit **Allow** path also takes the lock. It does not force a previously disabled process policy on. No automatic failure retries with UI enabled. A denied or canceled explicit request returns to the usual **Keychain access required** state unless the existing credential-file fallback succeeds. Subsequent automatic refreshes stay noninteractive.

The legacy interaction API is deprecated, but remains the store-specific mechanism for suppressing login-keychain dialogs. Its use is narrowly scoped; it does not unlock a Keychain, grant access, alter an ACL, or bypass authentication. Reusing an authenticated `LAContext` would not repair a legacy app ACL, so no context or token cache is introduced. See Apple's [interaction API](https://developer.apple.com/documentation/security/seckeychainsetuserinteractionallowed(_:)) and [Security implementation](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_keychain/lib/SecKeychain.cpp).

Verification for this change is compilation and source review only. No real credential read, prompt experiment, permission change, or local installation was performed. Already-open system dialogs and prompts from Claude Code or another application are outside this app's read policy.
