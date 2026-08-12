# Provisioning profiles

Two, because CloudKit has two containers and reaching the wrong one is a
signing question rather than a setting.

A provisioning profile is not a secret. It carries no private key, only a
statement from Apple about what this App ID is allowed to claim, and the
certificate that claim is bound to. Committing them means a clean checkout can
build a signed app without a trip to the portal.

| file | signs with | reaches | expires |
|---|---|---|---|
| `Listen_Developer_ID.provisionprofile` | Developer ID Application | **Production** only | 2044-08-07 |
| `Listen_Mac_Development.provisionprofile` | Apple Development | Production or Development | **2027-08-12** |

`make_app.sh` embeds one of these as `Contents/embedded.provisionprofile` before
the outer signature, chosen by `LISTEN_CLOUDKIT_ENV`. Production is the default,
because the shipping build is the one that must never be got wrong.

## Why a Developer ID app needs a profile at all

`com.apple.developer.icloud-services` is a restricted entitlement. codesign
will only accept one that a profile vouches for, and until this directory
existed `make_app.sh` signed with `--entitlements` and no profile at all, which
is precisely the configuration that cannot carry it.

## Two things measured from these files rather than assumed

**The container is actually attached.** An App ID with iCloud enabled and no
container selected passes every screen in the portal and produces a profile
carrying the entitlement with nothing behind it. Both of these name
`iCloud.eu.jacarandalabs.listen` in `icloud-container-identifiers`.

**`keychain-access-groups` is `BUZ45YDWYN.*`**, a team wildcard. That answers a
question the migration plan left open: the shared iCloud Keychain item that
`com.mgo.listen` and `eu.jacarandalabs.listen` both read needs no separate
capability in the portal, because any group under the team prefix is already
covered. Without it the symptom would have been the second Mac signing in and
no key ever arriving.

## The one that will expire

The development profile has a year on it; the Developer ID one has eighteen.
So the expiry check in `release.sh`'s preflight is really about catching the
day the development profile lapses, which will present as Phase 3's scratch
libraries failing to reach the Development container for no visible reason.
Renew it in the portal and replace the file here; nothing else changes.
