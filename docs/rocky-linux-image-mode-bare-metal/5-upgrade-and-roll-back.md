# Step 5: Upgrade and roll back by moving a tag

This page ships a configuration change to a running node without touching the node: you
promote a new release in the registry, the node upgrades to it, and then you roll it back.

**Make targets:** `make vm-upgrade` and `make vm-rollback`, which run
[`deploy/vm-upgrade.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/rocky-linux-image-mode-bare-metal/deploy/vm-upgrade.sh) and
[`deploy/vm-rollback.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/rocky-linux-image-mode-bare-metal/deploy/vm-rollback.sh). `make promote REL=4` moves the tag
on its own.

## Promote and upgrade

Upgrading the fleet does not touch the nodes. The second site configuration release from
[Step 3](3-add-kubernetes-and-site-config.md), `edge-site-config` release 4, has a new MOTD
and a new label on the demo Deployment, and it is already built and pushed as
`rocky-edge:10.2-4`. You **promote** it by copying that tag onto the floating
`rocky-edge:10` inside the registry. The copy only touches the manifest and takes about a
second, because every blob is already in `oci-bootc`. Then the node runs `bootc upgrade`:

```console
$ skopeo copy --src-tls-verify=false --dest-tls-verify=false \
    docker://localhost:30080/oci-bootc/rocky-edge:10.2-4 \
    docker://localhost:30080/oci-bootc/rocky-edge:10
[root@edge-node-01 ~]# bootc upgrade
layers already present: 73; layers needed: 3 (7.8 MB)
Deploying...done (2 seconds)
Queued for next boot: 10.0.2.2:30080/oci-bootc/rocky-edge:10
  Version: 10.2-4
  Digest: sha256:c98876108f864a75e7a7f958fda049d72673652e8eae5849c63dac893bb38f16
[root@edge-node-01 ~]# reboot
```

The node downloads 7.8 MB, stages the new deployment, and reboots into it. After the reboot,
`bootc status` shows 10.2-4 booted with 10.2-3 as the rollback, the MOTD reads
`edge-site-config 1.0-4.el10: day-2 update via bootc upgrade (release 4)`, and RKE2 has
re-applied the re-seeded manifests, so the Deployment rolled to the release-4 label.

## Roll back

```console
[root@edge-node-01 ~]# bootc rollback
[root@edge-node-01 ~]# reboot
```

`bootc rollback` and a reboot put everything back, manifests included, because the seeding
service runs from whichever image is booted. The proof of concept runs it in both directions
to be sure. The [day-2 flow](architecture.md#day-2-flow) is diagrammed on the Architecture page.

## Image-mode lesson: the missing bubblewrap

This step produced the failure we learned the most from. On an earlier build, the upgrade
staged cleanly, the node rebooted, and it came back on the **old** image. The staged deployment
was gone, and there was no error in the current journal. The clue was in the next boot's
`ostree-boot-complete` output:

```text
ostree-finalize-staged.service failed on previous boot: Finalizing deployment:
Finalizing SELinux policy: Failed to execute child process "/usr/bin/bwrap"
(No such file or directory)
```

Here is what is going on. At shutdown, ostree finalizes the staged deployment. Because
`rke2-selinux` adds policy modules, `/etc/selinux` differs from the image's copy, so ostree
rebuilds the SELinux policy by running `semodule` inside bubblewrap (a small sandboxing tool).
The RESF minimal base does not include the `bubblewrap` package, and no package declares a
dependency on it, because libostree calls `/usr/bin/bwrap` by its hard-coded path.

**Why nothing caught it:** the base build never noticed, because the builder container had
bubblewrap as a dependency of rpm-ostree, and the community image happens to ship it. We proved
the diagnosis on the live node by temporarily overlaying `/usr` with `bootc usr-overlay` and
installing the package; the next upgrade went through. The fix is the `bubblewrap` package in
the first `RUN` of the [edge Containerfile](3-add-kubernetes-and-site-config.md#the-edge-containerfile),
plus a tmpfiles.d entry for `/var/log/journal` so that the journal survives reboots and the next
person does not have to find this in a serial log. `vm-upgrade.sh` now prints the
`ostree-boot-complete` journal itself whenever the booted digest is not the staged one.

The lesson generalizes: neither this bug nor the read-only `/opt` in Step 3 showed up in
`podman build`, `podman run` or `bootc container lint`. If you adopt image mode, your CI
needs a stage that boots the image and upgrades it, not just builds it. The VM harness in this
walkthrough's code is that stage. See
[Troubleshooting](troubleshooting.md#upgrade-succeeds-but-the-node-boots-the-old-image).

**Next:** [Step 6: Sign everything and verify everywhere](6-sign-and-verify.md).
