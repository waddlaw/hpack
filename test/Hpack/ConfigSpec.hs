{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Hpack.ConfigSpec (
  spec

, package
, deps
) where

import           Helper

import           Data.Aeson.Types
import           Data.String.Interpolate.IsString
import           Control.Arrow
import           GHC.Exts
import           System.Directory (createDirectory)
import           Data.Either
import qualified Data.Map.Lazy as Map

import           Hpack.Util
import           Hpack.Dependency
import           Hpack.Config hiding (package)
import qualified Hpack.Config as Config

instance IsList (Maybe (List a)) where
  type Item (Maybe (List a)) = a
  fromList = Just . List
  toList = undefined

deps :: [String] -> Dependencies
deps = Dependencies . Map.fromList . map (flip (,) AnyVersion)

package :: Package
package = Config.package "foo" "0.0.0"

executable :: String -> Executable
executable main_ = Executable (Just main_) ["Paths_foo"]

library :: Library
library = Library Nothing [] ["Paths_foo"] [] []

withPackage :: String -> IO () -> (([String], Package) -> Expectation) -> Expectation
withPackage content beforeAction expectation = withTempDirectory $ \dir_ -> do
  let dir = dir_ </> "foo"
  createDirectory dir
  writeFile (dir </> "package.yaml") content
  withCurrentDirectory dir beforeAction
  r <- readPackageConfig (dir </> "package.yaml")
  either expectationFailure expectation r

withPackageConfig :: String -> IO () -> (Package -> Expectation) -> Expectation
withPackageConfig content beforeAction expectation = withPackage content beforeAction (expectation . snd)

withPackageConfig_ :: String -> (Package -> Expectation) -> Expectation
withPackageConfig_ content = withPackageConfig content (return ())

withPackageWarnings :: String -> IO () -> ([String] -> Expectation) -> Expectation
withPackageWarnings content beforeAction expectation = withPackage content beforeAction (expectation . fst)

withPackageWarnings_ :: String -> ([String] -> Expectation) -> Expectation
withPackageWarnings_ content = withPackageWarnings content (return ())

spec :: Spec
spec = do
  describe "pathsModuleFromPackageName" $ do
    it "replaces dashes with underscores in package name" $ do
      pathsModuleFromPackageName "foo-bar" `shouldBe` "Paths_foo_bar"

  describe "determineModules" $ do
    it "adds the Paths_* module to the other-modules" $ do
      determineModules ["Paths_foo"] [] ["Foo"] Nothing `shouldBe` (["Foo"], ["Paths_foo"])

    it "adds the Paths_* module to the other-modules when no modules are specified" $ do
      determineModules ["Paths_foo"] [] Nothing Nothing `shouldBe` ([], ["Paths_foo"])

    context "when the Paths_* module is part of the exposed-modules" $ do
      it "does not add the Paths_* module to the other-modules" $ do
        determineModules ["Paths_foo"] [] ["Foo", "Paths_foo"] Nothing `shouldBe` (["Foo", "Paths_foo"], [])

  describe "fromLibrarySectionInConditional" $ do
    let
      sect = LibrarySection {
        librarySectionExposed = Nothing
      , librarySectionExposedModules = Nothing
      , librarySectionOtherModules = Nothing
      , librarySectionReexportedModules = Nothing
      , librarySectionSignatures = Nothing
      }
      lib = Library {
        libraryExposed = Nothing
      , libraryExposedModules = []
      , libraryOtherModules = []
      , libraryReexportedModules = []
      , librarySignatures = []
      }
      inferableModules = ["Foo", "Bar"]
      signatures = Nothing
      from = fromLibrarySectionInConditional signatures inferableModules

    context "when inferring modules" $ do
      it "infers other-modules" $ do
        from sect `shouldBe` lib {libraryOtherModules = ["Foo", "Bar"]}

      context "with exposed-modules" $ do
        it "infers nothing" $ do
          from sect {librarySectionExposedModules = []} `shouldBe` lib

      context "with other-modules" $ do
        it "infers nothing" $ do
          from sect {librarySectionOtherModules = []} `shouldBe` lib

  describe "renamePackage" $ do
    it "renames a package" $ do
      renamePackage "bar" package `shouldBe` package {packageName = "bar"}

    it "renames dependencies on self" $ do
      let packageWithExecutable dependencies = package {packageExecutables = Map.fromList [("main", (section $ executable "Main.hs") {sectionDependencies = deps dependencies})]}
      renamePackage "bar" (packageWithExecutable ["foo"]) `shouldBe` (packageWithExecutable ["bar"]) {packageName = "bar"}

  describe "renameDependencies" $ do
    let sectionWithDeps dependencies = (section ()) {sectionDependencies = deps dependencies}

    it "renames dependencies" $ do
      renameDependencies "bar" "baz" (sectionWithDeps ["foo", "bar"]) `shouldBe` sectionWithDeps ["foo", "baz"]

    it "renames dependency in conditionals" $ do
      let sectionWithConditional dependencies = (section ()) {
              sectionConditionals = [
                Conditional {
                  conditionalCondition = "some condition"
                , conditionalThen = sectionWithDeps dependencies
                , conditionalElse = Just (sectionWithDeps dependencies)
                }
                ]
            }
      renameDependencies "bar" "baz" (sectionWithConditional ["foo", "bar"]) `shouldBe` sectionWithConditional ["foo", "baz"]

  describe "getModules" $ around withTempDirectory $ do
    it "returns Haskell modules in specified source directory" $ \dir -> do
      touch (dir </> "src/Foo.hs")
      touch (dir </> "src/Bar/Baz.hs")
      touch (dir </> "src/Setup.hs")
      getModules dir "src" >>= (`shouldMatchList` ["Foo", "Bar.Baz", "Setup"])

    context "when source directory is '.'" $ do
      it "ignores Setup" $ \dir -> do
        touch (dir </> "Foo.hs")
        touch (dir </> "Setup.hs")
        getModules dir  "." `shouldReturn` ["Foo"]

    context "when source directory is './.'" $ do
      it "ignores Setup" $ \dir -> do
        touch (dir </> "Foo.hs")
        touch (dir </> "Setup.hs")
        getModules dir  "./." `shouldReturn` ["Foo"]

  describe "getSignatures" $ around withTempDirectory $ do
    it "returns signatures string in directory" $ \dir -> do
      touch (dir </> "./Foo.hs")
      touch (dir </> "./Bar/Baz.hs")
      touch (dir </> "./Test.hsig")
      touch (dir </> "./Test2.hsig")
      getSignatures dir >>= (`shouldBe` Just (List ["Test", "Test2"]))

  describe "readPackageConfig" $ do
    it "warns on unknown fields" $ do
      withPackageWarnings_ [i|
        name: foo
        bar: 23
        baz: 42
        _qux: 66
        |]
        (`shouldMatchList` [
          "Ignoring unknown field \"bar\" in package description"
        , "Ignoring unknown field \"baz\" in package description"
        ]
        )

    it "warns on unknown fields in when block, list" $ do
      withPackageWarnings_ [i|
        name: foo
        when:
          - condition: impl(ghc)
            bar: 23
            baz: 42
            _qux: 66
        |]
        (`shouldMatchList` [
          "Ignoring unknown field \"_qux\" in package description"
        , "Ignoring unknown field \"bar\" in package description"
        , "Ignoring unknown field \"baz\" in package description"
        ]
        )

    it "warns on unknown fields in when block, single" $ do
      withPackageWarnings_ [i|
        name: foo
        when:
          condition: impl(ghc)
          github: foo/bar
          dependencies: ghc-prim
          baz: 42
        |]
        (`shouldMatchList` [
          "Ignoring unknown field \"baz\" in package description"
        , "Ignoring unknown field \"github\" in package description"
        ]
        )

    it "warns on unknown fields in when block in library section" $ do
      withPackageWarnings_ [i|
        name: foo
        library:
          when:
            condition: impl(ghc)
            baz: 42
        |]
        (`shouldBe` [
          "Ignoring unknown field \"baz\" in library section"
        ]
        )

    it "warns on unknown fields in when block in executable section" $ do
      withPackageWarnings_ [i|
        name: foo
        executables:
          foo:
            main: Main.hs
            when:
              condition: impl(ghc)
              baz: 42
        |]
        (`shouldBe` [
          "Ignoring unknown field \"baz\" in executable section \"foo\""
        ]
        )

    it "warns on missing name" $ do
      withPackageWarnings_ [i|
        {}
        |]
        (`shouldBe` [
          "Package name not specified, inferred \"foo\""
        ]
        )

    it "infers name" $ do
      withPackageConfig_ [i|
        {}
        |]
        (packageName >>> (`shouldBe` "foo"))

    it "accepts name" $ do
      withPackageConfig_ [i|
        name: bar
        |]
        (packageName >>> (`shouldBe` "bar"))

    it "accepts version" $ do
      withPackageConfig_ [i|
        version: 0.1.0
        |]
        (packageVersion >>> (`shouldBe` "0.1.0"))

    it "accepts synopsis" $ do
      withPackageConfig_ [i|
        synopsis: some synopsis
        |]
        (packageSynopsis >>> (`shouldBe` Just "some synopsis"))

    it "accepts description" $ do
      withPackageConfig_ [i|
        description: some description
        |]
        (packageDescription >>> (`shouldBe` Just "some description"))

    it "accepts category" $ do
      withPackageConfig_ [i|
        category: Data
        |]
        (`shouldBe` package {packageCategory = Just "Data"})

    it "accepts author" $ do
      withPackageConfig_ [i|
        author: John Doe
        |]
        (`shouldBe` package {packageAuthor = ["John Doe"]})

    it "accepts maintainer" $ do
      withPackageConfig_ [i|
        maintainer: John Doe <john.doe@example.com>
        |]
        (`shouldBe` package {packageMaintainer = ["John Doe <john.doe@example.com>"]})

    it "accepts copyright" $ do
      withPackageConfig_ [i|
        copyright: (c) 2015 John Doe
        |]
        (`shouldBe` package {packageCopyright = ["(c) 2015 John Doe"]})

    it "accepts stability" $ do
      withPackageConfig_ [i|
        stability: experimental
        |]
        (packageStability >>> (`shouldBe` Just "experimental"))

    it "accepts homepage URL" $ do
      withPackageConfig_ [i|
        github: hspec/hspec
        homepage: https://example.com/
        |]
        (packageHomepage >>> (`shouldBe` Just "https://example.com/"))

    it "infers homepage URL from github" $ do
      withPackageConfig_ [i|
        github: hspec/hspec
        |]
        (packageHomepage >>> (`shouldBe` Just "https://github.com/hspec/hspec#readme"))

    it "omits homepage URL if it is null" $ do
      withPackageConfig_ [i|
        github: hspec/hspec
        homepage: null
        |]
        (packageHomepage >>> (`shouldBe` Nothing))

    it "accepts bug-reports URL" $ do
      withPackageConfig_ [i|
        github: hspec/hspec
        bug-reports: https://example.com/issues
        |]
        (packageBugReports >>> (`shouldBe` Just "https://example.com/issues"))

    it "infers bug-reports URL from github" $ do
      withPackageConfig_ [i|
        github: hspec/hspec
        |]
        (packageBugReports >>> (`shouldBe` Just "https://github.com/hspec/hspec/issues"))

    it "omits bug-reports URL if it is null" $ do
      withPackageConfig_ [i|
        github: hspec/hspec
        bug-reports: null
        |]
        (packageBugReports >>> (`shouldBe` Nothing))

    it "accepts license" $ do
      withPackageConfig_ [i|
        license: MIT
        |]
        (`shouldBe` package {packageLicense = Just "MIT"})

    it "infers license file" $ do
      withPackageConfig [i|
        name: foo
        |]
        (do
        touch "LICENSE"
        )
        (packageLicenseFile >>> (`shouldBe` ["LICENSE"]))

    it "accepts license file" $ do
      withPackageConfig_ [i|
        license-file: FOO
        |]
        (packageLicenseFile >>> (`shouldBe` ["FOO"]))

    it "accepts list of license files" $ do
      withPackageConfig_ [i|
        license-file: [FOO, BAR]
        |]
        (packageLicenseFile >>> (`shouldBe` ["FOO", "BAR"]))

    it "accepts build-type: Simple" $ do
      withPackageConfig_ [i|
        build-type: Simple
        |]
        (`shouldBe` package {packageBuildType = Simple})

    it "accepts build-type: Configure" $ do
      withPackageConfig_ [i|
        build-type: Configure
        |]
        (`shouldBe` package {packageBuildType = Configure})

    it "accepts build-type: Make" $ do
      withPackageConfig_ [i|
        build-type: Make
        |]
        (`shouldBe` package {packageBuildType = Make})

    it "accepts build-type: Custom" $ do
      withPackageConfig_ [i|
        build-type: Custom
        |]
        (`shouldBe` package {packageBuildType = Custom})

    it "rejects unknown build-type" $ do
      parseEither parseJSON (String "foobar") `shouldBe` (Left "Error in $: build-type must be one of: Simple, Configure, Make, Custom" :: Either String BuildType)

    it "accepts flags" $ do
      withPackageConfig_ [i|
        flags:
          integration-tests:
            description: Run the integration test suite
            manual: yes
            default: no
        |]
        (packageFlags >>> (`shouldBe` [Flag "integration-tests" (Just "Run the integration test suite") True False]))

    it "warns on unknown fields in flag sections" $ do
      withPackageWarnings_ [i|
        name: foo
        flags:
          integration-tests:
            description: Run the integration test suite
            manual: yes
            default: no
            foo: 23
        |]
        (`shouldBe` [
          "Ignoring unknown field \"foo\" for flag \"integration-tests\""
        ]
        )

    it "accepts extra-source-files" $ do
      withPackageConfig [i|
        extra-source-files:
          - CHANGES.markdown
          - README.markdown
        |]
        (do
        touch "CHANGES.markdown"
        touch "README.markdown"
        )
        (packageExtraSourceFiles >>> (`shouldBe` ["CHANGES.markdown", "README.markdown"]))

    it "accepts data-files" $ do
      withPackageConfig [i|
        data-files:
          - data/**/*.html
        |]
        (do
        touch "data/foo/index.html"
        touch "data/bar/index.html"
        )
        (packageDataFiles >>> (`shouldMatchList` ["data/foo/index.html", "data/bar/index.html"]))

    it "accepts github" $ do
      withPackageConfig_ [i|
        github: hspec/hspec
        |]
        (packageSourceRepository >>> (`shouldBe` Just (SourceRepository "https://github.com/hspec/hspec" Nothing)))

    it "accepts third part of github URL as subdir" $ do
      withPackageConfig_ [i|
        github: hspec/hspec/hspec-core
        |]
        (packageSourceRepository >>> (`shouldBe` Just (SourceRepository "https://github.com/hspec/hspec" (Just "hspec-core"))))

    it "accepts arbitrary git URLs as source repository" $ do
      withPackageConfig_ [i|
        git: https://gitlab.com/gitlab-org/gitlab-ce.git
        |]
        (packageSourceRepository >>> (`shouldBe` Just (SourceRepository "https://gitlab.com/gitlab-org/gitlab-ce.git" Nothing)))

    it "accepts CPP options" $ do
      withPackageConfig_ [i|
        cpp-options: -DFOO
        library:
          cpp-options: -DLIB

        executables:
          foo:
            main: Main.hs
            cpp-options: -DFOO


        tests:
          spec:
            main: Spec.hs
            cpp-options: -DTEST
        |]
        (`shouldBe` package {
          packageLibrary = Just (section library) {sectionCppOptions = ["-DFOO", "-DLIB"]}
        , packageExecutables = Map.fromList [("foo", (section $ executable "Main.hs") {sectionCppOptions = ["-DFOO", "-DFOO"]})]
        , packageTests = Map.fromList [("spec", (section $ executable "Spec.hs") {sectionCppOptions = ["-DFOO", "-DTEST"]})]
        }
        )

    it "accepts cc-options" $ do
      withPackageConfig_ [i|
        cc-options: -Wall
        library:
          cc-options: -fLIB

        executables:
          foo:
            main: Main.hs
            cc-options: -O2


        tests:
          spec:
            main: Spec.hs
            cc-options: -O0
        |]
        (`shouldBe` package {
          packageLibrary = Just (section library) {sectionCcOptions = ["-Wall", "-fLIB"]}
        , packageExecutables = Map.fromList [("foo", (section $ executable "Main.hs") {sectionCcOptions = ["-Wall", "-O2"]})]
        , packageTests = Map.fromList [("spec", (section $ executable "Spec.hs") {sectionCcOptions = ["-Wall", "-O0"]})]
        }
        )

    it "accepts ghcjs-options" $ do
      withPackageConfig_ [i|
        ghcjs-options: -dedupe
        library:
          ghcjs-options: -ghcjs1

        executables:
          foo:
            main: Main.hs
            ghcjs-options: -ghcjs2


        tests:
          spec:
            main: Spec.hs
            ghcjs-options: -ghcjs3
        |]
        (`shouldBe` package {
          packageLibrary = Just (section library) {sectionGhcjsOptions = ["-dedupe", "-ghcjs1"]}
        , packageExecutables = Map.fromList [("foo", (section $ executable "Main.hs") {sectionGhcjsOptions = ["-dedupe", "-ghcjs2"]})]
        , packageTests = Map.fromList [("spec", (section $ executable "Spec.hs") {sectionGhcjsOptions = ["-dedupe", "-ghcjs3"]})]
        }
        )

    it "accepts ld-options" $ do
      withPackageConfig_ [i|
        library:
          ld-options: -static
        |]
        (`shouldBe` package {
          packageLibrary = Just (section library) {sectionLdOptions = ["-static"]}
        }
        )

    it "accepts buildable" $ do
      withPackageConfig_ [i|
        buildable: no
        library:
          buildable: yes

        executables:
          foo:
            main: Main.hs
        |]
        (`shouldBe` package {
          packageLibrary = Just (section library) {sectionBuildable = Just True}
        , packageExecutables = Map.fromList [("foo", (section $ executable "Main.hs") {sectionBuildable = Just False})]
        }
        )

    it "accepts signatures" $ do
      withPackageConfig_ [i|
        library:
          signatures: Foo
        |]
        (`shouldBe` package {
          packageLibrary =  Just (section (library {librarySignatures = ["Foo"]}))
        }
        )

    it "allows yaml merging and overriding fields" $ do
      withPackageConfig_ [i|
        _common: &common
          name: n1

        <<: *common
        name: n2
        |]
        (packageName >>> (`shouldBe` "n2"))

    context "when reading library section" $ do
      it "warns on unknown fields" $ do
        withPackageWarnings_ [i|
          name: foo
          library:
            bar: 23
            baz: 42
          |]
          (`shouldMatchList` [
            "Ignoring unknown field \"bar\" in library section"
          , "Ignoring unknown field \"baz\" in library section"
          ]
          )

      it "accepts source-dirs" $ do
        withPackageConfig_ [i|
          library:
            source-dirs:
              - foo
              - bar
          |]
          (packageLibrary >>> (`shouldBe` Just (section library) {sectionSourceDirs = ["foo", "bar"]}))

      it "accepts build-tools" $ do
        withPackageConfig_ [i|
          library:
            build-tools:
              - alex
              - happy
          |]
          (packageLibrary >>> (`shouldBe` Just (section library) {sectionBuildTools = deps ["alex", "happy"]}))

      it "accepts default-extensions" $ do
        withPackageConfig_ [i|
          library:
            default-extensions:
              - Foo
              - Bar
          |]
          (packageLibrary >>> (`shouldBe` Just (section library) {sectionDefaultExtensions = ["Foo", "Bar"]}))

      it "accepts global default-extensions" $ do
        withPackageConfig_ [i|
          default-extensions:
            - Foo
            - Bar
          library: {}
          |]
          (packageLibrary >>> (`shouldBe` Just (section library) {sectionDefaultExtensions = ["Foo", "Bar"]}))

      it "accepts global source-dirs" $ do
        withPackageConfig_ [i|
          source-dirs:
            - foo
            - bar
          library: {}
          |]
          (packageLibrary >>> (`shouldBe` Just (section library) {sectionSourceDirs = ["foo", "bar"]}))

      it "accepts global build-tools" $ do
        withPackageConfig_ [i|
          build-tools:
            - alex
            - happy
          library: {}
          |]
          (packageLibrary >>> (`shouldBe` Just (section library) {sectionBuildTools = deps ["alex", "happy"]}))

      it "allows to specify exposed" $ do
        withPackageConfig_ [i|
          library:
            exposed: no
          |]
          (packageLibrary >>> (`shouldBe` Just (section library{libraryExposed = Just False})))

    context "when reading executable section" $ do
      it "warns on unknown fields" $ do
        withPackageWarnings_ [i|
          name: foo
          executables:
            foo:
              main: Main.hs
              bar: 42
              baz: 23
          |]
          (`shouldMatchList` [
            "Ignoring unknown field \"bar\" in executable section \"foo\""
          , "Ignoring unknown field \"baz\" in executable section \"foo\""
          ]
          )

      it "reads executables section" $ do
        withPackageConfig_ [i|
          executables:
            foo:
              main: driver/Main.hs
          |]
          (packageExecutables >>> (`shouldBe` Map.fromList [("foo", section $ executable "driver/Main.hs")]))

      it "reads executable section" $ do
        withPackageConfig_ [i|
          executable:
            main: driver/Main.hs
          |]
          (packageExecutables >>> (`shouldBe` Map.fromList [("foo", section $ executable "driver/Main.hs")]))

      it "warns on unknown executable fields" $ do
        withPackageWarnings_ [i|
          name: foo
          executable:
            main: Main.hs
            unknown: true
          |]
          (`shouldBe` ["Ignoring unknown field \"unknown\" in executable section"])

      context "with both executable and executables" $ do
        it "gives executable precedence" $ do
          withPackageConfig_ [i|
            executable:
              main: driver/Main1.hs
            executables:
              foo2:
                main: driver/Main2.hs
            |]
            (packageExecutables >>> (`shouldBe` Map.fromList [("foo", section $ executable "driver/Main1.hs")]))

        it "warns" $ do
          withPackageWarnings_ [i|
            name: foo
            executable:
              main: driver/Main1.hs
            executables:
              foo2:
                main: driver/Main2.hs
            |]
            (`shouldBe` ["Ignoring field \"executables\" in favor of \"executable\""])

      it "accepts source-dirs" $ do
        withPackageConfig_ [i|
          executables:
            foo:
              main: Main.hs
              source-dirs:
                - foo
                - bar
          |]
          (packageExecutables >>> (`shouldBe` Map.fromList [("foo", (section (executable "Main.hs") {executableOtherModules = ["Paths_foo"]}) {sectionSourceDirs = ["foo", "bar"]})]))

      it "accepts build-tools" $ do
        withPackageConfig_ [i|
          executables:
            foo:
              main: Main.hs
              build-tools:
                - alex
                - happy
          |]
          (packageExecutables >>> (`shouldBe` Map.fromList [("foo", (section $ executable "Main.hs") {sectionBuildTools = deps ["alex", "happy"]})]))

      it "accepts global source-dirs" $ do
        withPackageConfig_ [i|
          source-dirs:
            - foo
            - bar
          executables:
            foo:
              main: Main.hs
          |]
          (packageExecutables >>> (`shouldBe` Map.fromList [("foo", (section (executable "Main.hs") {executableOtherModules = ["Paths_foo"]}) {sectionSourceDirs = ["foo", "bar"]})]))

      it "accepts global build-tools" $ do
        withPackageConfig_ [i|
          build-tools:
            - alex
            - happy
          executables:
            foo:
              main: Main.hs
          |]
          (packageExecutables >>> (`shouldBe` Map.fromList [("foo", (section $ executable "Main.hs") {sectionBuildTools = deps ["alex", "happy"]})]))

      it "accepts default-extensions" $ do
        withPackageConfig_ [i|
          executables:
            foo:
              main: driver/Main.hs
              default-extensions:
                - Foo
                - Bar
          |]
          (packageExecutables >>> (`shouldBe` Map.fromList [("foo", (section $ executable "driver/Main.hs") {sectionDefaultExtensions = ["Foo", "Bar"]})]))

      it "accepts global default-extensions" $ do
        withPackageConfig_ [i|
          default-extensions:
            - Foo
            - Bar
          executables:
            foo:
              main: driver/Main.hs
          |]
          (packageExecutables >>> (`shouldBe` Map.fromList [("foo", (section $ executable "driver/Main.hs") {sectionDefaultExtensions = ["Foo", "Bar"]})]))

      it "accepts GHC options" $ do
        withPackageConfig_ [i|
          executables:
            foo:
              main: driver/Main.hs
              ghc-options: -Wall
          |]
          (`shouldBe` package {packageExecutables = Map.fromList [("foo", (section $ executable "driver/Main.hs") {sectionGhcOptions = ["-Wall"]})]})

      it "accepts global GHC options" $ do
        withPackageConfig_ [i|
          ghc-options: -Wall
          executables:
            foo:
              main: driver/Main.hs
          |]
          (`shouldBe` package {packageExecutables = Map.fromList [("foo", (section $ executable "driver/Main.hs") {sectionGhcOptions = ["-Wall"]})]})

      it "accepts GHC profiling options" $ do
        withPackageConfig_ [i|
          executables:
            foo:
              main: driver/Main.hs
              ghc-prof-options: -fprof-auto
          |]
          (`shouldBe` package {packageExecutables = Map.fromList [("foo", (section $ executable "driver/Main.hs") {sectionGhcProfOptions = ["-fprof-auto"]})]})

      it "accepts global GHC profiling options" $ do
        withPackageConfig_ [i|
          ghc-prof-options: -fprof-auto
          executables:
            foo:
              main: driver/Main.hs
          |]
          (`shouldBe` package {packageExecutables = Map.fromList [("foo", (section $ executable "driver/Main.hs") {sectionGhcProfOptions = ["-fprof-auto"]})]})

    context "when reading benchmark section" $ do
      it "warns on unknown fields" $ do
        withPackageWarnings_ [i|
          name: foo
          benchmarks:
            foo:
              main: Main.hs
              bar: 42
              baz: 23
          |]
          (`shouldMatchList` [
            "Ignoring unknown field \"bar\" in benchmark section \"foo\""
          , "Ignoring unknown field \"baz\" in benchmark section \"foo\""
          ]
          )

    context "when reading test section" $ do
      it "warns on unknown fields" $ do
        withPackageWarnings_ [i|
          name: foo
          tests:
            foo:
              main: Main.hs
              bar: 42
              baz: 23
          |]
          (`shouldMatchList` [
            "Ignoring unknown field \"bar\" in test section \"foo\""
          , "Ignoring unknown field \"baz\" in test section \"foo\""
          ]
          )

      it "reads test section" $ do
        withPackageConfig_ [i|
          tests:
            spec:
              main: test/Spec.hs
          |]
          (`shouldBe` package {packageTests = Map.fromList [("spec", section $ executable "test/Spec.hs")]})

    context "when a specified source directory does not exist" $ do
      it "warns" $ do
        withPackageWarnings [i|
          name: foo
          source-dirs:
            - some-dir
            - some-existing-dir
          library:
            source-dirs: some-lib-dir
          executables:
            main:
              main: Main.hs
              source-dirs: some-exec-dir
          tests:
            spec:
              main: Main.hs
              source-dirs: some-test-dir
          |]
          (do
          touch "some-existing-dir/foo"
          )
          (`shouldBe` [
            "Specified source-dir \"some-dir\" does not exist"
          , "Specified source-dir \"some-exec-dir\" does not exist"
          , "Specified source-dir \"some-lib-dir\" does not exist"
          , "Specified source-dir \"some-test-dir\" does not exist"
          ]
          )

    around withTempDirectory $ do
      context "when package.yaml can not be parsed" $ do
        it "returns an error" $ \dir -> do
          let file = dir </> "package.yaml"
          writeFile file [i|
            foo: bar
            foo baz
            |]
          readPackageConfig file `shouldReturn` Left (file ++ ":3:12: could not find expected ':' while scanning a simple key")

      context "when package.yaml is invalid" $ do
        it "returns an error" $ \dir -> do
          let file = dir </> "package.yaml"
          writeFile file [i|
            - one
            - two
            |]
          readPackageConfig file >>= (`shouldSatisfy` isLeft)

      context "when package.yaml does not exist" $ do
        it "returns an error" $ \dir -> do
          let file = dir </> "package.yaml"
          readPackageConfig file `shouldReturn` Left [i|#{file}: Yaml file not found: #{file}|]
