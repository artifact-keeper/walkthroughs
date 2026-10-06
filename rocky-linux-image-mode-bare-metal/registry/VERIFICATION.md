# Verification: Artifact Keeper registry layer

Run on 2026-10-06 (UTC) on a Fedora 44 host, **rootless podman 5.8.7**
(netavark + pasta), `podman compose` delegating to docker-compose v5.5.1.
Artifact Keeper backend 1.10.2, web 1.10.1. No sudo was used anywhere.
All commands are run from `registry/`. Secrets are never shown; the CI token is
read from `.ak-token`.

## 0. Stack up + bootstrap

```console
$ ./up.sh
up.sh: generating .../registry/.env
...
 Container artifact-keeper-opensearch Healthy
 Container artifact-keeper-db Healthy
 Container artifact-keeper-backend Started
 Container artifact-keeper-web Started
 Container artifact-keeper-caddy Started
up.sh: waiting for http://localhost:30080/readyz . ready
{"status":"ready","checks":{"database":{"status":"healthy"},"migrations":{"status":"healthy"},"setup_complete":{"status":"complete"}}}
```

Cold start including image pulls: ~60 s to `/readyz` = ready. `./down.sh` then
`./up.sh` again: ready on the first 5 s poll, data preserved.

```console
$ ./bootstrap.sh
bootstrap: logged in as admin
bootstrap: repo rpm-rocky10-baseos created (rpm/remote -> https://dl.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/)
bootstrap: repo rpm-rocky10-appstream created (rpm/remote -> https://dl.rockylinux.org/pub/rocky/10/AppStream/x86_64/os/)
bootstrap: repo rpm-rocky10-extras created (rpm/remote -> https://dl.rockylinux.org/pub/rocky/10/extras/x86_64/os/)
bootstrap: repo rpm-epel10 created (rpm/remote -> https://dl.fedoraproject.org/pub/epel/10/Everything/x86_64/)
bootstrap: repo rpm-k3s created (rpm/remote -> https://rpm.rancher.io/k3s/stable/common/centos/9/noarch/)
bootstrap: repo rpm-edge-site created (rpm/local)
bootstrap: repo oci-bootc created (docker/local)
bootstrap: repo oci-quay-proxy created (docker/remote -> https://quay.io)
bootstrap: minted CI token -> .../registry/.ak-token (user admin, 30 days)
bootstrap: wrote .../registry/out/edge.repo (HOST=localhost) and .../registry/out/edge.repo.in
bootstrap: wrote .../registry/out/README-urls.md
bootstrap: done

$ ./bootstrap.sh      # second run: idempotent
bootstrap: logged in as admin
bootstrap: repo rpm-rocky10-baseos exists, skipping
... (all 8 repos) ...
bootstrap: existing .../registry/.ak-token still valid, reusing
bootstrap: done
```

Final repository list (anonymous `GET /api/v1/repositories?per_page=100`, after the tests below):

```console
$ curl -s 'http://localhost:30080/api/v1/repositories?per_page=100' \
    | jq -r '.items[] | "\(.key)\t\(.format)\t\(.repo_type)\tpublic=\(.is_public)\t\(.upstream_url // "-")\t\(.storage_used_bytes)"'
rpm-epel10	rpm	remote	public=true	https://dl.fedoraproject.org/pub/epel/10/Everything/x86_64/	7603730
rpm-edge-site	rpm	local	public=true	-	6731
rpm-k3s	rpm	remote	public=true	https://rpm.rancher.io/k3s/stable/common/centos/9/noarch/	4061
rpm-rocky10-appstream	rpm	remote	public=true	https://dl.rockylinux.org/pub/rocky/10/AppStream/x86_64/os/	8136661
rpm-rocky10-baseos	rpm	remote	public=true	https://dl.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/	40470057
rpm-rocky10-extras	rpm	remote	public=true	https://dl.rockylinux.org/pub/rocky/10/extras/x86_64/os/	9374
oci-bootc	docker	local	public=true	-	107142892
oci-quay-proxy	docker	remote	public=true	https://quay.io	282534638
```

## Container -> host addressing

Under rootless podman with pasta, `host.containers.internal` resolves inside a
container to pasta's mapped host address and reaches the host's published port:

```console
$ podman run --rm quay.io/rockylinux/rockylinux:10 sh -c \
    'getent hosts host.containers.internal; curl -s -o /dev/null -w "%{http_code}\n" http://host.containers.internal:30080/readyz'
169.254.1.2     host.containers.internal host.docker.internal
200
```

So no LAN IP is needed for container builds. The repo file for containers was
generated from the template: `sed '/^baseurl=/s/@HOST@/host.containers.internal/' out/edge.repo.in > edge-ctr.repo`.

## (a) dnf install through the RPM proxy (remote repos)

```console
$ podman run --rm -v ./edge-ctr.repo:/etc/yum.repos.d/edge.repo:Z quay.io/rockylinux/rockylinux:10 \
    dnf --disablerepo='*' --enablerepo='rpm-rocky10-*' install -y tmux
Rocky Linux 10 BaseOS (proxy)                    10 MB/s |  34 MB     00:03
Rocky Linux 10 AppStream (proxy)                3.0 MB/s | 2.7 MB     00:00
Rocky Linux 10 extras (proxy)                    18 kB/s | 6.1 kB     00:00
Dependencies resolved.
================================================================================
 Package
        Arch     Version                             Repository            Size
================================================================================
Installing:
 tmux   x86_64   3.3a-13.20250207gitb202a2f.el10     rpm-rocky10-baseos   517 k

Transaction Summary
================================================================================
Install  1 Package

Total download size: 517 k
Installed size: 1.2 M
Downloading Packages:
tmux-3.3a-13.20250207gitb202a2f.el10.x86_64.rpm 1.1 MB/s | 517 kB     00:00
--------------------------------------------------------------------------------
Total                                           1.1 MB/s | 517 kB     00:00
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                        1/1
  Installing       : tmux-3.3a-13.20250207gitb202a2f.el10.x86_64            1/1
  Running scriptlet: tmux-3.3a-13.20250207gitb202a2f.el10.x86_64            1/1

Installed:
  tmux-3.3a-13.20250207gitb202a2f.el10.x86_64

Complete!
```

(8 s wall-clock including the first-ever fetch of BaseOS metadata through the proxy.)

All six RPM repos load through Artifact Keeper (`repolist -v` excerpt), and the
EPEL / k3s proxies resolve packages:

```console
$ podman run --rm -v ./edge-ctr.repo:/etc/yum.repos.d/edge.repo:Z quay.io/rockylinux/rockylinux:10 sh -c "
    dnf --disablerepo='*' --enablerepo='rpm-*' repolist -v | grep -E '^Repo-(id|pkgs|baseurl)';
    dnf --disablerepo='*' --enablerepo=rpm-k3s repoquery --available;
    dnf --disablerepo='*' --enablerepo=rpm-epel10 repoquery --available htop"
Repo-id            : rpm-edge-site
Repo-pkgs          : 1
Repo-baseurl       : http://host.containers.internal:30080/rpm/rpm-edge-site
Repo-id            : rpm-epel10
Repo-pkgs          : 25970
Repo-baseurl       : http://host.containers.internal:30080/rpm/rpm-epel10
Repo-id            : rpm-k3s
Repo-pkgs          : 4
Repo-baseurl       : http://host.containers.internal:30080/rpm/rpm-k3s
Repo-id            : rpm-rocky10-appstream
Repo-pkgs          : 7000
Repo-baseurl       : http://host.containers.internal:30080/rpm/rpm-rocky10-appstream
Repo-id            : rpm-rocky10-baseos
Repo-pkgs          : 2415
Repo-baseurl       : http://host.containers.internal:30080/rpm/rpm-rocky10-baseos
Repo-id            : rpm-rocky10-extras
Repo-pkgs          : 25
Repo-baseurl       : http://host.containers.internal:30080/rpm/rpm-rocky10-extras
k3s-selinux-0:1.4-1.el9.noarch
k3s-selinux-0:1.5-1.el9.noarch
k3s-selinux-0:1.6-1.el9.noarch
htop-0:3.3.0-5.el10_0.x86_64
```

`rpm-k3s` only contains `k3s-selinux` el9 builds (Rancher publishes no el10 path; see README).

## (b) Upload a custom RPM to the hosted repo and consume it with dnf

Built a trivial noarch package (`edge-hello`, drops `/etc/edge-hello`) inside a
`rockylinux:10` container, installing `rpm-build` through the proxy repos. Then:

```console
$ # documented path from the site docs (system-packages.mdx) -- does NOT work:
$ curl -u "admin:$(cat .ak-token)" -F "file=@edge-hello-0.1.0-1.el10.noarch.rpm" \
    http://localhost:30080/api/artifacts/rpm/rpm-edge-site
Repository not found
HTTP 404

$ # native route -- works (API token as basic-auth password):
$ curl -u "admin:$(cat .ak-token)" -T edge-hello-0.1.0-1.el10.noarch.rpm \
    http://localhost:30080/rpm/rpm-edge-site/packages/edge-hello-0.1.0-1.el10.noarch.rpm
{"arch":"noarch","name":"edge-hello","release":"1.el10","sha256":"52cbf93684c2ee6a86ab9867916836b735ffa4c63d1d53d4057a5f25b7a2c742","size":6731,"version":"0.1.0"}
HTTP 201
```

Server-generated repodata (no createrepo step):

```console
$ curl -s http://localhost:30080/rpm/rpm-edge-site/repodata/repomd.xml | head -12
<?xml version="1.0" encoding="UTF-8"?>
<repomd xmlns="http://linux.duke.edu/metadata/repo" xmlns:rpm="http://linux.duke.edu/metadata/rpm">
  <revision>1791249376</revision>
  <data type="primary">
    <location href="repodata/primary.xml.gz"/>
    <checksum type="sha256">4948eccf98c128cd2b5a08b4175d61f0b36574f728f9844814937bc8045ad3f4</checksum>
    <open-checksum type="sha256">ac103bc406f9b4e8e111c757e4ab7018d447638541ce11f3b4f1d649afd71e53</open-checksum>
    <timestamp>1791249376</timestamp>
    <size>493</size>
    <open-size>857</open-size>
  </data>
  <data type="filelists">
...
$ curl -s http://localhost:30080/rpm/rpm-edge-site/repodata/primary.xml.gz | zcat | grep -o '<name>[^<]*'
<name>edge-hello
```

dnf sees and installs it:

```console
$ podman run --rm -v ./edge-ctr.repo:/etc/yum.repos.d/edge.repo:Z quay.io/rockylinux/rockylinux:10 sh -c "
    dnf --disablerepo='*' --enablerepo=rpm-edge-site repoquery --available;
    dnf --disablerepo='*' --enablerepo=rpm-edge-site install -y edge-hello | tail -4;
    cat /etc/edge-hello"
Edge site custom RPMs                            82 kB/s | 565  B     00:00    
edge-hello-0:0.1.0-1.el10.noarch
Installed:
  edge-hello-0.1.0-1.el10.noarch                                                

Complete!
hello from rpm-edge-site
```

## (c) Push a bootc-style image to the hosted OCI repo

```console
$ podman login --tls-verify=false -u admin --password-stdin localhost:30080 < .ak-token
Login Succeeded!
$ podman pull -q '--tls-verify=false' localhost:30080/oci-quay-proxy/rockylinux/rockylinux:10-minimal
1db47e4f611d81cf876c5a7c0e754d5071d1b36d8c0d763a275178b049cc0c21
$ podman tag localhost:30080/oci-quay-proxy/rockylinux/rockylinux:10-minimal localhost:30080/oci-bootc/hello:test
$ podman push '--tls-verify=false' localhost:30080/oci-bootc/hello:test
Getting image source signatures
Copying blob sha256:ee551c7c76d501fb21e7d19d56cb9bbfa8c2d418337be898312abad165654cbe
Copying config sha256:1db47e4f611d81cf876c5a7c0e754d5071d1b36d8c0d763a275178b049cc0c21
Writing manifest to image destination
$ skopeo inspect '--tls-verify=false' docker://localhost:30080/oci-bootc/hello:test
{
    "Name": "localhost:30080/oci-bootc/hello",
    "Digest": "sha256:86b31f19c0ce9c9153ad06e4f35c022901275b9c16683a1b27429f0178e494dc",
    "RepoTags": [
        "test"
    ],
    "Created": "2026-05-26T00:26:37.158176931Z",
    "DockerVersion": "",
    "Labels": {
        "io.buildah.version": "1.43.1",
        "license": "BSD-3-Clause",
        "name": "rockylinux",
        "org.opencontainers.image.authors": "Lukas Magauer, Neil Hanlon, Louis Abel",
        "org.opencontainers.image.licenses": "BSD-3-Clause",
        "org.opencontainers.image.source": "https://git.resf.org/sig_core/rocky-kiwi-descriptions/src/branch/r10",
        "org.opencontainers.image.title": "rockylinux",
        "org.opencontainers.image.vendor": "Rocky Enterprise Software Foundation",
        "org.opencontainers.image.version": "10-minimal",
        "summary": "Rocky Linux Minimal image",
        "vendor": "Rocky Enterprise Software Foundation",
        "version": "10-minimal"
    },
    "Architecture": "amd64",
    "Os": "linux",
    "Layers": [
        "sha256:639b8cac98934e934784f7e651c48670f84f7c1ac6b98c76f75fd923b59b24f2"
    ],
    "LayersData": [
        {
            "MIMEType": "application/vnd.oci.image.layer.v1.tar+gzip",
            "Digest": "sha256:639b8cac98934e934784f7e651c48670f84f7c1ac6b98c76f75fd923b59b24f2",
            "Size": 53570417,
            "Annotations": null
        }
    ],
    "Env": [
        "container=oci"
    ]
}
```

Anonymous read of the public hosted repo works too (needed for unauthenticated
`bootc switch`/install pulls):

```console
$ skopeo inspect --no-creds --tls-verify=false docker://localhost:30080/oci-bootc/hello:test | jq -r .Digest
sha256:86b31f19c0ce9c9153ad06e4f35c022901275b9c16683a1b27429f0178e494dc
```

Note the pushed blob digest (`ee551c7c...`, podman's local layer) differs from
the stored layer (`639b8cac...`): podman recompresses on push. Expected.

## (d) Pull through the quay.io proxy

```console
$ podman pull --tls-verify=false localhost:30080/oci-quay-proxy/rockylinux/rockylinux:10
Trying to pull localhost:30080/oci-quay-proxy/rockylinux/rockylinux:10...
Getting image source signatures
Copying blob sha256:530d6b37ba46a527ac6dfd8fa14e3b44a6abd963d7ba147d3751a1650febf4b6
Copying config sha256:0b5329d806d053ad65ab6b21fc3e49f1025e970cd826547a01a93b3ce9012796
Writing manifest to image destination
0b5329d806d053ad65ab6b21fc3e49f1025e970cd826547a01a93b3ce9012796

$ skopeo inspect --no-creds --tls-verify=false docker://localhost:30080/oci-quay-proxy/rockylinux/rockylinux:10 | jq -c '{Digest,Layers}'
{"Digest":"sha256:827d37bc128288ccf160ee318bb3cb92d591164cb217e92f8bc61e3982ae1834","Layers":["sha256:530d6b37ba46a527ac6dfd8fa14e3b44a6abd963d7ba147d3751a1650febf4b6"]}
$ skopeo inspect docker://quay.io/rockylinux/rockylinux:10 | jq -c '{Digest,Layers}'
{"Digest":"sha256:827d37bc128288ccf160ee318bb3cb92d591164cb217e92f8bc61e3982ae1834","Layers":["sha256:530d6b37ba46a527ac6dfd8fa14e3b44a6abd963d7ba147d3751a1650febf4b6"]}

$ # blob really streams through Artifact Keeper (87.7 MB):
$ curl -s -u "admin:$(cat .ak-token)" -o /dev/null -w '%{http_code} %{size_download} bytes\n' -L \
    http://localhost:30080/v2/oci-quay-proxy/rockylinux/rockylinux/blobs/sha256:530d6b37ba46a527ac6dfd8fa14e3b44a6abd963d7ba147d3751a1650febf4b6
200 87693174 bytes
```

Digest through the proxy is identical to quay.io. The podman pull itself took
<1 s because the layer already existed in local storage (podman skips blobs it
has); the blob fetch above proves the proxy path. `rockylinux:10-minimal` was
also pulled through the proxy (used as the source for test (c)).
Note: a raw anonymous `curl` of a blob returns `401` with
`Www-Authenticate: Bearer realm="http://localhost:30080/v2/token",...`; OCI
clients do the anonymous token dance automatically (skopeo `--no-creds` works).
