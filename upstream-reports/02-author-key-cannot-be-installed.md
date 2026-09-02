# Docs: `Plugin_API.md` never says where a recipient installs the author public key

**Version:** 3.0.0-alpha11 (`6f510128d7`) · **Type:** documentation, with a UX suggestion · **Severity:** low

## Summary

The signed-bundle flow works, but the documentation stops one step short. It tells
an author to distribute `<author>.pem` and never tells the recipient what to do
with it. Every first-time recipient hits an error message that does not name the
file, the folder, or the required filename.

## What the docs say

`doc/Plugin_API.md`, "Plugin distribution":

> You will need to distribute your *public* key named as `<author>.pem`, where
> `<author>` is value of `author` field in `manifest.json` file. The *public key*
> file distribution is again a one-time action.

That is the last mention of the key. The string `authorized_authors` does not
appear anywhere in `doc/`.

## What a recipient sees

Installing a correctly signed zip without the key present:

> Plugin installation failed: Cannot load public key for author `<author>`

The message does not say that a key file is expected, where it goes, or what it
must be named. `PluginRegistry::install()` (`PluginRegistry.cpp:129`) reads
`<data_dir>/authorized_authors/<author>.pem`; a missing file throws
`CryptoException`, which becomes the text above.

## The missing step

Copy `<author>.pem` into `<data_dir>/authorized_authors/`, restart, then install.
The filename must match the `author` field in `manifest.json` exactly, since that
is the lookup key.

## Suggested fix

Add that step to `Plugin_API.md`, including how to find the data directory
(Help → Show Configuration Folder), and extend the error message to name the
expected path.

## Optional, beyond the docs

`AuthorRegistry::store_author_key()` exists but has no callers anywhere in the
tree — only its declaration (`AuthorRegistry.hpp:17`) and definition
(`AuthorRegistry.cpp:13`). If a key-import UI was intended, a prompt to trust the
bundle's key on first install — showing a fingerprint the user can compare
against one published out of band — would be a better trust bootstrap than
copying a file into a config folder, where nothing is displayed to compare.

One related observation, offered as a design note rather than a defect:
`PluginRegistry::scan()` never calls `verify()` and never consults the
`AuthorRegistry`, so a bundle unpacked directly into `<data_dir>/lua/` loads with
no signature check. (Verified by removing the key and confirming the bundle still
loaded.) That is presumably deliberate, so that local development needs no
signing — but it does mean the unsigned route is the path of least resistance,
which may not be the intended incentive.

## Caveat on this report

The failure mode above is reproduced and certain. The fix — that placing the file
makes the import succeed — is read from `install()` rather than observed; we have
exercised the directory-scan path extensively but not the GUI zip-import path.
