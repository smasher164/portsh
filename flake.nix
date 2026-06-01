{
  description = "portsh — one file that is a valid POSIX sh script AND a Windows batch/JScript program: a truly portable shell.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) lib stdenv;

        # Portability bugs only surface when you run the SAME script under
        # several shells. dash = strict POSIX reference, mksh = another
        # lineage, bash = ubiquitous, busybox(ash) = embedded/Alpine.
        shells = [ pkgs.dash pkgs.bash pkgs.mksh ]
          ++ lib.optionals stdenv.isLinux [ pkgs.busybox ];

        # The Windows-side engine pairs awk (Unix) with JScript, so the
        # interpreter must run under ANY POSIX awk, not just gawk.
        awks = [ pkgs.gawk pkgs.mawk ];

        # cmd.exe + cscript only live in Wine, which only really works on Linux.
        # On darwin/arm there is no local Windows env — use CI (windows-latest).
        winePkgs = lib.optionals stdenv.isLinux [ pkgs.wine64 ];
      in {
        devShells.default = pkgs.mkShell {
          packages = shells ++ awks ++ winePkgs ++ [
            pkgs.shellcheck   # lint the sh half / catch bashisms
            pkgs.bats         # test harness option
            pkgs.qemu         # nix-native Windows VM (UTM is just a GUI over this)
            pkgs.coreutils
            pkgs.openssh      # harness drives the cmd leg over ssh into the VM
            pkgs.gnumake
            pkgs.git
          ];
          shellHook = ''
            echo "portsh dev shell"
            echo "  shells : dash bash mksh${lib.optionalString stdenv.isLinux " busybox(ash)"}"
            echo "  awks   : gawk mawk"
            ${lib.optionalString stdenv.isLinux  ''echo "  windows: wine64 ($(command -v wine64 >/dev/null && echo present || echo missing))"''}
            ${lib.optionalString stdenv.isDarwin ''echo "  windows: none locally (arm/darwin) -> use CI windows-latest for cmd/cscript"''}
          '';
        };
      });
}
