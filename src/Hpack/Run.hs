{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE CPP #-}
module Hpack.Run (
  run
, renderPackage
, RenderSettings(..)
, Alignment(..)
, CommaStyle(..)
, defaultRenderSettings
#ifdef TEST
, renderConditional
, renderLibraryFields
, renderExecutableFields
, renderFlag
, renderSourceRepository
, renderDirectories
, formatDescription
#endif
) where

import           Control.Monad
import           Data.Char
import           Data.Maybe
import           Data.List
import           System.Exit
import           System.FilePath
import           Data.Version
import           Data.Map.Lazy (Map)
import qualified Data.Map.Lazy as Map

import           Hpack.Util
import           Hpack.Config
import           Hpack.Render
import           Hpack.FormattingHints

run :: Maybe FilePath -> FilePath -> IO ([String], FilePath, String)
run mDir c = do
  let dir = fromMaybe "" mDir
  mPackage <- readPackageConfig (dir </> c)
  case mPackage of
    Right (warnings, pkg) -> do
      let cabalFile = dir </> (packageName pkg ++ ".cabal")

      old <- tryReadFile cabalFile

      let
        FormattingHints{..} = sniffFormattingHints (fromMaybe "" old)
        alignment = fromMaybe 16 formattingHintsAlignment
        settings = formattingHintsRenderSettings

        output = renderPackage settings alignment formattingHintsFieldOrder formattingHintsSectionsFieldOrder pkg

      return (warnings, cabalFile, output)
    Left err -> die err

renderPackage :: RenderSettings -> Alignment -> [String] -> [(String, [String])] -> Package -> String
renderPackage settings alignment existingFieldOrder sectionsFieldOrder Package{..} = intercalate "\n" (unlines header : chunks)
  where
    chunks :: [String]
    chunks = map unlines . filter (not . null) . map (render settings 0) $ sortSectionFields sectionsFieldOrder stanzas

    header :: [String]
    header = concatMap (render settings {renderSettingsFieldAlignment = alignment} 0) fields

    extraSourceFiles :: Element
    extraSourceFiles = Field "extra-source-files" (LineSeparatedList packageExtraSourceFiles)

    extraDocFiles :: Element
    extraDocFiles = Field "extra-doc-files" (LineSeparatedList packageExtraDocFiles)

    dataFiles :: Element
    dataFiles = Field "data-files" (LineSeparatedList packageDataFiles)

    sourceRepository :: [Element]
    sourceRepository = maybe [] (return . renderSourceRepository) packageSourceRepository

    customSetup :: [Element]
    customSetup = maybe [] (return . renderCustomSetup) packageCustomSetup

    library :: [Element]
    library = maybe [] (return . renderLibrary) packageLibrary

    stanzas :: [Element]
    stanzas =
      extraSourceFiles
      : extraDocFiles
      : dataFiles
      : sourceRepository
      ++ concat [
        customSetup
      , map renderFlag packageFlags
      , library
      , renderInternalLibraries packageInternalLibraries
      , renderExecutables packageExecutables
      , renderTests packageTests
      , renderBenchmarks packageBenchmarks
      ]

    fields :: [Element]
    fields = sortFieldsBy existingFieldOrder . mapMaybe (\(name, value) -> Field name . Literal <$> value) $ [
        ("name", Just packageName)
      , ("version", Just packageVersion)
      , ("synopsis", packageSynopsis)
      , ("description", (formatDescription alignment <$> packageDescription))
      , ("category", packageCategory)
      , ("stability", packageStability)
      , ("homepage", packageHomepage)
      , ("bug-reports", packageBugReports)
      , ("author", formatList packageAuthor)
      , ("maintainer", formatList packageMaintainer)
      , ("copyright", formatList packageCopyright)
      , ("license", packageLicense)
      , case packageLicenseFile of
          [file] -> ("license-file", Just file)
          files  -> ("license-files", formatList files)
      , ("tested-with", packageTestedWith)
      , ("build-type", Just (show packageBuildType))
      , ("cabal-version", cabalVersion)
      ]

    formatList :: [String] -> Maybe String
    formatList xs = guard (not $ null xs) >> (Just $ intercalate separator xs)
      where
        separator = let Alignment n = alignment in ",\n" ++ replicate n ' '

    cabalVersion :: Maybe String
    cabalVersion = (">= " ++) . showVersion <$> maximum [
        Just (makeVersion [1,10])
      , packageCabalVersion
      , packageLibrary >>= libraryCabalVersion . sectionData
      , internalLibsCabalVersion packageInternalLibraries
      ]
     where
      packageCabalVersion :: Maybe Version
      packageCabalVersion
        | isJust packageCustomSetup = Just (makeVersion [1,24])
        | otherwise = Nothing

      libraryCabalVersion :: Library -> Maybe Version
      libraryCabalVersion Library{..} = maximum [
          makeVersion [1,22] <$ guard hasReexportedModules
        , makeVersion [2,0]  <$ guard hasSignatures
        ]
        where
          hasReexportedModules = (not . null) libraryReexportedModules
          hasSignatures = (not . null) librarySignatures

      internalLibsCabalVersion :: Map String (Section Library) -> Maybe Version
      internalLibsCabalVersion internalLibraries = makeVersion [2,0] <$ guard (not (Map.null internalLibraries))

sortSectionFields :: [(String, [String])] -> [Element] -> [Element]
sortSectionFields sectionsFieldOrder = go
  where
    go sections = case sections of
      [] -> []
      Stanza name fields : xs | Just fieldOrder <- lookup name sectionsFieldOrder -> Stanza name (sortFieldsBy fieldOrder fields) : go xs
      x : xs -> x : go xs

formatDescription :: Alignment -> String -> String
formatDescription (Alignment alignment) description = case map emptyLineToDot $ lines description of
  x : xs -> intercalate "\n" (x : map (indentation ++) xs)
  [] -> ""
  where
    n = max alignment (length ("description: " :: String))
    indentation = replicate n ' '

    emptyLineToDot xs
      | isEmptyLine xs = "."
      | otherwise = xs

    isEmptyLine = all isSpace

renderSourceRepository :: SourceRepository -> Element
renderSourceRepository SourceRepository{..} = Stanza "source-repository head" [
    Field "type" "git"
  , Field "location" (Literal sourceRepositoryUrl)
  , Field "subdir" (maybe "" Literal sourceRepositorySubdir)
  ]

renderFlag :: Flag -> Element
renderFlag Flag {..} = Stanza ("flag " ++ flagName) $ description ++ [
    Field "manual" (Literal $ show flagManual)
  , Field "default" (Literal $ show flagDefault)
  ]
  where
    description = maybe [] (return . Field "description" . Literal) flagDescription

renderInternalLibraries :: Map String (Section Library) -> [Element]
renderInternalLibraries = map renderInternalLibrary . Map.toList

renderInternalLibrary :: (String, Section Library) -> Element
renderInternalLibrary (name, sect) =
  Stanza ("library " ++ name) (renderLibrarySection sect)

renderExecutables :: Map String (Section Executable) -> [Element]
renderExecutables = map renderExecutable . Map.toList

renderExecutable :: (String, Section Executable) -> Element
renderExecutable (name, sect@(sectionData -> Executable{..})) =
  Stanza ("executable " ++ name) (renderExecutableSection sect)

renderTests :: Map String (Section Executable) -> [Element]
renderTests = map renderTest . Map.toList

renderTest :: (String, Section Executable) -> Element
renderTest (name, sect) =
  Stanza ("test-suite " ++ name)
    (Field "type" "exitcode-stdio-1.0" : renderExecutableSection sect)

renderBenchmarks :: Map String (Section Executable) -> [Element]
renderBenchmarks = map renderBenchmark . Map.toList

renderBenchmark :: (String, Section Executable) -> Element
renderBenchmark (name, sect) =
  Stanza ("benchmark " ++ name)
    (Field "type" "exitcode-stdio-1.0" : renderExecutableSection sect)

renderExecutableSection :: Section Executable -> [Element]
renderExecutableSection sect = renderSection renderExecutableFields sect ++ [defaultLanguage]

renderExecutableFields :: Executable -> [Element]
renderExecutableFields Executable{..} = mainIs ++ [otherModules]
  where
    mainIs = maybe [] (return . Field "main-is" . Literal) executableMain
    otherModules = renderOtherModules executableOtherModules

renderCustomSetup :: CustomSetup -> Element
renderCustomSetup CustomSetup{..} =
  Stanza "custom-setup" [renderDependencies "setup-depends" customSetupDependencies]

renderLibrary :: Section Library -> Element
renderLibrary sect = Stanza "library" $ renderLibrarySection sect

renderLibrarySection :: Section Library -> [Element]
renderLibrarySection sect = renderSection renderLibraryFields sect ++ [defaultLanguage]

renderLibraryFields :: Library -> [Element]
renderLibraryFields Library{..} =
  maybe [] (return . renderExposed) libraryExposed ++ [
    renderExposedModules libraryExposedModules
  , renderOtherModules libraryOtherModules
  , renderReexportedModules libraryReexportedModules
  , renderSignatures librarySignatures
  ]

renderExposed :: Bool -> Element
renderExposed = Field "exposed" . Literal . show

renderSection :: (a -> [Element]) -> Section a -> [Element]
renderSection renderSectionData Section{..} =
  renderSectionData sectionData ++ [
    renderDirectories "hs-source-dirs" sectionSourceDirs
  , renderDefaultExtensions sectionDefaultExtensions
  , renderOtherExtensions sectionOtherExtensions
  , renderGhcOptions sectionGhcOptions
  , renderGhcProfOptions sectionGhcProfOptions
  , renderGhcjsOptions sectionGhcjsOptions
  , renderCppOptions sectionCppOptions
  , renderCcOptions sectionCcOptions
  , renderDirectories "include-dirs" sectionIncludeDirs
  , Field "install-includes" (LineSeparatedList sectionInstallIncludes)
  , Field "c-sources" (LineSeparatedList sectionCSources)
  , Field "js-sources" (LineSeparatedList sectionJsSources)
  , renderDirectories "extra-lib-dirs" sectionExtraLibDirs
  , Field "extra-libraries" (LineSeparatedList sectionExtraLibraries)
  , renderDirectories "extra-frameworks-dirs" sectionExtraFrameworksDirs
  , Field "frameworks" (LineSeparatedList sectionFrameworks)
  , renderLdOptions sectionLdOptions
  , renderDependencies "build-depends" sectionDependencies
  , Field "pkgconfig-depends" (CommaSeparatedList sectionPkgConfigDependencies)
  , renderDependencies "build-tools" sectionBuildTools
  ]
  ++ maybe [] (return . renderBuildable) sectionBuildable
  ++ map (renderConditional renderSectionData) sectionConditionals

renderConditional :: (a -> [Element]) -> Conditional (Section a) -> Element
renderConditional renderSectionData (Conditional condition sect mElse) = case mElse of
  Nothing -> if_
  Just else_ -> Group if_ (Stanza "else" $ renderSection renderSectionData else_)
  where
    if_ = Stanza ("if " ++ condition) (renderSection renderSectionData sect)

defaultLanguage :: Element
defaultLanguage = Field "default-language" "Haskell2010"

renderDirectories :: String -> [String] -> Element
renderDirectories name = Field name . LineSeparatedList . replaceDots
  where
    replaceDots = map replaceDot
    replaceDot xs = case xs of
      "." -> "./."
      _ -> xs

renderExposedModules :: [String] -> Element
renderExposedModules = Field "exposed-modules" . LineSeparatedList

renderOtherModules :: [String] -> Element
renderOtherModules = Field "other-modules" . LineSeparatedList

renderReexportedModules :: [String] -> Element
renderReexportedModules = Field "reexported-modules" . LineSeparatedList

renderSignatures :: [String] -> Element
renderSignatures = Field "signatures" . CommaSeparatedList

renderDependencies :: String -> Dependencies -> Element
renderDependencies name = Field name . CommaSeparatedList . map renderDependency . Map.toList . unDependencies

renderDependency :: (String, DependencyVersion) -> String
renderDependency (name, version) = name ++ v
  where
    v = case version of
      AnyVersion -> ""
      VersionRange x -> " " ++ x
      SourceDependency _ -> ""

renderGhcOptions :: [GhcOption] -> Element
renderGhcOptions = Field "ghc-options" . WordList

renderGhcProfOptions :: [GhcProfOption] -> Element
renderGhcProfOptions = Field "ghc-prof-options" . WordList

renderGhcjsOptions :: [GhcjsOption] -> Element
renderGhcjsOptions = Field "ghcjs-options" . WordList

renderCppOptions :: [CppOption] -> Element
renderCppOptions = Field "cpp-options" . WordList

renderCcOptions :: [CcOption] -> Element
renderCcOptions = Field "cc-options" . WordList

renderLdOptions :: [LdOption] -> Element
renderLdOptions = Field "ld-options" . WordList

renderBuildable :: Bool -> Element
renderBuildable = Field "buildable" . Literal . show

renderDefaultExtensions :: [String] -> Element
renderDefaultExtensions = Field "default-extensions" . WordList

renderOtherExtensions :: [String] -> Element
renderOtherExtensions = Field "other-extensions" . WordList
