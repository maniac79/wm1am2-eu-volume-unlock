# Review findings addressed in 0.2.3 source

This is an implementation map, not a claim of publication or hardware
acceptance. IDs refer to the 25 October 2026 review. Source changes must still
pass the final integration tests and artifact review. No 0.2.3 physical device
run, manual rollback, or listening acceptance is claimed here.

| Review ID | 0.2.3 treatment | Remaining boundary |
|---|---|---|
| U1 | Adjacent Platform Tools lookup and explicit menu/CLI helper install; no implicit installation on status/read/apply. | Check extracted final ZIPs on each host OS. |
| C1 | Installed APK pulled and byte-compared with bundled APK; bundle checked against adjacent provenance hash before privileged spawn. | Trust in published package needs external release hash and signer verification. |
| C2 | Both settings list/get must confirm the key absent; query errors stop before mutation. | Pre-existing present/uncertain keys are refused, not auto-repaired. |
| C3–C4 | Exit/signal and PowerShell finally cleanup check the setting and remote payload; cleanup failure wins with recovery exit 7 and retained record/lock. | SIGKILL, power loss, USB loss and real-device interruption still need separate assessment. |
| C5 | Per-phase unique remote payload plus atomic device-wide lock across privileged phases. | A stale/interrupted lock requires deliberate manual inspection; no blind automatic unlock. |
| C6 | Only verifiably absent setting state is accepted; existing custom/empty/literal-null values are not round-tripped or overwritten. | This intentionally narrows supported preflight state. |
| C7 | Restore's accepted-current-value guard remains fail-closed. Error help and manual plan explain that damaged partial fields may require Sony service or separately designed recovery. | No claim that every partial write is recoverable. |
| U2–U3 | Docs distinguish reference-value `baseline`, modified-state `snapshot` and independently proven unit-original values; test plan separates return routes. | External historical original records were not sought or judged here. |
| U4 | Status documented as property-only; QUICKSTART names `vendor.safe_volume.enabled` correctly. | Status alone does not verify firmware or loaded DAC table. |
| U5 | Firmware-update and reset advice requires full state review; no automatic/prescriptive updater or Play Store disable. Provenance limits current hardware claims. | Firmware changes and factory reset behavior remain untested. |
| U6 | External release ZIP hashes, internal manifest and APK signer are distinguished; local script trust prompts described as a user decision. | Final hashes must be filled after final release asset readback. |
| U7 | Explicit `local` and `ci` signing modes allow private nonrelease builds; default release mode retains maintainer certificate pin. | Other certificates cannot upgrade a release-signed installed app. |
| R1 | CI candidate packaging and extracted package-path tests select `-ci.zip` explicitly as an intended release gate. | CI/mock success is not physical device validation; CI archives are not official assets. |
| R2 | Build receipt and package-input verification bind APK metadata, signer, source/build inputs and Git state; only clean eligible release archives use the unsuffixed official name. CI/local/dirty builds carry visible suffixes. | `SOURCE-COMMIT.txt` records signing mode, certificate SHA-256 and release eligibility; this is provenance evidence, not independent bit-for-bit reproduction. |
| R3 | Signing password uses environment/file references instead of literal process arguments. | Key material still requires private storage and careful custody. |

The eight target/reference NVRAM field values and schema 1 backup format were
not changed for this release. The original manual method was reported
successful on one device, while macOS, Windows and Linux 0.2.3 tool runs on
hardware remain untested. `README.md`, `QUICKSTART.txt`, `SIGNING.md` and the
manual test plan contain the user-facing operational details.
