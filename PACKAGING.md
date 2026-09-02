# Packaging a release

Verified against PrusaSlicer 3.0.0-alpha11 on macOS.

```bash
PS=/Applications/PrusaSlicer-3.0.0-alpha11.app/Contents/MacOS/PrusaSlicer
```

## Signing key (one-time, already done)

```bash
"$PS" plugin keygen -P ~/.prusaslicer-plugin-keys/hyiger.private.pem -p keys/hyiger.pem
```

`-P` is the **private** key and `-p` the public one — note the help text has them
swapped in its descriptions. Default size is RSA-2048 (`-k` accepts a
power of two in [1024, 8192]).

The private key is at `~/.prusaslicer-plugin-keys/hyiger.private.pem`, mode 600,
deliberately outside this tree. Keep it secret and back it up. The public key
`keys/hyiger.pem` is the one you distribute; its filename **must** match the
`author` field in `manifest.json`, because `AuthorRegistry` looks it up as
`<author>.pem`.

## Sign and zip (every release)

```bash
"$PS" plugin sign -P ~/.prusaslicer-plugin-keys/hyiger.private.pem com.hyiger.slicer.calibration
```

This validates `manifest.json`, writes `manifest.txt` (SHA-256 of every payload
file) and `manifest.sign` (RSA-SHA256 over `manifest.txt`) *into the bundle
directory*, then writes `com.hyiger.slicer.calibration.zip` into the current
working directory. Bump `version` in `manifest.json` first.

Payload filenames must match `[a-zA-Z0-9.-_ ]+` or signing aborts.

Verify independently at any time:

```bash
openssl dgst -sha256 -verify keys/hyiger.pem \
  -signature com.hyiger.slicer.calibration/manifest.sign \
  com.hyiger.slicer.calibration/manifest.txt
```

## Installing

The recipient needs the public key trusted once, then the bundle:

```bash
D=~/Library/Application\ Support/PrusaSlicer3-dev
cp keys/hyiger.pem "$D/authorized_authors/hyiger.pem"
```

Then either import `com.hyiger.slicer.calibration.zip` from the Plugins menu, or
for development skip signing entirely and symlink the bundle directory:

```bash
ln -s "$PWD/com.hyiger.slicer.calibration" "$D/lua/com.hyiger.slicer.calibration"
```

Either way, finish with **Plugins → Rescan**. Note `PrusaSlicer3-dev` is the
alpha's data dir; the 2.9 fork uses `PrusaSlicer`.

## What the scan logs

Only failures. A bundle that loads cleanly produces no log line at all, so to
confirm the scan is reaching your directory, drop in a folder with no
`manifest.json` and look for `is not a plugin bundle` from `PluginRegistry.cpp`:

```bash
"$PS" --loglevel 4 2>&1 | grep -E "PluginBundle|PluginRegistry"
```
