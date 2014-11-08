{-
 - Copyright 2011-2013 Per Magnus Therning
 -
 - Licensed under the Apache License, Version 2.0 (the "License");
 - you may not use this file except in compliance with the License.
 - You may obtain a copy of the License at
 -
 -     http://www.apache.org/licenses/LICENSE-2.0
 -
 - Unless required by applicable law or agreed to in writing, software
 - distributed under the License is distributed on an "AS IS" BASIS,
 - WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 - See the License for the specific language governing permissions and
 - limitations under the License.
 -}

module Util.Misc where

-- {{{1 imports
import qualified PkgDB as DB

import Codec.Archive.Tar as Tar
import Codec.Compression.GZip as GZip
import Control.Exception (onException)
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Data.Either
import Data.Version
import Distribution.Compiler
import Distribution.Package as P
import Distribution.PackageDescription
import Distribution.PackageDescription.Configuration
import Distribution.PackageDescription.Parse
import Distribution.System
import Distribution.Text
import Distribution.Verbosity
import Distribution.Version
import Options.Applicative
import Options.Applicative.Types
import Safe (lastMay)
import System.Directory
import System.Exit
import System.FilePath
import System.IO
import System.Posix.Files
import System.Process
import System.Unix.Directory
import Text.ParserCombinators.ReadP hiding (many)
import qualified Data.ByteString.Lazy.Char8 as BS

-- {{{1 dependency
depName (Dependency (PackageName n) _) = n
depVersionRange (Dependency _ vr) = vr

-- {{{ print functions
printUnSat (n, ds) = do
    putStrLn $ "Failed to satisfy the following dependencies for " ++ n ++ ":"
    mapM_ (putStrLn . ("  " ++) . display) ds

printBrksOth  ((n, v), brks) = do
    putStrLn $ "Adding " ++ n ++ " " ++ display v ++ " would break:"
    mapM_ (\ (bN, Just bD) -> putStrLn $ "  " ++ bN ++ " : " ++ display bD) brks

-- {{{1 program variables
progName = "cblrepo"
dbName = progName ++ ".db"

ghcDefVersion = Version [7, 8, 3] []
ghcVersionDep :: Version -> Int -> String
ghcVersionDep ghcVer ghcRel = "ghc=" ++ display ghcVer ++ "-" ++ show ghcRel

indexUrl = "http://hackage.haskell.org/packages/index.tar.gz"
indexFileName = "index.tar.gz"

-- {{{1 command line parser helpers
readPkgNVersion :: ReadP (String, Version)
readPkgNVersion = do
    n <- many (satisfy (/= ','))
    char ','
    v <- parseVersion
    return (n, v)

readFlag :: ReadP (FlagName, Bool)
readFlag = readNegFlag <++ readPosFlag
    where
        readNegFlag = do
            char '-'
            n <- many (satisfy (/= ','))
            return (FlagName n, False)

        readPosFlag = do
            n0 <- get
            n <- many (satisfy (/= ','))
            return (FlagName (n0 : n), True)

ghcVersionArgReader :: ReadM Version
ghcVersionArgReader = do
    arg <- readerAsk
    case lastMay $ readP_to_S parseVersion arg of
        Just (v, "") -> return v
        _ -> fail $ "cannot parse value `" ++ arg ++ "`"

pkgNVersionArgReader :: ReadM (String, Version)
pkgNVersionArgReader = do
    s <- readerAsk
    case lastMay (readP_to_S readPkgNVersion s) of
        Just (r, "") -> return r
        _ -> fail $ "Cannot parse '" ++ s ++ "' as PKG,VER"

ghcPkgArgReader :: ReadM (String, Version)
ghcPkgArgReader = pkgNVersionArgReader

distroPkgArgReader :: ReadM (String, Version, String)
distroPkgArgReader = let
        readDistroPkg = do
            (n, v) <- readPkgNVersion
            char ','
            r <- many (satisfy (/= ','))
            return (n, v, r)

    in do
        s <- readerAsk
        case lastMay (readP_to_S readDistroPkg s) of
            Just (r, "") -> return r
            _ -> fail $ "Cannot parse '" ++ s ++ "' as PKG,VER,REL"

strCblFileArgReader :: ReadM (FilePath, FlagAssignment)
strCblFileArgReader = let
        readWithFlags = do
            fn <- many $ satisfy (/= ':')
            char ':'
            fas <- sepBy readFlag (char ',')
            return (fn, fas)

        readWithoutFlags = do
            fn <- many $ satisfy (/= ':')
            return (fn, [])

    in do
        s <-readerAsk
        case lastMay (readP_to_S (readWithFlags <++ readWithoutFlags) s) of
            Just (r, "") -> return r
            _ -> fail $ "Cannot parse '" ++ s ++ "' as FILE[:FLAG,-FLAG,..]"

strCblPkgArgReader :: ReadM (String, Version, FlagAssignment)
strCblPkgArgReader = let
        readWithFlags = do
            (n, v) <- readPkgNVersion
            char ':'
            fas <- sepBy readFlag (char ',')
            return (n, v, fas)

        readWithoutFlags = do
            (n, v) <- readPkgNVersion
            return (n, v, [])

    in do
        s <- readerAsk
        case lastMay (readP_to_S (readWithFlags <++ readWithoutFlags) s) of
            Just (r, "") -> return r
            _ -> fail $ "Cannot parse: " ++ s

-- Helper for grabbing things out of the options
optGet :: MonadReader o m => (o -> s) -> m s
optGet f = liftM f ask

-- {{{1 command line argument type
data Cmds
    = CmdAdd
        { patchDir :: FilePath, ghcVer :: Version, cmdAddGhcPkgs :: [(String, Version)]
        , cmdAddDistroPkgs :: [(String, Version, String)], cmdAddFileCbls :: [(FilePath, FlagAssignment)]
        , cmdAddCbls :: [(String, Version, FlagAssignment)] }
    | CmdBuildPkgs { pkgs :: [String] }
    | CmdBumpPkgs { inclusive :: Bool, pkgs :: [String] }
    | CmdSync { unused :: Bool }
    | CmdVersions { latest :: Bool, pkgs :: [String] }
    | CmdListPkgs
        { listGhc :: Bool, listDistro :: Bool, noListRepo :: Bool
        , hackageFmt :: Bool, pkgs :: [String] }
    | CmdUpdates { idxStyle :: Bool }
    | CmdUrls { pkgVers :: [(String, Version)] }
    | CmdPkgBuild { ghcVer :: Version, ghcRel :: Int, patchDir :: FilePath, pkgs :: [String] }
    | CmdConvertDb { inDbFile :: FilePath, outDbFile :: FilePath }
    | CmdRemovePkg { pkgs :: [String] }
    deriving (Show)

data Opts = Opts
    { appDir :: FilePath
    , dbFile :: FilePath
    , dryRun :: Bool
    , optsCmd :: Cmds
    } deriving (Show)

-- {{{1 getFromURL
getFromURL url fn = do
    (ec, _, er) <- readProcessWithExitCode "curl" ["-f", "-L", "-o", fn, url] ""
    case ec of
        ExitSuccess -> return ()
        ExitFailure _ -> do
            hPutStrLn stderr ("Failed downloading " ++ url)
            hPutStrLn stderr er
            exitFailure

-- {{{1 applyPatchIfExist
applyPatch origFilename patchFilename = do
    (ec, _, _) <- liftIO $ readProcessWithExitCode "patch" [origFilename, patchFilename] ""
    case ec of
        ExitSuccess -> return ()
        ExitFailure _ ->
            throwError ("Failed patching " ++ origFilename ++ " with " ++ patchFilename)

applyPatchIfExist origFilename patchFilename =
    liftIO (fileExist patchFilename) >>= flip when (applyPatch origFilename patchFilename)

-- {{{1 index functions
readIndexFile indexLocation = exitOnException
    "Cannot open index file, have you run the 'sync' command?"
    (BS.readFile $ indexLocation </> indexFileName)

-- {{{1 package descriptions
-- {{{2 readCabal
readCabalFromIdx :: FilePath -> FilePath -> (String, Version) -> FilePath -> ErrorT String IO GenericPackageDescription
readCabalFromIdx appDir patchDir (pkgN, pkgVer) destDir = extractCabal >>= readPatchedCabal patchDir
    where
        verStr = display pkgVer
        pathInIdx = pkgN </> verStr </> pkgN ++ ".cabal"
        pkgWithStr = pkgN ++ " " ++ verStr
        fn = destDir </> (pkgN ++ ".cabal")

        esFindEntry (Next e es) = if pathInIdx == entryPath e then Just e else esFindEntry es
        esFindEntry _ = Nothing

        eGetContent e =
            case entryContent e of
                NormalFile c _ -> Just $ BS.unpack c
                _ -> Nothing

        extractCabal = do
            es <- liftM (Tar.read . GZip.decompress) (liftIO $ readIndexFile appDir)
            e <- maybe (throwError $ "No entry for " ++ pkgWithStr)
                return
                (esFindEntry es)
            cbl <- maybe (throwError $ "Failed to extract contents for " ++ pkgWithStr)
                return
                (eGetContent e)
            liftIO $ writeFile fn cbl
            return fn

readPatchedCabal :: FilePath -> FilePath -> ErrorT String IO GenericPackageDescription
readPatchedCabal patchDir cblFn = do
    pn <- liftIO $ extractName cblFn
    let patchFn = patchDir </> pn <.> "cabal"
    applyPatchIfExist cblFn patchFn
    liftIO $ readPackageDescription silent cblFn

    where
        extractName fn = liftM name $ readPackageDescription silent fn
        name = display . pkgName . package . packageDescription

-- {{{2 finalising
finalizePkg ghcVersion db fa gpd = let
        n = ((\ (P.PackageName n) -> n ) . P.pkgName . package . packageDescription) gpd
    in finalizePackageDescription
        fa
        (checkAgainstDb db n)
        (Platform X86_64 buildOS) -- platform
        (CompilerId GHC ghcVersion)  -- compiler version
        [] -- no additional constraints
        gpd

checkAgainstDb db name dep = let
        dN = depName dep
        dVR = depVersionRange dep
    in (dN == name) ||
            (case DB.lookupPkg db dN of
                Nothing -> False
                Just (DB.CP _ p) -> withinRange (DB.version p) dVR)

-- {{{1 Command type
type Command a = ReaderT Opts IO a

runCommand cmds func = runReaderT func cmds

-- {{{1 ErrorT
withTempDirErrT fp func = let
        reWrapErrT (Left e) = throwError e
        reWrapErrT (Right v) = return v
    in do
        r <- liftIO $ withTemporaryDirectory fp (runErrorT . func)
        reWrapErrT r

exitOnErrors vs = let
        es = lefts vs
    in
        if not $ null $ lefts vs
            then liftIO $ mapM_ (hPutStrLn stderr) es >> exitFailure
            else return (rights vs)

exitOnException msg a = onException a $ hPutStrLn stderr msg >> exitFailure
