{ nixpkgs
, mmdoc
, system
, self
, ...
}:

let

  pkgs = import nixpkgs { inherit system; config = { allowBroken = true; }; };

  developPackageAttrs = {
    name = "nixpkgs-update";
    root = self;
    returnShellEnv = false;
  };

  drvAttrs = attrs: with pkgs; {
    NIX = nix;
    GIT = git;
    HUB = gitAndTools.hub;
    JQ = jq;
    TREE = tree;
    GIST = gist;
    # TODO: are there more coreutils paths that need locking down?
    TIMEOUT = coreutils;
    NIXPKGSREVIEW = nixpkgs-review;
  };

  haskellPackages = pkgs.haskellPackages.override {
    overrides = _: haskellPackages: {
      polysemy-plugin = pkgs.haskell.lib.dontCheck haskellPackages.polysemy-plugin;
      polysemy = pkgs.haskell.lib.dontCheck haskellPackages.polysemy;
      nixpkgs-update =
        pkgs.haskell.lib.justStaticExecutables (
          pkgs.haskell.lib.failOnAllWarnings (
            pkgs.haskell.lib.disableExecutableProfiling (
              pkgs.haskell.lib.disableLibraryProfiling (
                pkgs.haskell.lib.generateOptparseApplicativeCompletion "nixpkgs-update" (
                  (haskellPackages.developPackage developPackageAttrs).overrideAttrs drvAttrs
                )
              )
            )
          )
        );
    };
  };

  shell = haskellPackages.shellFor {
    nativeBuildInputs = with pkgs; [
      cabal-install
      ghcid
    ];
    packages = ps: [ ps.nixpkgs-update ];
    shellHook = ''
    '';
  };

  doc = pkgs.stdenvNoCC.mkDerivation rec {
    name = "nixpkgs-update-doc";
    src = self;
    phases = [ "mmdocPhase" ];
    mmdocPhase = "${mmdoc.packages.${system}.mmdoc}/bin/mmdoc nixpkgs-update $src/doc $out";
  };

in
{
  nixpkgs-update = haskellPackages.nixpkgs-update;
  nixpkgs-update-doc = doc;
  devShell = shell;
}
