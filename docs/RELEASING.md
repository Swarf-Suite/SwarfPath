# Releasing SwarfPath

A release is a universal **SwarfPath.app**, signed with a Developer ID and notarized, in two forms:
**SwarfPath.dmg** (what people download) and **SwarfPath.zip** (what Sparkle downloads to update an installed
copy), plus **appcast.xml** (what Sparkle checks). GitHub Actions builds them for free (the repository is public).
It's the same pipeline as SwarfGRBL's (`Swarf-Suite/SwarfGRBL`, `docs/RELEASING.md`), with the same certificate,
notary key and Sparkle key.

## Before tagging a release

1. `swift test -c release` passes on the commit you'll tag.
2. `scripts/build-app.sh` and try the app: import an STL, Full Processing, Simulate (no gouges), Export.
3. Anything new: check its output in the simulator and, for anything that changes toolpaths, air-cut it first.
4. From the second release on: after it's out, an installed copy of the previous release shows the update
   (**SwarfPath → Check for Updates…**) and installs it.

## Making a release

```sh
git tag v0.2
git push origin v0.2
```

`.github/workflows/release.yml` runs the tests and `scripts/release.sh 0.2`, and makes the GitHub Release with
generated notes. The version comes from the tag; the build number is the commit time, so Sparkle always treats a
later release as newer.

- **Signed and notarized** (all the secrets below are set): published as the latest release, so the download link
  and every installed copy's update check pick it up straight away.
- **Anything missing**: left as a **draft** with a warning in the run. Nobody can download or update to it. Delete
  the draft and the tag, fix the secrets, and tag again.

**Actions → Release → Run workflow** builds a version without publishing anything (the files are kept as the run's
artifact). `scripts/release.sh 0.2` does the same on a Mac, into `dist/`; `dist/release.env` says whether it was
signed, notarized and given an appcast. To notarize locally, set `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and
`NOTARY_ISSUER_ID`; for the appcast, `SPARKLE_ED_PRIVATE_KEY`.

If a run fails with "The job was not acquired by Runner", `.github/workflows/retry.yml` re-runs it by itself.

## Links

| What | URL |
|---|---|
| Download (always the latest release) | `https://github.com/Swarf-Suite/SwarfPath/releases/latest/download/SwarfPath.dmg` |
| Release notes | `https://github.com/Swarf-Suite/SwarfPath/releases/latest` |
| Sparkle feed (baked into the app) | `https://github.com/Swarf-Suite/SwarfPath/releases/latest/download/appcast.xml` |

The feed URL is in every installed copy's Info.plist, so it mustn't change.

## Secrets

In **Settings → Secrets and variables → Actions**, or with `gh secret set NAME -R Swarf-Suite/SwarfPath`. Pull
requests from forks can't read them.

| Secret | What |
|---|---|
| `SPARKLE_ED_PRIVATE_KEY` | Signs each update. Its public half is `scripts/sparkle-public-key.txt`, baked into the app |
| `MACOS_CERT_P12` | The Developer ID Application certificate and its private key, as a base64 `.p12` |
| `MACOS_CERT_PASSWORD` | The `.p12`'s password |
| `NOTARY_KEY_P8` | An App Store Connect API key (the `.p8` file's text) for notarization |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the keys list |

They're the same values as SwarfGRBL's. The Sparkle private key is in the design Mac's login keychain (account
`kerfline`); **never lose it**, or installed copies can't be updated.
