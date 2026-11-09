# Jellyfin for moj.tv

Stock Jellyfin from the official apt repository, plus two changes, rebuilt automatically for every new Jellyfin release:

- **Recently Added options** from [jellyfin/jellyfin#18381](https://github.com/jellyfin/jellyfin/pull/18381) (by theguymadmax, not merged upstream yet): server settings `DisplayLatestSeasons` and `DisplayLatestEpisodes`. With both off, Recently Added in TV libraries always shows the whole show, with its number of unwatched episodes, like Emby does. With both on, it behaves like stock Jellyfin 12.
- **Two checkboxes** for them in *Dashboard → Libraries → Display* (web change in `patches/jellyfin-web`), with Croatian texts, plus a corrected Croatian label for "Group shows into collections".

Built with help from Claude (Anthropic).

## How it works

1. **`patches/`** holds the changes. `patches/jellyfin/*.patch` are the commits of #18381 with their author kept. `patches/jellyfin-web/*.patch` is the display settings page; its texts are merged from `patches/jellyfin-web/strings/*.json` at build time, so translation updates upstream never break the patch.
2. **GitHub Actions** (`.github/workflows/build.yml`) checks every hour for a new Jellyfin release. It builds it with `scripts/build.sh` (patches, server tests, Linux build, web build) and publishes release `v<version>` with `jellyfin-patch-<version>.tar.gz`. When a patch no longer applies, the run fails and GitHub emails you. When upstream includes a change, the build leaves that part out by itself. Every run also re-enables the workflow, because GitHub stops the schedule of a public repository after 60 days without commits.
3. **On the server** Jellyfin stays installed by apt, and dash updates it as before. A systemd drop-in runs `/usr/local/sbin/jellyfin-patch prepare` before every start. For the installed version it downloads the matching build and assembles `/var/lib/jellyfin-patch/run`: hard links to `/usr/lib/jellyfin/bin` with the patched assemblies swapped in, plus the patched web client. No file of the Jellyfin packages is changed. When there is no build for the installed version, stock Jellyfin starts. If a patched build crashes twice within five minutes of starting, the following starts are stock until another build arrives or `jellyfin-patch enable` is run.

## Updating Jellyfin

Nothing changes: update from dash (or apt). On the first start of the new version the server downloads its patched build. If you update within the first hour after a release, before the build exists, Jellyfin runs stock until it is restarted after the build appears (Restart on dash's Servers page; `jellyfin-patch status` shows which one is running).

## Server install (one time)

```bash
install -m 0755 server/jellyfin-patch /usr/local/sbin/jellyfin-patch
install -D -m 0644 server/zz-jellyfin-patch.conf /etc/systemd/system/jellyfin.service.d/zz-jellyfin-patch.conf
systemctl daemon-reload
jellyfin-patch fetch
systemctl restart jellyfin
jellyfin-patch status
```

`/etc/jellyfin-patch.conf` may set `REPO=owner/name` if the builds live in another GitHub repository. A build can also be added from a file with `jellyfin-patch add jellyfin-patch-12.4.tar.gz` (with its `.sha256` next to it).

## Going back to stock Jellyfin

- For a while: `jellyfin-patch disable && systemctl restart jellyfin` (`enable` undoes it).
- For good: delete `/etc/systemd/system/jellyfin.service.d/zz-jellyfin-patch.conf`, `systemctl daemon-reload`, `systemctl restart jellyfin`.

The settings stay in `/etc/jellyfin/system.xml`; stock Jellyfin ignores them.

## When a patch stops applying

In checkouts at the new tag: `git am -3 patches/jellyfin/*.patch` (or `patches/jellyfin-web/*.patch`), resolve the conflicts, build and test, then replace the patch files with `git format-patch v<version>..HEAD`. If upstream has merged the change in another form, delete the patch instead.

## Development

`jellyfin/` and `jellyfin-web/` are working checkouts (ignored by git). `scripts/demo/` has a demo library generator, a script that sets up a throwaway local server and prints Recently Added for each option combination, and the screenshot script used for the upstream PR.

Jellyfin is licensed under GPL-2.0; the builds published here are made from the upstream sources plus the patches in this repository.
