let
  sources = import ./npins;
in
{
  system ? builtins.currentSystem,
  nixpkgs ? sources.nixpkgs,
  serokell-nix ? sources.serokell-nix,
}:
let
  overlay = self: super: {
    haskell = super.haskell // {
      packageOverrides = self: super: { nixfmt = self.callCabal2nix "nixfmt" src { }; };
    };
  };

  pkgs = import nixpkgs {
    inherit system;
    overlays = [
      overlay
      (import (serokell-nix + "/overlay"))
    ];
    config = { };
  };

  inherit (pkgs) haskell lib;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./nixfmt.cabal
      ./src
      ./main
      ./LICENSE
    ];
  };

  build = lib.pipe pkgs.haskellPackages.nixfmt [
    haskell.lib.justStaticExecutables
    haskell.lib.dontHaddock
    (drv: lib.lazyDerivation { derivation = drv; })
  ];

  treefmtEval = (import sources.treefmt-nix).evalModule pkgs {
    # Used to find the project root
    projectRootFile = ".git/config";
  };
in
build
// {
  packages = {
    nixfmt = build;
    inherit (pkgs) reuse;
  };

  shell = pkgs.haskellPackages.shellFor {
    packages = p: [ p.nixfmt ];
    nativeBuildInputs = with pkgs; [
      cabal-install
      stylish-haskell
      haskellPackages.haskell-language-server
      shellcheck
      npins
      hlint
      treefmtEval.config.build.wrapper
    ];
  };

  checks = {
    hlint = pkgs.build.haskell.hlint src;
    treefmt = treefmtEval.config.build.check src;
  };
}
