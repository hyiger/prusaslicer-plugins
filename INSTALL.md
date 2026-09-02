# Installing this plugin

For **PrusaSlicer 3.0.0-alpha11**. Two routes — pick one.

## Find your configuration folder first

Both routes need it. In PrusaSlicer: **Help → Show Configuration Folder**.

On macOS it is `~/Library/Application Support/PrusaSlicer3-dev`. The folder name
differs between builds and platforms, so use the menu item rather than typing a
path from memory — the alpha does *not* share a folder with PrusaSlicer 2.x.

## Route A — signed bundle (verifies integrity)

The signed `.zip` will **not** install on its own. PrusaSlicer checks the
signature against a public key it already trusts, and if that key is missing you
get:

> Plugin installation failed: Cannot load public key for author hyiger

There is no in-app way to add the key in alpha11 — `AuthorRegistry::store_author_key()`
exists in the source but has no callers, so the file has to be placed by hand,
once. After that, every future release from the same author installs normally.

1. Copy `hyiger.pem` into the `authorized_authors` folder inside your
   configuration folder (the folder already exists; it starts out empty).
2. Restart PrusaSlicer.
3. Install `com.hyiger.slicer.calibration.zip` from the Plugins menu.
4. **Plugins → Rescan**.

macOS, in one line:

```bash
cp hyiger.pem ~/Library/Application\ Support/PrusaSlicer3-dev/authorized_authors/
```

The filename must stay exactly `hyiger.pem` — it is looked up as
`<author>.pem`, where `author` is the field in the bundle's `manifest.json`.

## Route B — unzip it yourself (no key needed)

`PluginRegistry::scan()` does not check signatures; only the zip-import path
does. So a bundle unpacked straight into the `lua` folder loads with no key at
all:

```bash
mkdir -p "<config folder>/lua/com.hyiger.slicer.calibration"
unzip com.hyiger.slicer.calibration.zip -d "<config folder>/lua/com.hyiger.slicer.calibration"
```

Then **Plugins → Rescan**. Faster, but nothing verifies the files were not
altered in transit — which matters here, because a plugin is code that runs on
your machine.

## Which to use

Route A only means something if you get `hyiger.pem` from somewhere the plugin
zip does *not* come from. Downloading both from the same page proves little: an
attacker who can swap one can swap the other. Its real value is over time — the
key is installed once, and every later release is checked against it, so a
tampered *update* is caught.

## Verifying by hand

```bash
unzip -o com.hyiger.slicer.calibration.zip -d bundle
openssl dgst -sha256 -verify hyiger.pem \
  -signature bundle/manifest.sign bundle/manifest.txt   # -> "Verified OK"
shasum -a 256 -c bundle/manifest.txt                     # payload matches
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Cannot load public key for author hyiger` | `hyiger.pem` missing from `authorized_authors`, or misnamed |
| `Integrity verification failed` | The zip was modified after signing, or the key does not match it |
| Installs, but no menu entry | Rescan not run, or the bundle landed a level too deep — `manifest.json` must sit directly inside `lua/com.hyiger.slicer.calibration/` |
| Nothing happens on Run | Plugin errors are only written to the log, never shown. Run with `--loglevel 4` and grep for `pa_tower` |
