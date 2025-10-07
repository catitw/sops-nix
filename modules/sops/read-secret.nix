{ lib, pkgs, cfg }:

let
  sops-read-secret = pkgs.callPackage ../../pkgs/sops-read-secret {
    inherit (cfg) gnupgHome ageKeyFile;
    # Add age to build inputs if SSH keys are used
    age = lib.mkIf (cfg.ageSSHKeyPaths != []) pkgs.age;
    gnupg = lib.mkIf (cfg.gnupgHome != null) pkgs.gnupg;
    vendorHash = "sha256-b+yUkMeIKiozlrANOwaMY2QDWo0cZYpD9SXZuSgYUQs=";
  };

  # Helper function to read a secret at build time
  readSecret = secretName: {
    sopsFile,
    key ? "",
    format ? "yaml",
  }:
    let
      secretConfig = cfg.secrets.${secretName} or (throw "Secret ${secretName} not found in sops.secrets");

      # Prepare sops environment
      sopsEnv = {
        SOPS_FILE = toString sopsFile;
        SOPS_KEY = if key == "" then
          (if secretConfig.key or "" != "" then secretConfig.key else secretName)
          else key;
        SOPS_FORMAT = format;
      } // lib.optionalAttrs (cfg.gnupg.home != null) {
        GNUPGHOME = cfg.gnupg.home;
      } // lib.optionalAttrs (cfg.age.ageKeyFile != null) {
        SOPS_AGE_KEY_FILE = cfg.age.ageKeyFile;
      };

      # Build the command to read the secret
      readSecretCmd = pkgs.writeShellScript "read-secret-${secretName}" ''
        set -euo pipefail

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "export ${n}='${v}'") sopsEnv)}

        # Use sops-read-secret to decrypt and extract the content
        ${sops-read-secret}/bin/sops-read-secret \
          --file "$SOPS_FILE" \
          ${lib.optionalString (sopsEnv.SOPS_KEY != "") "--key \"$SOPS_KEY\""} \
          --format "$SOPS_FORMAT" \
          ${lib.concatStringsSep " " (map (path: "--ssh-key-path \"${path}\"") (cfg.age.sshKeyPaths or []))} \
          ${lib.concatStringsSep " " (map (path: "--ssh-key-path \"${path}\"") (cfg.gnupg.sshKeyPaths or []))} \
          ${lib.optionalString (cfg.gnupg.home != null) "--gnupg-home \"${cfg.gnupg.home}\""} \
          ${lib.optionalString (cfg.age.keyFile != null) "--age-key-file \"${cfg.age.keyFile}\""}
      '';
    in
    pkgs.runCommand "secret-${secretName}-content" {
      buildInputs = [ sops-read-secret ];
      passthru.env = sopsEnv;
    } ''
      ${readSecretCmd} > $out
    '';

  # Function to get secret content as a string
  getSecretContent = secretName: args:
    let
      result = readSecret secretName args;
    in
    lib.strings.fileContents result;

in {
  inherit readSecret getSecretContent;
}