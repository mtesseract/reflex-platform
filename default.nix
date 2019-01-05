{ nixpkgsFunc ? import ./nixpkgs
, system ? builtins.currentSystem
, config ? {}
, enableLibraryProfiling ? false
, enableExposeAllUnfoldings ? true
, enableTraceReflexEvents ? false
, useFastWeak ? true
, useReflexOptimizer ? false
, useTextJSString ? true
, __useLegacyCompilers ? false # Interface unstable
, iosSdkVersion ? "10.2"
, nixpkgsOverlays ? []
, haskellOverlays ? []
}:
let iosSupport = system == "x86_64-darwin";
    androidSupport = lib.elem system [ "x86_64-linux" ];

    # Overlay for GHC with -load-splices & -save-splices option
    splicesEval = self: super: {
      haskell = super.haskell // {
        compiler = super.haskell.compiler // {
          ghcSplices-8_4 = super.haskell.compiler.ghc843.overrideAttrs (drv: {
            enableParallelBuilding = false;
            patches = (drv.patches or [])
              ++ [ ./splices-load-save.patch ./haddock.patch ];
          });
        };
        packages = super.haskell.packages // {
          ghcSplices-8_4 = super.haskell.packages.ghc843.override {
            buildHaskellPackages = self.buildPackages.haskell.packages.ghcSplices-8_4;
            ghc = self.buildPackages.haskell.compiler.ghcSplices-8_4;
          };
        };
      };
    };

    hackGetOverlay = self: super:
      import ./nixpkgs-overlays/hack-get { inherit lib; } self;

    bindHaskellOverlays = self: super: {
      haskell = super.haskell // {
        overlays = super.overlays or {} // import ./haskell-overlays {
          nixpkgs = self;
          inherit (self) lib;
          haskellLib = self.haskell.lib;
          inherit
            useFastWeak useReflexOptimizer enableLibraryProfiling enableTraceReflexEvents
            useTextJSString enableExposeAllUnfoldings
            haskellOverlays;
          inherit ghcSavedSplices;
        };
      };
    };

    forceStaticLibs = self: super: {
      darwin = super.darwin // {
        libiconv = super.darwin.libiconv.overrideAttrs (_:
          lib.optionalAttrs (self.stdenv.hostPlatform != self.stdenv.buildPlatform) {
            postInstall = "rm $out/include/libcharset.h $out/include/localcharset.h";
            configureFlags = ["--disable-shared" "--enable-static"];
          });
      };
      zlib = super.zlib.override (lib.optionalAttrs
        (self.stdenv.hostPlatform != self.stdenv.buildPlatform)
        { static = true; });
    };

    mobileGhcOverlay = import ./nixpkgs-overlays/mobile-ghc { inherit lib; };

    nixpkgsArgs = {
      inherit system;
      overlays = [
        hackGetOverlay
        bindHaskellOverlays
        forceStaticLibs
        mobileGhcOverlay
        splicesEval
      ] ++ nixpkgsOverlays;
      config = {
        permittedInsecurePackages = [
          "webkitgtk-2.4.11"
        ];
        packageOverrides = pkgs: {
          webkitgtk = pkgs.webkitgtk220x;
        };

        # XCode needed for native macOS app
        # Obelisk needs it to for some reason
        allowUnfree = true;
      } // config;
    };

    nixpkgs = nixpkgsFunc nixpkgsArgs;

    inherit (nixpkgs) lib fetchurl fetchgit fetchgitPrivate fetchFromGitHub;

    nixpkgsCross = {
      android = lib.mapAttrs (_: args: nixpkgsFunc (nixpkgsArgs // args)) rec {
        aarch64 = {
          crossSystem = lib.systems.examples.aarch64-android-prebuilt;
        };
        aarch32 = {
          crossSystem = lib.systems.examples.armv7a-android-prebuilt // {
            # Hard to find newer 32-bit phone to test with that's newer than
            # this. Concretely, doing so resulted in:
            # https://android.googlesource.com/platform/bionic/+/master/libc/arch-common/bionic/pthread_atfork.h#19
            sdkVer = "22";
          };
        };
        # Back compat
        arm64 = lib.warn "nixpkgsCross.android.arm64 has been deprecated, using nixpkgsCross.android.aarch64 instead." aarch64;
        armv7a = lib.warn "nixpkgsCross.android.armv7a has been deprecated, using nixpkgsCross.android.aarch32 instead." aarch32;
        arm64Impure = lib.warn "nixpkgsCross.android.arm64Impure has been deprecated, using nixpkgsCross.android.aarch64 instead." aarch64;
        armv7aImpure = lib.warn "nixpkgsCross.android.armv7aImpure has been deprecated, using nixpkgsCross.android.aarch32 instead." aarch32;
      };
      ios = lib.mapAttrs (_: args: nixpkgsFunc (nixpkgsArgs // args)) rec {
        simulator64 = {
          crossSystem = lib.systems.examples.iphone64-simulator // {
            sdkVer = iosSdkVersion;
          };
        };
        aarch64 = {
          crossSystem = lib.systems.examples.iphone64 // {
            sdkVer = iosSdkVersion;
          };
        };
        aarch32 = {
          crossSystem = lib.systems.examples.iphone32 // {
            sdkVer = iosSdkVersion;
          };
        };
        # Back compat
        arm64 = lib.warn "nixpkgsCross.ios.arm64 has been deprecated, using nixpkgsCross.ios.aarch64 instead." aarch64;
      };
    };

    haskellLib = nixpkgs.haskell.lib;

    overrideCabal = pkg: f: if pkg == null then null else haskellLib.overrideCabal pkg f;

    combineOverrides = old: new: old // new // lib.optionalAttrs (old ? overrides && new ? overrides) {
      overrides = lib.composeExtensions old.overrides new.overrides;
    };

    # Makes sure that old `overrides` from a previous call to `override` are not
    # forgotten, but composed. Do this by overriding `override` and passing a
    # function which takes the old argument set and combining it. What a tongue
    # twister!
    makeRecursivelyOverridable = x: x // {
      override = new: makeRecursivelyOverridable (x.override (old: (combineOverrides old new)));
    };

    cabal2nixResult = src: builtins.trace "cabal2nixResult is deprecated; use ghc.haskellSrc2nix or ghc.callCabal2nix instead" (ghc.haskellSrc2nix {
      name = "for-unknown-package";
      src = "file://${src}";
      sha256 = null;
    });

  ghcSavedSplices = ghcSavedSplices-8_4;
  ghcSavedSplices-8_4 = (makeRecursivelyOverridable nixpkgs.haskell.packages.integer-simple.ghcSplices-8_4).override {
    overrides = lib.foldr lib.composeExtensions (_: _: {}) (let
      haskellOverlays = nixpkgs.haskell.overlays;
    in [
      haskellOverlays.combined
      haskellOverlays.saveSplices
      (self: super: with haskellLib; {
        cryptonite = disableCabalFlag super.cryptonite "integer-gmp";
        integer-logarithms = disableCabalFlag super.integer-logarithms "integer-gmp";
        scientific = enableCabalFlag super.scientific "integer-simple";
        dependent-sum-template = dontCheck super.dependent-sum-template;
        generic-deriving = dontCheck super.generic-deriving;
      })
    ]);
  };
  ghcjs = if __useLegacyCompilers then ghcjs8_0 else ghcjs8_4;
  ghcjs8_4 = (makeRecursivelyOverridable (nixpkgs.haskell.packages.ghcjs84.override (old: {
    ghc = old.ghc.override {
      ghcjsSrc = fetchgit {
        url = "https://github.com/obsidiansystems/ghcjs.git";
        rev = "584eaa138c32c5debb3aae571c4153d537ff58f1";
        sha256 = "1ib0vsv2wrwf5iivnq6jw2l9g5izs0fjpp80jrd71qyywx4xcm66";
        fetchSubmodules = true;
      };
    };
  }))).override {
    overrides = nixpkgs.haskell.overlays.combined;
  };
  ghcjs8_2 = (makeRecursivelyOverridable (nixpkgs.haskell.packages.ghcjs82.override (old: {
    ghc = old.ghc.override {
      ghcjsDepOverrides = self: super: {
        haddock-library-ghcjs = haskellLib.doJailbreak super.haddock-library-ghcjs;
      };
    };
  }))).override {
    overrides = nixpkgs.haskell.overlays.combined;
  };
  ghcjs8_0 = (makeRecursivelyOverridable (nixpkgs.haskell.packages.ghcjs80.override (old: {
  }))).override {
    overrides = nixpkgs.haskell.overlays.combined;
  };

  ghc = if __useLegacyCompilers then ghc8_0 else ghc8_4;
  ghcHEAD = (makeRecursivelyOverridable nixpkgs.haskell.packages.ghcHEAD).override {
    overrides = nixpkgs.haskell.overlays.combined;
  };
  ghc8_4 = (makeRecursivelyOverridable nixpkgs.haskell.packages.ghc843).override {
    overrides = nixpkgs.haskell.overlays.combined;
  };
  ghc8_2 = (makeRecursivelyOverridable nixpkgs.haskell.packages.ghc822).override {
    overrides = nixpkgs.haskell.overlays.combined;
  };
  ghc8_0 = (makeRecursivelyOverridable nixpkgs.haskell.packages.ghc802).override {
    overrides = nixpkgs.haskell.overlays.combined;
  };
  ghc7 = (makeRecursivelyOverridable nixpkgs.haskell.packages.ghc7103).override {
    overrides = nixpkgs.haskell.overlays.combined;
  };

  # Takes a package set with `makeRecursivelyOverridable` and ensures that any
  # future overrides will be applied to both the package set itself and it's
  # build-time package set (`buildHaskellPackages`).
  makeRecursivelyOverridableBHPToo = x: x // {
    override = new: makeRecursivelyOverridableBHPToo (x.override
      (combineOverrides
        {
          overrides = self: super: {
            buildHaskellPackages = super.buildHaskellPackages.override new;
          };
        }
        new));
  };

  ghcAndroidAarch64 = if __useLegacyCompilers then ghcAndroidAarch64-8_2 else ghcAndroidAarch64-8_4;
  ghcAndroidAarch64-8_4 = makeRecursivelyOverridableBHPToo ((makeRecursivelyOverridable nixpkgsCross.android.aarch64.haskell.packages.integer-simple.ghcSplices-8_4).override {
    overrides = nixpkgsCross.android.aarch64.haskell.overlays.combined;
  });
  ghcAndroidAarch64-8_2 = (makeRecursivelyOverridable nixpkgsCross.android.aarch64.haskell.packages.integer-simple.ghc822).override {
    overrides = nixpkgsCross.android.aarch64.haskell.overlays.combined;
  };
  ghcAndroidAarch32 = if __useLegacyCompilers then ghcAndroidAarch32-8_2 else ghcAndroidAarch32-8_4;
  ghcAndroidAarch32-8_4 = makeRecursivelyOverridableBHPToo ((makeRecursivelyOverridable nixpkgsCross.android.aarch32.haskell.packages.integer-simple.ghcSplices-8_4).override {
    overrides = nixpkgsCross.android.aarch32.haskell.overlays.combined;
  });
  ghcAndroidAarch32-8_2 = (makeRecursivelyOverridable nixpkgsCross.android.aarch32.haskell.packages.integer-simple.ghc822).override {
    overrides = nixpkgsCross.android.aarch32.haskell.overlays.combined;
  };

  ghcIosSimulator64 = if __useLegacyCompilers then ghcIosSimulator64-8_2 else ghcIosSimulator64-8_4;
  ghcIosSimulator64-8_4 = makeRecursivelyOverridableBHPToo ((makeRecursivelyOverridable nixpkgsCross.ios.simulator64.haskell.packages.integer-simple.ghcSplices-8_4).override {
    overrides = nixpkgsCross.ios.simulator64.haskell.overlays.combined;
  });
  ghcIosSimulator64-8_2 = (makeRecursivelyOverridable nixpkgsCross.ios.simulator64.haskell.packages.integer-simple.ghc822).override {
    overrides = nixpkgsCross.ios.simulator64.haskell.overlays.combined;
  };
  ghcIosAarch64 = if __useLegacyCompilers then ghcIosAarch64-8_2 else ghcIosAarch64-8_4;
  ghcIosAarch64-8_4 = makeRecursivelyOverridableBHPToo ((makeRecursivelyOverridable nixpkgsCross.ios.aarch64.haskell.packages.integer-simple.ghcSplices-8_4).override {
    overrides = nixpkgsCross.ios.aarch64.haskell.overlays.combined;
  });
  ghcIosAarch64-8_2 = (makeRecursivelyOverridable nixpkgsCross.ios.aarch64.haskell.packages.integer-simple.ghc822).override {
    overrides = nixpkgsCross.ios.aarch64.haskell.overlays.combined;
  };
  ghcIosAarch32 = if __useLegacyCompilers then ghcIosAarch32-8_2 else ghcIosAarch32-8_4;
  ghcIosAarch32-8_4 = makeRecursivelyOverridableBHPToo ((makeRecursivelyOverridable nixpkgsCross.ios.aarch32.haskell.packages.integer-simple.ghcSplices-8_4).override {
    overrides = nixpkgsCross.ios.aarch32.haskell.overlays.combined;
  });
  ghcIosAarch32-8_2 = (makeRecursivelyOverridable nixpkgsCross.ios.aarch32.haskell.packages.integer-simple.ghc822).override {
    overrides = nixpkgsCross.ios.aarch32.haskell.overlays.combined;
  };

  #TODO: Separate debug and release APKs
  #TODO: Warn the user that the android app name can't include dashes
  android = androidWithHaskellPackages {
    inherit ghcAndroidAarch64 ghcAndroidAarch32;
  };
  android-8_4 = androidWithHaskellPackages {
    ghcAndroidAarch64 = ghcAndroidAarch64-8_4;
    ghcAndroidAarch32 = ghcAndroidAarch32-8_4;
  };
  android-8_2 = androidWithHaskellPackages {
    ghcAndroidAarch64 = ghcAndroidAarch64-8_2;
    ghcAndroidAarch32 = ghcAndroidAarch32-8_2;
  };
  androidWithHaskellPackages = { ghcAndroidAarch64, ghcAndroidAarch32 }: import ./android {
    inherit nixpkgs nixpkgsCross ghcAndroidAarch64 ghcAndroidAarch32 overrideCabal;
  };
  iosAarch64 = iosWithHaskellPackages ghcIosAarch64;
  iosAarch64-8_4 = iosWithHaskellPackages ghcIosAarch64-8_4;
  iosAarch64-8_2 = iosWithHaskellPackages ghcIosAarch64-8_2;
  iosAarch32 = iosWithHaskellPackages ghcIosAarch32;
  iosAarch32-8_4 = iosWithHaskellPackages ghcIosAarch32-8_4;
  iosAarch32-8_2 = iosWithHaskellPackages ghcIosAarch32-8_2;
  iosWithHaskellPackages = ghc: {
    buildApp = nixpkgs.lib.makeOverridable (import ./ios { inherit nixpkgs ghc; });
  };

in let this = rec {
  inherit (nixpkgs)
    filterGit
    hackGet
    thunkSet
    ;
  inherit nixpkgs
          nixpkgsCross
          overrideCabal
          ghc
          ghcHEAD
          ghc8_4
          ghc8_2
          ghc8_0
          ghc7
          ghcIosSimulator64
          ghcIosAarch64
          ghcIosAarch64-8_4
          ghcIosAarch64-8_2
          ghcIosAarch32
          ghcIosAarch32-8_4
          ghcIosAarch32-8_2
          ghcAndroidAarch64
          ghcAndroidAarch64-8_4
          ghcAndroidAarch64-8_2
          ghcAndroidAarch32
          ghcAndroidAarch32-8_4
          ghcAndroidAarch32-8_2
          ghcjs
          ghcjs8_0
          ghcjs8_2
          ghcjs8_4
          ghcSavedSplices
          android
          androidWithHaskellPackages
          iosAarch32
          iosAarch64
          iosWithHaskellPackages
          ;

  # Back compat
  ios = iosAarch64;
  ghcAndroidArm64 = lib.warn "ghcAndroidArm64 has been deprecated, using ghcAndroidAarch64 instead." ghcAndroidAarch64;
  ghcAndroidArmv7a = lib.warn "ghcAndroidArmv7a has been deprecated, using ghcAndroidAarch32 instead." ghcAndroidAarch32;
  ghcIosArm64 = lib.warn "ghcIosArm64 has been deprecated, using ghcIosAarch64 instead." ghcIosAarch64;

  androidReflexTodomvc = android.buildApp {
    package = p: p.reflex-todomvc;
    executableName = "reflex-todomvc";
    applicationId = "org.reflexfrp.todomvc";
    displayName = "Reflex TodoMVC";
  };
  androidReflexTodomvc-8_4 = android-8_4.buildApp {
    package = p: p.reflex-todomvc;
    executableName = "reflex-todomvc";
    applicationId = "org.reflexfrp.todomvc.via_8_4";
    displayName = "Reflex TodoMVC via GHC 8.4";
  };
  androidReflexTodomvc-8_2 = android-8_2.buildApp {
    package = p: p.reflex-todomvc;
    executableName = "reflex-todomvc";
    applicationId = "org.reflexfrp.todomvc.via_8_2";
    displayName = "Reflex TodoMVC via GHC 8.2";
  };
  iosReflexTodomvc = ios.buildApp {
    package = p: p.reflex-todomvc;
    executableName = "reflex-todomvc";
    bundleIdentifier = "org.reflexfrp.todomvc";
    bundleName = "Reflex TodoMVC";
  };
  iosReflexTodomvc-8_4 = iosAarch64-8_4.buildApp {
    package = p: p.reflex-todomvc;
    executableName = "reflex-todomvc";
    bundleIdentifier = "org.reflexfrp.todomvc.via_8_4";
    bundleName = "Reflex TodoMVC via GHC 8.4";
  };
  iosReflexTodomvc-8_2 = iosAarch64-8_2.buildApp {
    package = p: p.reflex-todomvc;
    executableName = "reflex-todomvc";
    bundleIdentifier = "org.reflexfrp.todomvc.via_8_2";
    bundleName = "Reflex TodoMVC via GHC 8.2";
  };
  setGhcLibdir = ghcLibdir: inputGhcjs:
    let libDir = "$out/lib/ghcjs-${inputGhcjs.version}";
        ghcLibdirLink = nixpkgs.stdenv.mkDerivation {
          name = "ghc_libdir";
          inherit ghcLibdir;
          buildCommand = ''
            mkdir -p ${libDir}
            echo "$ghcLibdir" > ${libDir}/ghc_libdir_override
          '';
        };
    in inputGhcjs // {
    outPath = nixpkgs.buildEnv {
      inherit (inputGhcjs) name;
      paths = [ inputGhcjs ghcLibdirLink ];
      postBuild = ''
        mv ${libDir}/ghc_libdir_override ${libDir}/ghc_libdir
      '';
    };
  };

  platforms = [
    "ghcjs"
    "ghc"
  ];

  androidDevTools = [
    ghc.haven
    nixpkgs.maven
    nixpkgs.androidsdk
  ];

  # Tools that are useful for development under both ghc and ghcjs
  generalDevToolsAttrs = haskellPackages:
    let nativeHaskellPackages = ghc;
    in {
    inherit (nativeHaskellPackages)
      Cabal
      cabal-install
      ghcid
      hasktags
      hdevtools
      hlint;
    inherit (nixpkgs)
      cabal2nix
      curl
      nix-prefetch-scripts
      nodejs
      pkgconfig
      closurecompiler;
  } // (lib.optionalAttrs (!(haskellPackages.ghc.isGhcjs or false) && builtins.compareVersions haskellPackages.ghc.version "8.2" < 0) {
    # ghc-mod doesn't currently work on ghc 8.2.2; revisit when https://github.com/DanielG/ghc-mod/pull/911 is closed
    # When ghc-mod is included in the environment without being wrapped in justStaticExecutables, it prevents ghc-pkg from seeing the libraries we install
    ghc-mod = (nixpkgs.haskell.lib.justStaticExecutables haskellPackages.ghc-mod);
  }) // (lib.optionalAttrs (builtins.compareVersions haskellPackages.ghc.version "7.10" >= 0) {
    inherit (nativeHaskellPackages) stylish-haskell; # Recent stylish-haskell only builds with AMP in place
  });

  generalDevTools = haskellPackages: builtins.attrValues (generalDevToolsAttrs haskellPackages);

  nativeHaskellPackages = haskellPackages:
    if haskellPackages.isGhcjs or false
    then haskellPackages.ghc
    else haskellPackages;

  workOn = haskellPackages: package: (overrideCabal package (drv: {
    buildDepends = (drv.buildDepends or []) ++ generalDevTools (nativeHaskellPackages haskellPackages);
  })).env;

  workOnMulti' = { env, packageNames, tools ? _: [], shellToolOverrides ? _: _: {} }:
    let inherit (builtins) listToAttrs filter attrValues all concatLists;
        combinableAttrs = [
          "benchmarkDepends"
          "benchmarkFrameworkDepends"
          "benchmarkHaskellDepends"
          "benchmarkPkgconfigDepends"
          "benchmarkSystemDepends"
          "benchmarkToolDepends"
          "buildDepends"
          "buildTools"
          "executableFrameworkDepends"
          "executableHaskellDepends"
          "executablePkgconfigDepends"
          "executableSystemDepends"
          "executableToolDepends"
          "extraLibraries"
          "libraryFrameworkDepends"
          "libraryHaskellDepends"
          "libraryPkgconfigDepends"
          "librarySystemDepends"
          "libraryToolDepends"
          "pkgconfigDepends"
          "setupHaskellDepends"
          "testDepends"
          "testFrameworkDepends"
          "testHaskellDepends"
          "testPkgconfigDepends"
          "testSystemDepends"
          "testToolDepends"
        ];
        concatCombinableAttrs = haskellConfigs: lib.filterAttrs (n: v: v != []) (lib.listToAttrs (map (name: { inherit name; value = concatLists (map (haskellConfig: haskellConfig.${name} or []) haskellConfigs); }) combinableAttrs));
        getHaskellConfig = p: (overrideCabal p (args: {
          passthru = (args.passthru or {}) // {
            out = args;
          };
        })).out;
        notInTargetPackageSet = p: all (pname: (p.pname or "") != pname) packageNames;
        baseTools = generalDevToolsAttrs env;
        overriddenTools = attrValues (baseTools // shellToolOverrides env baseTools);
        depAttrs = lib.mapAttrs (_: v: filter notInTargetPackageSet v) (concatCombinableAttrs (concatLists [
          (map getHaskellConfig (lib.attrVals packageNames env))
          [{
            buildTools = overriddenTools ++ tools env;
          }]
        ]));

    in (env.mkDerivation (depAttrs // {
      pname = "work-on-multi--combined-pkg";
      version = "0";
      license = null;
    })).env;

  workOnMulti = env: packageNames: workOnMulti' { inherit env packageNames; };

  # A simple derivation that just creates a file with the names of all
  # of its inputs. If built, it will have a runtime dependency on all
  # of the given build inputs.
  pinBuildInputs = name: buildInputs: (nixpkgs.releaseTools.aggregate {
    inherit name;
    constituents = buildInputs;
  }).overrideAttrs (old: {
    buildCommand = old.buildCommand + ''
      echo "$propagatedBuildInputs $buildInputs $nativeBuildInputs $propagatedNativeBuildInputs" > "$out/deps"
    '';
    inherit buildInputs;
  });

  reflexEnv = platform:
    let haskellPackages = builtins.getAttr platform this;
        ghcWithStuff = if platform == "ghc" || platform == "ghcjs"
                       then haskellPackages.ghcWithHoogle
                       else haskellPackages.ghcWithPackages;
    in ghcWithStuff (p: import ./packages.nix {
      haskellPackages = p;
      inherit platform;
    });

  tryReflexPackages = generalDevTools ghc
    ++ builtins.map reflexEnv platforms;

  cachePackages =
    let otherPlatforms = lib.optionals androidSupport [
          "ghcAndroidAarch64"
          "ghcAndroidAarch32"
        ] ++ lib.optional iosSupport "ghcIosAarch64";
    in tryReflexPackages
      ++ builtins.map reflexEnv otherPlatforms
      ++ lib.optionals androidSupport [
        androidDevTools
        androidReflexTodomvc
      ] ++ lib.optionals iosSupport [
        iosReflexTodomvc
      ];

  inherit cabal2nixResult system androidSupport iosSupport;
  project = args: import ./project this (args ({ pkgs = nixpkgs; } // this));
  tryReflexShell = pinBuildInputs ("shell-" + system) tryReflexPackages;
  ghcjsExternsJs = ./ghcjs.externs.js;
}; in this
