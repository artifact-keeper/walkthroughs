Name:           edge-hello
Version:        0.1.0
Release:        1%{?dist}
Summary:        Trivial marker package for the edge-site repo (PoC)
License:        MIT
BuildArch:      noarch

%description
Drops /etc/edge-hello so we can prove rpm-edge-site serves custom RPMs.

%install
mkdir -p %{buildroot}%{_sysconfdir}
echo "hello from rpm-edge-site" > %{buildroot}%{_sysconfdir}/edge-hello

%files
%{_sysconfdir}/edge-hello
