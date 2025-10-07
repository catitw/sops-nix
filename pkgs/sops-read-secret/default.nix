{
  lib,
  buildGo124Module,
  sops,
  gnupg ? null,
  age ? null,
  vendorHash,
}:

buildGo124Module {
  pname = "sops-read-secret";
  version = "0.0.1";

  src = lib.sourceByRegex ../.. [
    "go\.(mod|sum)"
    "pkgs"
    "pkgs/sops-read-secret.*"
  ];

  subPackages = [ "pkgs/sops-read-secret" ];

  # We need sops and potentially gnupg/age in the final binary
  propagatedBuildInputs = [ sops ] ++ lib.optionals (gnupg != null) [ gnupg ]
    ++ lib.optionals (age != null) [ age ];

  # Make sure the binary can find sops
  postInstall = ''
    wrapProgram $out/bin/sops-read-secret \
      --prefix PATH : ${lib.makeBinPath ([ sops ] ++ lib.optionals (gnupg != null) [ gnupg ] ++ lib.optionals (age != null) [ age ])}
  '';

  meta = with lib; {
    description = "Utility to read sops secrets at build time";
    homepage = "https://github.com/Mic92/sops-nix";
    license = licenses.mit;
    maintainers = with maintainers; [ mic92 ];
    platforms = platforms.unix;
  };
}