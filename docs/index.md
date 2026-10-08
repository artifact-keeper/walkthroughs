# Artifact Keeper Walkthroughs

Walkthroughs are step-by-step guides for real deployments built on
[Artifact Keeper](https://github.com/artifact-keeper/artifact-keeper), the open-source
universal artifact registry. Each one starts from an empty host, explains every decision as it
is made, and ends with something running that you can verify. Every walkthrough is backed by a
public repository you can clone and run with the same commands, so nothing here is a sketch.

<div class="grid cards" markdown>

-   :material-server-network:{ .lg .middle } __Rocky Linux image mode on bare metal__

    ---

    Build a Rocky Linux 10 bootc image with RKE2, install it on bare metal with a kickstart,
    upgrade and roll back by moving a tag, and sign and verify every RPM and image, with
    Artifact Keeper as the single source of truth.

    [:octicons-arrow-right-24: Start the walkthrough](rocky-linux-image-mode-bare-metal/index.md)

-   :material-package-variant-closed:{ .lg .middle } __A private conda channel for pixi__

    ---

    Proxy conda-forge, host your own packages, and present one virtual channel that cannot be
    shadowed. Sign every package with your own key, verify before linking, build containers on
    a network with no internet, and answer "which environments contain this?" from the registry.

    [:octicons-arrow-right-24: Start the walkthrough](private-conda-channel-pixi/index.md)

</div>

Looking for a specific format, tool or control? [Browse by tag](tags.md).

Want a walkthrough for a deployment that is not here yet?
[Open an issue](https://github.com/artifact-keeper/walkthroughs/issues/new) and describe it.
