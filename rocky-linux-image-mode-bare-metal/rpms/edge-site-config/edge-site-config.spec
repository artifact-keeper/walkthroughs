# Site configuration for the Rocky Linux image-mode edge PoC.
# Build: rpmbuild -bb --define "rel 4" edge-site-config.spec   (rpms/build.sh does this)
# Releases 1/2: unsigned baseline/day-2 (iteration 1). Releases 3/4: the same content,
# signed with the edge RPM key (rpmsign in rpms/build.sh); 3 = baseline, 4 = day-2.
%{!?rel: %global rel 1}

Name:           edge-site-config
Version:        1.0
Release:        %{rel}%{?dist}
Summary:        RKE2, registry and workload configuration for edge nodes
License:        MIT
BuildArch:      noarch

Source0:        config.yaml
Source1:        registries.yaml
Source2:        motd.in
Source3:        nginx-demo.yaml.in
Source4:        edge-site-manifests.service
Source5:        50-artifact-keeper.conf
Source6:        rke2-canal.conf
Source7:        80-edge-site.preset

BuildRequires:  systemd-rpm-macros
Requires:       rke2-server
%{?systemd_requires}

%description
Configuration for single-node RKE2 edge servers whose OS image, RPMs and
container images all come from one Artifact Keeper instance:
RKE2 config.yaml and registries.yaml (docker.io mirrored through the Artifact
Keeper Docker Hub proxy), an insecure-registry drop-in so `bootc upgrade` can
reach the plain-HTTP registry, a MOTD carrying this package's version, and a
sample nginx workload seeded into RKE2's auto-deploy manifests directory.

%prep
# nothing to unpack

%build
%if %{rel} == 1 || %{rel} == 3
%global motd_note initial site configuration
%else
%global motd_note day-2 update via bootc upgrade (release %{rel})
%endif
sed -e 's/@VERSION@/%{version}/' -e 's/@RELEASE@/%{release}/' -e 's/@NOTE@/%{motd_note}/' \
    %{SOURCE2} > motd
sed -e 's/@RELEASE@/%{rel}/g' %{SOURCE3} > nginx-demo.yaml

%install
install -D -m 0644 %{SOURCE0} %{buildroot}%{_sysconfdir}/rancher/rke2/config.yaml
install -D -m 0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/rancher/rke2/registries.yaml
install -D -m 0644 motd %{buildroot}%{_sysconfdir}/motd.d/edge
install -D -m 0644 nginx-demo.yaml %{buildroot}%{_datadir}/edge-site/manifests/nginx-demo.yaml
install -D -m 0644 %{SOURCE4} %{buildroot}%{_unitdir}/edge-site-manifests.service
install -D -m 0644 %{SOURCE5} %{buildroot}%{_sysconfdir}/containers/registries.conf.d/50-artifact-keeper.conf
install -D -m 0644 %{SOURCE6} %{buildroot}%{_sysconfdir}/NetworkManager/conf.d/rke2-canal.conf
install -D -m 0644 %{SOURCE7} %{buildroot}%{_presetdir}/80-edge-site.preset

%post
%systemd_post edge-site-manifests.service

%preun
%systemd_preun edge-site-manifests.service

%postun
%systemd_postun edge-site-manifests.service

%files
%config(noreplace) %{_sysconfdir}/rancher/rke2/config.yaml
%config(noreplace) %{_sysconfdir}/rancher/rke2/registries.yaml
%config(noreplace) %{_sysconfdir}/containers/registries.conf.d/50-artifact-keeper.conf
%config(noreplace) %{_sysconfdir}/NetworkManager/conf.d/rke2-canal.conf
%{_sysconfdir}/motd.d/edge
%dir %{_datadir}/edge-site
%dir %{_datadir}/edge-site/manifests
%{_datadir}/edge-site/manifests/nginx-demo.yaml
%{_unitdir}/edge-site-manifests.service
%{_presetdir}/80-edge-site.preset

%changelog
* Tue Oct 06 2026 Brandon Geraci <bgeraci@openteams.com> - 1.0-4
- Signed day-2 demo (same content as 1.0-2, signed with the edge RPM key)

* Tue Oct 06 2026 Brandon Geraci <bgeraci@openteams.com> - 1.0-3
- Signed baseline (same content as 1.0-1, signed with the edge RPM key)

* Mon Oct 05 2026 Brandon Geraci <bgeraci@openteams.com> - 1.0-2
- Day-2 demo: new MOTD text and edge-site/config-release label on nginx-demo

* Mon Oct 05 2026 Brandon Geraci <bgeraci@openteams.com> - 1.0-1
- Initial site configuration: RKE2 config/registries, MOTD, nginx demo manifest
