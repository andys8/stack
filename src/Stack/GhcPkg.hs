{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS -fno-warn-unused-do-bind #-}

-- | Functions for the GHC package database.

module Stack.GhcPkg
  (getPackageVersionMap
  ,findGhcPkgId
  ,getGhcPkgIds
  ,getGlobalDB
  ,EnvOverride(..)
  ,envHelper
  ,unregisterPackage)
  where

import           Control.Applicative
import           Control.Exception hiding (catch)
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Data.Attoparsec.ByteString.Char8
import qualified Data.Attoparsec.ByteString.Lazy as AttoLazy
import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.Lazy as L
import           Data.Data
import           Data.List
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Maybe
import           Data.Monoid ((<>))
import           Data.Streaming.Process
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Path (Path, Abs, Dir, toFilePath, parent, parseAbsDir)
import           Prelude hiding (FilePath)
import           Stack.Types
import           System.Directory (createDirectoryIfMissing, doesDirectoryExist, canonicalizePath)
import           System.Process.Read

-- | A ghc-pkg exception.
data GhcPkgException
  = GetAllPackagesFail
  | GetUserDbPathFail
  | FindPackageIdFail PackageName ProcessExitedUnsuccessfully
  deriving (Typeable,Show)
instance Exception GhcPkgException

-- | Get the global package database
getGlobalDB :: (MonadIO m, MonadLogger m, MonadThrow m)
            => EnvOverride
            -> m (Path Abs Dir)
getGlobalDB menv = do
    -- This seems like a strange way to get the global package database
    -- location, but I don't know of a better one
    bs <- ghcPkg menv [] ["list", "--global"] >>= either throwM return
    let fp = S8.unpack $ stripTrailingColon $ firstLine bs
    liftIO (canonicalizePath fp) >>= parseAbsDir
  where
    stripTrailingColon bs
        | S8.null bs = bs
        | S8.last bs == ':' = S8.init bs
        | otherwise = bs
    firstLine = S8.takeWhile (\c -> c /= '\r' && c /= '\n')

-- | Run the ghc-pkg executable
ghcPkg :: (MonadIO m, MonadLogger m)
       => EnvOverride
       -> [Path Abs Dir]
       -> [String]
       -> m (Either ProcessExitedUnsuccessfully S8.ByteString)
ghcPkg menv pkgDbs args = do
    $logDebug $ "Calling ghc-pkg with: " <> T.pack (show args')
    eres <- go
    case eres of
        Left _ -> do
            forM_ pkgDbs $ \db -> do
                let db' = toFilePath db
                exists <- liftIO $ doesDirectoryExist db'
                unless exists $ do
                    -- Creating the parent doesn't seem necessary, as ghc-pkg
                    -- seems to be sufficiently smart. But I don't feel like
                    -- finding out it isn't the hard way
                    liftIO $ createDirectoryIfMissing True $ toFilePath $ parent db
                    _ <- tryProcessStdout menv "ghc-pkg" ["init", db']
                    return ()
            go
        Right _ -> return eres
  where
    args' =
          "--no-user-package-db"
        : map (\x -> ("--package-db=" ++ toFilePath x)) pkgDbs
       ++ args
    go = tryProcessStdout menv "ghc-pkg" args'

-- | Get all available packages.
getPackageVersionMap :: (MonadCatch m, MonadIO m, MonadThrow m, MonadLogger m)
                     => EnvOverride
                     -> [Path Abs Dir] -- ^ package databases
                     -> m (Map PackageName Version)
getPackageVersionMap menv pkgDbs = do
    result <-
        ghcPkg menv pkgDbs ["--global", "list"]
    case result of
        Left{} ->
            throw GetAllPackagesFail
        Right lbs ->
            case AttoLazy.parse
                     pkgsListParser
                     (L.fromStrict lbs) of
                AttoLazy.Fail _ _ _ ->
                    throw GetAllPackagesFail
                AttoLazy.Done _ r ->
                    liftIO (evaluate r)

-- | Parser for ghc-pkg's list output.
pkgsListParser :: Parser (Map PackageName Version)
pkgsListParser =
  -- Use unionsWith max to account for cases where the snapshot introduces a
  -- newer version of a global package, see:
  -- https://github.com/fpco/stack/issues/78
  fmap (M.unionsWith max . map M.fromList) sections
  where sections =
          many (heading *>
                (many (pkg <* endOfLine)) <*
                optional endOfLine)
        heading =
          many1 (satisfy (not . (== '\n'))) <*
          endOfLine
        pkg =
          do space
             space
             space
             space
             fmap toTuple (packageIdentifierParser <|>
                ("(" *> packageIdentifierParser <* ")")) -- hidden packages

-- | Get the id of the package e.g. @foo-0.0.0-9c293923c0685761dcff6f8c3ad8f8ec@.
findGhcPkgId :: (MonadIO m, MonadLogger m)
             => EnvOverride
             -> [Path Abs Dir] -- ^ package databases
             -> PackageName
             -> m (Maybe GhcPkgId)
findGhcPkgId menv pkgDbs name = do
    result <-
        ghcPkg menv pkgDbs ["describe", packageNameString name]
    case result of
        Left{} ->
            return Nothing
        Right lbs -> do
            let mpid =
                    fmap
                        T.encodeUtf8
                        (listToMaybe
                             (mapMaybe
                                  (fmap stripCR .
                                   T.stripPrefix "id: ")
                                  (map T.decodeUtf8 (S8.lines lbs))))
            case mpid of
                Just !pid ->
                    return (parseGhcPkgId pid)
                _ ->
                    return Nothing
  where
    stripCR t =
        fromMaybe t (T.stripSuffix "\r" t)

-- | Get all current package ids.
getGhcPkgIds :: (MonadIO m, MonadLogger m)
             => EnvOverride
             -> [Path Abs Dir] -- ^ package databases
             -> [PackageName]
             -> m (Map PackageName GhcPkgId)
getGhcPkgIds menv pkgDbs pkgs =
    collect pkgs >>= liftIO . evaluate
  where
    collect =
        liftM (M.fromList . catMaybes) .
        mapM getTuple
    getTuple name = do
        mpid <- findGhcPkgId menv pkgDbs name
        case mpid of
            Nothing ->
                return Nothing
            Just pid ->
                return (Just (name, pid))

-- | Unregister the given package.
unregisterPackage :: (MonadIO m,MonadLogger m,MonadThrow m)
                  => EnvOverride -> PackageIdentifier -> m ()
unregisterPackage menv ident =
    liftM
        (const ())
        (ghcPkg menv [] ["unregister", "--force", packageIdentifierString ident] >>=
         either throwM return)
