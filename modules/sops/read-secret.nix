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
      } // lib.optionalAttrs (cfg.gnupgHome != null) {
        GNUPGHOME = cfg.gnupgHome;
      } // lib.optionalAttrs (cfg.ageKeyFile != null) {
        SOPS_AGE_KEY_FILE = cfg.ageKeyFile;
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
          ${lib.concatStringsSep " " (map (path: "--ssh-key-path \"${path}\"") (cfg.ageSSHKeyPaths or []))} \
          ${lib.concatStringsSep " " (map (path: "--ssh-key-path \"${path}\"") (cfg.sshKeyPaths or []))} \
          ${lib.optionalString (cfg.gnupgHome != null) "--gnupg-home \"${cfg.gnupgHome}\""} \
          ${lib.optionalString (cfg.ageKeyFile != null) "--age-key-file \"${cfg.ageKeyFile}\""}
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