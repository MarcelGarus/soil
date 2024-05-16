{
  inputs = {
    nixpkgs.url =
      "github:nixos/nixpkgs?ref=8eb7faf85cc3d45fdca33b54bb10a2728eda899b";
    # https://github.com/NixOS/nixpkgs/pull/311568
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        devShell = with pkgs; mkShell { buildInputs = [ dart fasm gnumake ]; };
      });
}
