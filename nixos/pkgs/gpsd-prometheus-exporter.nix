# Prometheus exporter for gpsd (https://github.com/brendanbank/gpsd-prometheus-exporter).
#
# Single-file Python exporter; packaged here because it is not in nixpkgs.
# It needs the `gps` Python module, which nixpkgs ships inside the gpsd
# package's site-packages (python_libdir), so that path is added to
# PYTHONPATH in the wrapper.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  makeWrapper,
  python3,
  gpsd,
}:

let
  pythonEnv = python3.withPackages (ps: [
    ps.prometheus-client
    ps.packaging # optional version check in gpsd_exporter.py
  ]);
in
stdenvNoCC.mkDerivation {
  pname = "gpsd-prometheus-exporter";
  # Upstream has no releases; __version__ in gpsd_exporter.py at this commit.
  version = "1.1.19-unstable-2026-03-23";

  src = fetchFromGitHub {
    owner = "brendanbank";
    repo = "gpsd-prometheus-exporter";
    rev = "b11dd24a03e8abdf4000860c48c22c0e4236e3a6";
    hash = "sha256-YY4tgXhxGQbodHdZ9RqSV+LTVEnH//aQZZ/IN/td8uU=";
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm755 gpsd_exporter.py $out/libexec/gpsd_exporter.py
    makeWrapper ${pythonEnv}/bin/python $out/bin/gpsd-exporter \
      --add-flags "$out/libexec/gpsd_exporter.py" \
      --prefix PYTHONPATH : "${gpsd}/${python3.sitePackages}"
    runHook postInstall
  '';

  meta = {
    description = "Prometheus exporter for the gpsd GPS daemon";
    homepage = "https://github.com/brendanbank/gpsd-prometheus-exporter";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
    mainProgram = "gpsd-exporter";
  };
}
