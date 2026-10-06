# rpms/ — edge-site-config

A small noarch RPM that carries everything site-specific, so the OS image
stays generic and a site change is "bump a release, rebuild, `bootc upgrade`".

| File installed | Purpose |
|---|---|
| `/etc/rancher/rke2/config.yaml` | single-node server, `write-kubeconfig-mode: "0644"`, `selinux: true`, `tls-san` localhost/127.0.0.1 |
| `/etc/rancher/rke2/registries.yaml` | `docker.io` mirror `http://10.0.2.2:30080` with `rewrite "^(.*)$" -> "oci-dockerhub-proxy/$1"` |
| `/etc/containers/registries.conf.d/50-artifact-keeper.conf` | `10.0.2.2:30080` insecure, for `bootc upgrade`/`switch` |
| `/etc/NetworkManager/conf.d/rke2-canal.conf` | NetworkManager ignores CNI interfaces (RKE2 known issue) |
| `/etc/motd.d/edge` | MOTD with the package version-release (day-2 is visible at login) |
| `/usr/share/edge-site/manifests/nginx-demo.yaml` | Deployment + NodePort Service (30090), `docker.io/library/nginx:alpine` |
| `/usr/lib/systemd/system/edge-site-manifests.service` | oneshot, `Before=rke2-server.service`, copies the manifests into `/var/lib/rancher/rke2/server/manifests/` on every boot |
| `/usr/lib/systemd/system-preset/80-edge-site.preset` | enables the oneshot |

Release 1 vs 2 differ only in the MOTD note and the `edge-site/config-release`
label on the nginx Deployment/pod template/Service (`--define "rel N"`).
Releases 3 and 4 are the same content as 1 and 2 (3 = baseline MOTD,
4 = day-2 MOTD; the label carries the release number) but **signed**; uploads are
write-once per file name, so signed content needed new release numbers.
`Requires: rke2-server`.

## Signing

`build.sh` signs every RPM it builds with the edge RPM key (`signing/gen-keys.sh`,
RSA 4096, `Edge Site Signing <edge@example.invalid>`, fingerprint in
`signing/keys/pub/RPM-GPG-KEY-edge.fingerprint`):

- `rpm-sign` and `gnupg2` are installed in the builder container (from the AK Rocky proxies, gpg-checked);
- `signing/keys/gnupg` is mounted **read-only** and copied into a throwaway `GNUPGHOME`
  inside the container (gpg wants a writable homedir for its agent socket);
- `rpmsign --addsign --define "_gpg_name <fingerprint>"`, then `rpm --import` of the public
  key and `rpm -K`, which must print `digests signatures OK` or the build fails.

```
/out/edge-site-config-1.0-3.el10.noarch.rpm: digests signatures OK
  edge-site-config-1.0-3.el10.noarch signature: RSA/SHA256, ..., Key ID 765cd686c1f8f57d
```

On EL10 use `%{RSAHEADER:pgpsig}` to print the signature; `%{SIGPGP}` stays `(none)`.
Consumers verify with `gpgcheck=1` (key: `raw-edge-keys/RPM-GPG-KEY-edge`); the repo's
metadata is signed by Artifact Keeper (`repo_gpgcheck=1`, key: `repodata/repomd.xml.key`).
An unsigned release is refused by dnf: `Package edge-site-config-1.0-1.el10.noarch.rpm is not signed`.

## Usage

```bash
make rpm                 # = rpms/build.sh && rpms/upload.sh (releases 3 and 4)
RELEASES=5 rpms/build.sh # another release (add a %changelog entry)
```

- `build.sh`: `rpmbuild` + `rpmsign` inside `localhost:30080/oci-quay-proxy/rockylinux/rockylinux:10`
  (rootless), dnf restricted to the Artifact Keeper Rocky proxies. Output in `rpms/out/`.
  Needs `make keys` first. Rebuilding produces different bytes (rpmbuild and signatures are
  not reproducible), so do not rebuild a release that is already uploaded.
- `upload.sh`: `PUT /rpm/rpm-edge-site/packages/<file>` with the CI token, then
  reads the server-generated `repodata/primary.xml.gz` and fails unless every
  uploaded release is listed. An existing file returns HTTP 409 and is left
  as is (Artifact Keeper does not overwrite; bump the release instead).
