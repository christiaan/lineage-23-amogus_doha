# OTA feed for LineageOS 24.0 on the Moto G8 Plus (amogus_doha)

The Updater app on this ROM reads `amogus_doha.json` from this branch
(`lineage.updater.uri`, set by `build.sh`) and offers the build it lists
when that's newer than the one installed. The zip itself is downloaded
from the GitHub release.

The file is written by `ota-json.py` (on the `lineage-24.0` branch) after
each release's zip is uploaded:

```
./ota-json.py lineage-24.0-<date>-UNOFFICIAL-amogus_doha.zip <tag> -o amogus_doha.json
```

Nothing else belongs on this branch. Builds before the first one with
`lineage.updater.uri` (v2.0.0, v2.0.1) don't check this feed; update
those once with `adb sideload`.
