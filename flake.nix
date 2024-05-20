{
  inputs = {
    nixpkgs.url =
      "github:nixos/nixpkgs?ref=a22a985f13d58b2bafb4964dd2bdf6376106a2d2";
    # https://github.com/NixOS/nixpkgs/pull/311815
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        flutter = pkgs.flutterPackages.v3_22;
      in {
        devShell = with pkgs;
          mkShell {
            FLUTTER_ROOT = flutter;
            buildInputs = [ fasm flutter gnumake ];
          };
      });
}
