{
  lib,
  runtimeShell,
  stdenvNoCC,
  callPackage,
  substituteAll,
  writeShellScript,
  makeWrapper,
  dotnetCorePackages,
  mkNugetDeps,
  nuget-to-nix,
  cacert,
  unzip,
  yq,
  nix,
}:
let
  transformArgs =
    finalAttrs:
    {
      name ? "${args.pname}-${args.version}",
      pname ? name,
      enableParallelBuilding ? true,
      doCheck ? false,
      # Flags to pass to `makeWrapper`. This is done to avoid double wrapping.
      makeWrapperArgs ? [ ],

      # Flags to pass to `dotnet restore`.
      dotnetRestoreFlags ? [ ],
      # Flags to pass to `dotnet build`.
      dotnetBuildFlags ? [ ],
      # Flags to pass to `dotnet test`, if running tests is enabled.
      dotnetTestFlags ? [ ],
      # Flags to pass to `dotnet install`.
      dotnetInstallFlags ? [ ],
      # Flags to pass to `dotnet pack`.
      dotnetPackFlags ? [ ],
      # Flags to pass to dotnet in all phases.
      dotnetFlags ? [ ],

      # The path to publish the project to. When unset, the directory "$out/lib/$pname" is used.
      installPath ? null,
      # The binaries that should get installed to `$out/bin`, relative to `$installPath/`. These get wrapped accordingly.
      # Unfortunately, dotnet has no method for doing this automatically.
      # If unset, all executables in the projects root will get installed. This may cause bloat!
      executables ? null,
      # Packs a project as a `nupkg`, and installs it to `$out/share`. If set to `true`, the derivation can be used as a dependency for another dotnet project by adding it to `projectReferences`.
      packNupkg ? false,
      # The packages project file, which contains instructions on how to compile it. This can be an array of multiple project files as well.
      projectFile ? null,
      # The NuGet dependency file. This locks all NuGet dependency versions, as otherwise they cannot be deterministically fetched.
      # This can be generated by running the `passthru.fetch-deps` script.
      nugetDeps ? null,
      # A list of derivations containing nupkg packages for local project references.
      # Referenced derivations can be built with `buildDotnetModule` with `packNupkg=true` flag.
      # Since we are sharing them as nugets they must be added to csproj/fsproj files as `PackageReference` as well.
      # For example, your project has a local dependency:
      #     <ProjectReference Include="../foo/bar.fsproj" />
      # To enable discovery through `projectReferences` you would need to add a line:
      #     <ProjectReference Include="../foo/bar.fsproj" />
      #     <PackageReference Include="bar" Version="*" Condition=" '$(ContinuousIntegrationBuild)'=='true' "/>
      projectReferences ? [ ],
      # Libraries that need to be available at runtime should be passed through this.
      # These get wrapped into `LD_LIBRARY_PATH`.
      runtimeDeps ? [ ],
      # The dotnet runtime ID. If null, fetch-deps will gather dependencies for all
      # platforms in meta.platforms which are supported by the sdk.
      runtimeId ? null,

      # Tests to disable. This gets passed to `dotnet test --filter "FullyQualifiedName!={}"`, to ensure compatibility with all frameworks.
      # See https://docs.microsoft.com/en-us/dotnet/core/tools/dotnet-test#filter-option-details for more details.
      disabledTests ? [ ],
      # The project file to run unit tests against. This is usually referenced in the regular project file, but sometimes it needs to be manually set.
      # It gets restored and build, but not installed. You may need to regenerate your nuget lockfile after setting this.
      testProjectFile ? null,

      # The type of build to perform. This is passed to `dotnet` with the `--configuration` flag. Possible values are `Release`, `Debug`, etc.
      buildType ? "Release",
      # If set to true, builds the application as a self-contained - removing the runtime dependency on dotnet
      selfContainedBuild ? false,
      # Whether to use an alternative wrapper, that executes the application DLL using the dotnet runtime from the user environment. `dotnet-runtime` is provided as a default in case no .NET is installed
      # This is useful for .NET tools and applications that may need to run under different .NET runtimes
      useDotnetFromEnv ? false,
      # Whether to explicitly enable UseAppHost when building. This is redundant if useDotnetFromEnv is enabled
      useAppHost ? true,
      # The dotnet SDK to use.
      dotnet-sdk ? dotnetCorePackages.sdk_6_0,
      # The dotnet runtime to use.
      dotnet-runtime ? dotnetCorePackages.runtime_6_0,
      ...
    }@args:
    let
      projectFiles = lib.optionals (projectFile != null) (lib.toList projectFile);
      testProjectFiles = lib.optionals (testProjectFile != null) (lib.toList testProjectFile);

      platforms =
        if args ? meta.platforms then
          lib.intersectLists args.meta.platforms dotnet-sdk.meta.platforms
        else
          dotnet-sdk.meta.platforms;

      inherit (callPackage ./hooks { inherit dotnet-sdk dotnet-runtime; })
        dotnetConfigureHook
        dotnetBuildHook
        dotnetCheckHook
        dotnetInstallHook
        dotnetFixupHook
        ;

      _nugetDeps =
        if (nugetDeps != null) then
          if lib.isDerivation nugetDeps then
            nugetDeps
          else
            mkNugetDeps {
              inherit name;
              sourceFile = nugetDeps;
            }
        else
          throw "Defining the `nugetDeps` attribute is required, as to lock the NuGet dependencies. This file can be generated by running the `passthru.fetch-deps` script.";

      nugetDepsFile = _nugetDeps.sourceFile;

      inherit (dotnetCorePackages) systemToDotnetRid;
    in
    # Not all args need to be passed through to mkDerivation
    # TODO: We should probably filter out even more attrs
    removeAttrs args [ "nugetDeps" ]
    // {
      dotnetInstallPath = installPath;
      dotnetExecutables = executables;
      dotnetBuildType = buildType;
      dotnetProjectFiles = projectFiles;
      dotnetTestProjectFiles = testProjectFiles;
      dotnetDisabledTests = disabledTests;
      dotnetRuntimeIds = lib.singleton (
        if runtimeId != null then runtimeId else systemToDotnetRid stdenvNoCC.hostPlatform.system
      );
      dotnetRuntimeDeps = map lib.getLib runtimeDeps;
      dotnetSelfContainedBuild = selfContainedBuild;
      dotnetUseAppHost = useAppHost;
      inherit useDotnetFromEnv;

      nativeBuildInputs = args.nativeBuildInputs or [ ] ++ [
        dotnetConfigureHook
        dotnetBuildHook
        dotnetCheckHook
        dotnetInstallHook
        dotnetFixupHook

        cacert
        makeWrapper
        dotnet-sdk
        unzip
        yq
      ];

      buildInputs =
        args.buildInputs or [ ]
        ++ [
          dotnet-sdk.packages
          _nugetDeps
        ]
        ++ projectReferences;

      # Parse the version attr into a format acceptable for the Version msbuild property
      # The actual version attr is saved in InformationalVersion, which accepts an arbitrary string
      versionForDotnet =
        if !(lib.hasAttr "version" args) || args.version == null then
          null
        else
          let
            components = lib.pipe args.version [
              lib.splitVersion
              (lib.filter (x: (lib.strings.match "[0-9]+" x) != null))
              (lib.filter (x: (lib.toIntBase10 x) < 65535)) # one version component in dotnet has to fit in 16 bits
            ];
          in
          if (lib.length components) == 0 then
            null
          else
            lib.concatStringsSep "." (
              (lib.take 4 components)
              ++ (if (lib.length components) < 4 then lib.replicate (4 - (lib.length components)) "0" else [ ])
            );

      makeWrapperArgs = args.makeWrapperArgs or [ ] ++ [
        "--prefix"
        "LD_LIBRARY_PATH"
        ":"
        "${dotnet-sdk.icu}/lib"
      ];

      # Stripping breaks the executable
      dontStrip = args.dontStrip or true;

      # gappsWrapperArgs gets included when wrapping for dotnet, as to avoid double wrapping
      dontWrapGApps = args.dontWrapGApps or true;

      # propagate the runtime sandbox profile since the contents apply to published
      # executables
      propagatedSandboxProfile = toString dotnet-runtime.__propagatedSandboxProfile;

      passthru =
        {
          nugetDeps = _nugetDeps;
        }
        // lib.optionalAttrs (!lib.isDerivation nugetDeps) {
          fetch-deps =
            let
              pkg = finalAttrs.finalPackage.overrideAttrs (
                old:
                {
                  buildInputs = lib.remove _nugetDeps old.buildInputs;
                  keepNugetConfig = true;
                }
                // lib.optionalAttrs (runtimeId == null) {
                  dotnetRuntimeIds = map (system: systemToDotnetRid system) platforms;
                }
              );

              drv = builtins.unsafeDiscardOutputDependency pkg.drvPath;

              innerScript = substituteAll {
                src = ./fetch-deps.sh;
                isExecutable = true;
                defaultDepsFile =
                  # Wire in the nugetDeps file such that running the script with no args
                  # runs it agains the correct deps file by default.
                  # Note that toString is necessary here as it results in the path at
                  # eval time (i.e. to the file in your local Nixpkgs checkout) rather
                  # than the Nix store path of the path after it's been imported.
                  if lib.isPath nugetDepsFile && !lib.hasPrefix "${builtins.storeDir}/" (toString nugetDepsFile) then
                    toString nugetDepsFile
                  else
                    ''$(mktemp -t "${pname}-deps-XXXXXX.nix")'';
                nugetToNix = (nuget-to-nix.override { inherit dotnet-sdk; });
              };

            in
            writeShellScript "${name}-fetch-deps" ''
              NIX_BUILD_SHELL="${runtimeShell}" exec ${nix}/bin/nix-shell \
                --pure --run 'source "${innerScript}"' "${drv}"
            '';
        }
        // args.passthru or { };

      meta = (args.meta or { }) // {
        inherit platforms;
      };
    };
in
fnOrAttrs:
stdenvNoCC.mkDerivation (
  finalAttrs:
  let
    args = if lib.isFunction fnOrAttrs then fnOrAttrs (args // finalAttrs) else fnOrAttrs;
  in
  transformArgs finalAttrs args
)
