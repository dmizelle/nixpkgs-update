{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

module Update
  ( addPatched,
    assertNotUpdatedOn,
    cveAll,
    cveReport,
    prMessage,
    sourceGithubAll,
    updateAll,
    updatePackage,
  )
where

import CVE (CVE, cveID, cveLI)
import qualified Check
import Control.Concurrent
import Control.Exception (IOException, catch, bracket)
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Maybe (fromJust)
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time.Calendar (showGregorian)
import Data.Time.Clock (getCurrentTime, utctDay)
import qualified GH
import qualified Git
import Language.Haskell.TH.Env (envQ)
import NVD (getCVEs, withVulnDB)
import qualified Nix
import qualified NixpkgsReview
import OurPrelude
import qualified Outpaths
import qualified Rewrite
import qualified Skiplist
import qualified Time
import Utils
  ( Options (..),
    URL,
    UpdateEnv (..),
    Version,
    branchName,
    logDir,
    parseUpdates,
    prTitle,
    whenBatch,
  )
import qualified Utils as U
import qualified Version
import Prelude hiding (log)
import System.Directory (doesDirectoryExist, withCurrentDirectory)
import System.Posix.Directory (createDirectory)

default (T.Text)

alsoLogToAttrPath :: Text -> (Text -> IO()) -> IO (Text -> IO())
alsoLogToAttrPath attrPath topLevelLog = do
  logFile <- attrPathLogFilePath attrPath
  let attrPathLog = log' logFile
  return \text -> do
    topLevelLog text
    attrPathLog text

log' :: MonadIO m => FilePath -> Text -> m ()
log' logFile msg = do
  runDate <- liftIO $ runM $ Time.runIO Time.runDate
  liftIO $ T.appendFile logFile (runDate <> " " <> msg <> "\n")

attrPathLogFilePath :: Text -> IO String
attrPathLogFilePath attrPath = do
  lDir <- logDir
  now <- getCurrentTime
  let dir = lDir <> "/" <> T.unpack attrPath
  dirExists <- doesDirectoryExist dir
  unless
    dirExists
    (createDirectory dir U.regDirMode)
  let logFile = dir <> "/" <> showGregorian (utctDay now) <> ".log"
  putStrLn ("For attrpath " <> T.unpack attrPath <> ", using log file: " <> logFile)
  return logFile

logFileName :: IO String
logFileName = do
  lDir <- logDir
  now <- getCurrentTime
  let logFile = lDir <> "/" <> showGregorian (utctDay now) <> ".log"
  putStrLn ("Using log file: " <> logFile)
  return logFile

getLog :: Options -> IO (Text -> IO ())
getLog o = do
  if batchUpdate o
    then do
      logFile <- logFileName
      let log = log' logFile
      T.appendFile logFile "\n\n"
      return log
    else return T.putStrLn

notifyOptions :: (Text -> IO ()) -> Options -> IO ()
notifyOptions log o = do
  let repr f = if f o then "YES" else "NO"
  let ghUser = GH.untagName . githubUser $ o
  let pr = repr doPR
  let outpaths = repr calculateOutpaths
  let cve = repr makeCVEReport
  let review = repr runNixpkgsReview
  let exactAttrPath = repr U.attrpath
  npDir <- tshow <$> Git.nixpkgsDir
  log $
    [interpolate|
    Configured Nixpkgs-Update Options:
    ----------------------------------
    GitHub User:                   $ghUser
    Send pull request on success:  $pr
    Calculate Outpaths:            $outpaths
    CVE Security Report:           $cve
    Run nixpkgs-review:            $review
    Nixpkgs Dir:                   $npDir
    update info uses attrpath:     $exactAttrPath
    ----------------------------------|]

updateAll :: Options -> Text -> IO ()
updateAll o updates = do
  log <- getLog o
  log "New run of nixpkgs-update"
  notifyOptions log o
  updateLoop o log (parseUpdates updates)

cveAll :: Options -> Text -> IO ()
cveAll o updates = do
  let u' = rights $ parseUpdates updates
  results <-
    mapM
      ( \(p, oldV, newV, url) -> do
          r <- cveReport (UpdateEnv p oldV newV url o)
          return $ p <> ": " <> oldV <> " -> " <> newV <> "\n" <> r
      )
      u'
  T.putStrLn (T.unlines results)

sourceGithubAll :: Options -> Text -> IO ()
sourceGithubAll o updates = do
  let u' = rights $ parseUpdates updates
  _ <-
    runExceptT $ do
      Git.fetchIfStale <|> liftIO (T.putStrLn "Failed to fetch.")
      Git.cleanAndResetTo "master"
  mapM_
    ( \(p, oldV, newV, url) -> do
        let updateEnv = UpdateEnv p oldV newV url o
        runExceptT $ do
          attrPath <- Nix.lookupAttrPath updateEnv
          srcUrl <- Nix.getSrcUrl attrPath
          v <- GH.latestVersion updateEnv srcUrl
          if v /= newV
            then
              liftIO $
                T.putStrLn $
                  p <> ": " <> oldV <> " -> " <> newV <> " -> " <> v
            else return ()
    )
    u'

updateLoop ::
  Options ->
  (Text -> IO ()) ->
  [Either Text (Text, Version, Version, Maybe URL)] ->
  IO ()
updateLoop _ log [] = log "nixpkgs-update finished"
updateLoop o log (Left e : moreUpdates) = do
  log e
  updateLoop o log moreUpdates
updateLoop o log (Right (pName, oldVer, newVer, url) : moreUpdates) = do
  let updateInfoLine = (pName <> " " <> oldVer <> " -> " <> newVer <> fromMaybe "" (fmap (" " <>) url))
  log updateInfoLine
  let updateEnv = UpdateEnv pName oldVer newVer url o
  updated <-
    Control.Exception.catch (updatePackageBatch log updateInfoLine updateEnv)
    (\e -> do let errMsg = tshow (e :: IOException)
              log $ "Caught exception: " <> errMsg
              return UpdatePackageFailure)
  case updated of
    UpdatePackageFailure -> do
      log $ "Failed to update: " <> updateInfoLine
      if ".0" `T.isSuffixOf` newVer
        then
          let Just newNewVersion = ".0" `T.stripSuffix` newVer
          in updateLoop
             o
             log
             (Right (pName, oldVer, newNewVersion, url) : moreUpdates)
        else updateLoop o log moreUpdates
    UpdatePackageSuccess -> do
      log $ "Success updating: " <> updateInfoLine
      updateLoop o log moreUpdates

data UpdatePackageResult = UpdatePackageSuccess | UpdatePackageFailure

-- Arguments this function should have to make it testable:
-- - the merge base commit (should be updated externally to this function)
-- - the commit for branches: master, staging, staging-next
updatePackageBatch ::
  (Text -> IO ()) ->
  Text ->
  UpdateEnv ->
  IO UpdatePackageResult
updatePackageBatch simpleLog updateInfoLine updateEnv@UpdateEnv {..} = do
  eitherFailureOrAttrpath <- runExceptT $ do
    -- Filters that don't need git
    whenBatch updateEnv do
      Skiplist.packageName packageName
      -- Update our git checkout
      Git.fetchIfStale <|> liftIO (T.putStrLn "Failed to fetch.")

    -- Filters: various cases where we shouldn't update the package
    if attrpath options
      then return packageName
      else Nix.lookupAttrPath updateEnv

  case eitherFailureOrAttrpath of
    Left failure -> do
      simpleLog failure
      return UpdatePackageFailure
    Right foundAttrPath -> do
      log <- alsoLogToAttrPath foundAttrPath simpleLog
      log updateInfoLine
      mergeBase <- if batchUpdate options
        then Git.mergeBase
        else pure "HEAD"
      withWorktree mergeBase foundAttrPath updateEnv $
        updateAttrPath log mergeBase updateEnv foundAttrPath

updateAttrPath ::
  (Text -> IO ()) ->
  Text ->
  UpdateEnv ->
  Text ->
  IO UpdatePackageResult
updateAttrPath log mergeBase updateEnv@UpdateEnv {..} attrPath = do
  let pr = doPR options

  successOrFailure <- runExceptT $ do
    hasUpdateScript <- Nix.hasUpdateScript attrPath

    whenBatch updateEnv do
      Skiplist.attrPath attrPath
      when pr do
        Git.checkAutoUpdateBranchDoesntExist packageName
        unless hasUpdateScript do
          GH.checkExistingUpdatePR updateEnv attrPath

    unless hasUpdateScript do
      Nix.assertNewerVersion updateEnv
      Version.assertCompatibleWithPathPin updateEnv attrPath
    
    let skipOutpathBase = either Just (const Nothing) $ Skiplist.skipOutpathCalc packageName

    derivationFile <- either pure (const $ Nix.getDerivationFile attrPath) $ Skiplist.overrideDerivationFile packageName
    unless hasUpdateScript do
      assertNotUpdatedOn updateEnv derivationFile "master"
      assertNotUpdatedOn updateEnv derivationFile "staging"
      assertNotUpdatedOn updateEnv derivationFile "staging-next"

    -- Calculate output paths for rebuilds and our merge base
    let calcOutpaths = calculateOutpaths options && isNothing skipOutpathBase
    mergeBaseOutpathSet <-
      if calcOutpaths
        then Outpaths.currentOutpathSet
        else return $ Outpaths.dummyOutpathSetBefore attrPath

    -- Get the original values for diffing purposes
    derivationContents <- liftIO $ T.readFile $ T.unpack derivationFile
    oldHash <- Nix.getOldHash attrPath <|> pure ""
    oldSrcUrl <- Nix.getSrcUrl attrPath <|> pure ""
    oldRev <- Nix.getAttr Nix.Raw "rev" attrPath <|> pure ""
    oldVerMay <- rightMay `fmapRT` (lift $ runExceptT $ Nix.getAttr Nix.Raw "version" attrPath)

    tryAssert
      "The derivation has no 'version' attribute, so do not know how to figure out the version while doing an updateScript update"
      (not hasUpdateScript || isJust oldVerMay)

    -- One final filter
    Skiplist.content derivationContents

    ----------------------------------------------------------------------------
    -- UPDATES
    --
    -- At this point, we've stashed the old derivation contents and
    -- validated that we actually should be rewriting something. Get
    -- to work processing the various rewrite functions!
    rewriteMsgs <- Rewrite.runAll log Rewrite.Args {derivationFile = T.unpack derivationFile, ..}
    ----------------------------------------------------------------------------

    -- Compute the diff and get updated values
    diffAfterRewrites <- Git.diff mergeBase
    tryAssert
      "The diff was empty after rewrites."
      (diffAfterRewrites /= T.empty)
    lift . log $ "Diff after rewrites:\n" <> diffAfterRewrites
    updatedDerivationContents <- liftIO $ T.readFile $ T.unpack derivationFile
    newSrcUrl <- Nix.getSrcUrl attrPath <|> pure ""
    newHash <- Nix.getHash attrPath <|> pure ""
    newRev <- Nix.getAttr Nix.Raw "rev" attrPath <|> pure ""
    newVerMay <- rightMay `fmapRT` (lift $ runExceptT $ Nix.getAttr Nix.Raw "version" attrPath)

    tryAssert
      "The derivation has no 'version' attribute, so do not know how to figure out the version while doing an updateScript update"
      (not hasUpdateScript || isJust newVerMay)

    -- Sanity checks to make sure the PR is worth opening
    unless hasUpdateScript do
      when (derivationContents == updatedDerivationContents) $ throwE "No rewrites performed on derivation."
      when (oldSrcUrl /= "" && oldSrcUrl == newSrcUrl) $ throwE "Source url did not change. "
      when (oldHash /= "" && oldHash == newHash) $ throwE "Hashes equal; no update necessary"
      when (oldRev /= "" && oldRev == newRev) $ throwE "rev equal; no update necessary"
    editedOutpathSet <- if calcOutpaths then Outpaths.currentOutpathSetUncached else return $ Outpaths.dummyOutpathSetAfter attrPath
    let opDiff = S.difference mergeBaseOutpathSet editedOutpathSet
    let numPRebuilds = Outpaths.numPackageRebuilds opDiff
    whenBatch updateEnv do
      Skiplist.python numPRebuilds derivationContents
    when (numPRebuilds == 0) (throwE "Update edits cause no rebuilds.")
    --
    -- Update updateEnv if using updateScript
    updateEnv' <-
      if hasUpdateScript
        then do
          -- Already checked that these are Just above.
          let Just oldVer = oldVerMay
          let Just newVer = newVerMay
          return $
            UpdateEnv
              packageName
              oldVer
              newVer
              (Just "passthru.updateScript")
              options
        else return updateEnv

    when hasUpdateScript do
      assertNotUpdatedOn updateEnv' derivationFile "master"
      assertNotUpdatedOn updateEnv' derivationFile "staging"
      assertNotUpdatedOn updateEnv' derivationFile "staging-next"
    whenBatch updateEnv do
      when pr do
        when hasUpdateScript do
          GH.checkExistingUpdatePR updateEnv' attrPath

    Nix.build attrPath

    --
    -- Publish the result
    lift . log $ "Successfully finished processing"
    result <- Nix.resultLink  
    let opReport =
          if isJust skipOutpathBase
          then "Outpath calculations were skipped for this package; total number of rebuilds unknown."
          else Outpaths.outpathReport opDiff
    let prBase =
          flip fromMaybe skipOutpathBase
            if Outpaths.numPackageRebuilds opDiff <= 500
            then "master"
            else "staging"
    publishPackage log updateEnv' oldSrcUrl newSrcUrl attrPath result opReport prBase rewriteMsgs

  case successOrFailure of
    Left failure -> do
      log failure
      return UpdatePackageFailure
    Right () -> return UpdatePackageSuccess

publishPackage ::
  (Text -> IO ()) ->
  UpdateEnv ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  [Text] ->
  ExceptT Text IO ()
publishPackage log updateEnv oldSrcUrl newSrcUrl attrPath result opReport prBase rewriteMsgs = do
  cachixTestInstructions <- doCachix log updateEnv result
  resultCheckReport <-
    case Skiplist.checkResult (packageName updateEnv) of
      Right () -> lift $ Check.result updateEnv (T.unpack result)
      Left msg -> pure msg
  metaDescription <- Nix.getDescription attrPath <|> return T.empty
  metaHomepage <- Nix.getHomepageET attrPath <|> return T.empty
  metaChangelog <- Nix.getChangelog attrPath <|> return T.empty
  cveRep <- liftIO $ cveReport updateEnv
  releaseUrl <- GH.releaseUrl updateEnv newSrcUrl <|> return ""
  compareUrl <- GH.compareUrl oldSrcUrl newSrcUrl <|> return ""
  maintainers <- Nix.getMaintainers attrPath
  let commitMsg = commitMessage updateEnv attrPath
  Git.commit commitMsg
  commitRev <- Git.headRev
  nixpkgsReviewMsg <-
    if prBase /= "staging" && (runNixpkgsReview . options $ updateEnv)
      then liftIO $ NixpkgsReview.runReport log commitRev
      else return ""
  -- Try to push it three times
  when
    (doPR . options $ updateEnv)
    (Git.push updateEnv <|> Git.push updateEnv <|> Git.push updateEnv)
  isBroken <- Nix.getIsBroken attrPath
  when
    (batchUpdate . options $ updateEnv)
    (lift (untilOfBorgFree log))
  let prMsg =
        prMessage
          updateEnv
          isBroken
          metaDescription
          metaHomepage
          metaChangelog
          rewriteMsgs
          releaseUrl
          compareUrl
          resultCheckReport
          commitRev
          attrPath
          maintainers
          result
          opReport
          cveRep
          cachixTestInstructions
          nixpkgsReviewMsg
  liftIO $ log prMsg
  if (doPR . options $ updateEnv)
    then do
      let ghUser = GH.untagName . githubUser . options $ updateEnv
      pullRequestUrl <- GH.pr updateEnv (prTitle updateEnv attrPath) prMsg (ghUser <> ":" <> (branchName updateEnv)) prBase
      liftIO $ log pullRequestUrl
    else liftIO $ T.putStrLn prMsg

commitMessage :: UpdateEnv -> Text -> Text
commitMessage updateEnv attrPath = prTitle updateEnv attrPath

brokenWarning :: Bool -> Text
brokenWarning False = ""
brokenWarning True =
  "- WARNING: Package has meta.broken=true; Please manually test this package update and remove the broken attribute."

prMessage ::
  UpdateEnv ->
  Bool ->
  Text ->
  Text ->
  Text ->
  [Text] ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text
prMessage updateEnv isBroken metaDescription metaHomepage metaChangelog rewriteMsgs releaseUrl compareUrl resultCheckReport commitRev attrPath maintainers resultPath opReport cveRep cachixTestInstructions nixpkgsReviewMsg =
  -- Some components of the PR description are pre-generated prior to calling
  -- because they require IO, but in general try to put as much as possible for
  -- the formatting into the pure function so that we can control the body
  -- formatting in one place and unit test it.
  let brokenMsg = brokenWarning isBroken
      metaHomepageLine =
        if metaHomepage == T.empty
          then ""
          else "meta.homepage for " <> attrPath <> " is: " <> metaHomepage
      metaDescriptionLine =
        if metaDescription == T.empty
          then ""
          else "meta.description for " <> attrPath <> " is: " <> metaDescription
      metaChangelogLine =
        if metaChangelog == T.empty
          then ""
          else "meta.changelog for " <> attrPath <> " is: " <> metaChangelog
      rewriteMsgsLine = foldl (\ms m -> ms <> T.pack "\n- " <> m) "\n###### Updates performed" rewriteMsgs
      maintainersCc =
        if not (T.null maintainers)
          then "cc " <> maintainers <> " for [testing](https://github.com/ryantm/nixpkgs-update/blob/master/doc/nixpkgs-maintainer-faq.md#r-ryantm-opened-a-pr-for-my-package-what-do-i-do)."
          else ""
      releaseUrlMessage =
        if releaseUrl == T.empty
          then ""
          else "- [Release on GitHub](" <> releaseUrl <> ")"
      compareUrlMessage =
        if compareUrl == T.empty
          then ""
          else "- [Compare changes on GitHub](" <> compareUrl <> ")"
      nixpkgsReviewSection =
        if nixpkgsReviewMsg == T.empty
          then "NixPkgs review skipped"
          else
            [interpolate|
            We have automatically built all packages that will get rebuilt due to
            this change.

            This gives evidence on whether the upgrade will break dependent packages.
            Note sometimes packages show up as _failed to build_ independent of the
            change, simply because they are already broken on the target branch.

            $nixpkgsReviewMsg
            |]
      pat link = [interpolate|This update was made based on information from $link.|]
      sourceLinkInfo = maybe "" pat $ sourceURL updateEnv
      ghUser = GH.untagName . githubUser . options $ updateEnv
      batch = batchUpdate . options $ updateEnv
      automatic = if batch then "Automatic" else "Semi-automatic"
   in [interpolate|
       $automatic update generated by [nixpkgs-update](https://github.com/ryantm/nixpkgs-update) tools. $sourceLinkInfo
       $brokenMsg

       $metaDescriptionLine

       $metaHomepageLine

       $metaChangelogLine

       $rewriteMsgsLine

       ###### To inspect upstream changes

       $releaseUrlMessage

       $compareUrlMessage

       ###### Impact

       <details>
       <summary>
       <b>Checks done</b> (click to expand)
       </summary>

       ---

       - built on NixOS
       $resultCheckReport

       ---

       </details>
       <details>
       <summary>
       <b>Rebuild report</b> (if merged into master) (click to expand)
       </summary>

       ```
       $opReport
       ```

       </details>

       <details>
       <summary>
       <b>Instructions to test this update</b> (click to expand)
       </summary>

       ---

       $cachixTestInstructions
       ```
       nix-build -A $attrPath https://github.com/$ghUser/nixpkgs/archive/$commitRev.tar.gz
       ```

       After you've downloaded or built it, look at the files and if there are any, run the binaries:
       ```
       ls -la $resultPath
       ls -la $resultPath/bin
       ```

       ---

       </details>
       <br/>

       $cveRep

       ### Pre-merge build results

       $nixpkgsReviewSection

       ---

       ###### Maintainer pings

       $maintainersCc
    |]

jqBin :: String
jqBin = fromJust ($$(envQ "JQ") :: Maybe String) <> "/bin/jq"

untilOfBorgFree :: MonadIO m => (Text -> IO ()) -> m ()
untilOfBorgFree log = do
  stats <-
    shell "curl -s https://events.nix.ci/stats.php" & readProcessInterleaved_
  waiting <-
    shell (jqBin <> " .evaluator.messages.waiting") & setStdin (byteStringInput stats)
      & readProcessInterleaved_
      & fmap (BSL.readInt >>> fmap fst >>> fromMaybe 0)
  when (waiting > 2) $ do
    liftIO $ log ("Waiting for OfBorg: https://events.nix.ci/stats.php's evaluator.messages.waiting = " <> tshow waiting)
    liftIO $ threadDelay 60000000
    untilOfBorgFree log

assertNotUpdatedOn ::
  MonadIO m => UpdateEnv -> Text -> Text -> ExceptT Text m ()
assertNotUpdatedOn updateEnv derivationFile branch = do
  derivationContents <- Git.show branch derivationFile
  Nix.assertOldVersionOn updateEnv branch derivationContents

addPatched :: Text -> Set CVE -> IO [(CVE, Bool)]
addPatched attrPath set = do
  let list = S.toList set
  forM
    list
    ( \cve -> do
        patched <- runExceptT $ Nix.hasPatchNamed attrPath (cveID cve)
        let p =
              case patched of
                Left _ -> False
                Right r -> r
        return (cve, p)
    )

cveReport :: UpdateEnv -> IO Text
cveReport updateEnv =
  if not (makeCVEReport . options $ updateEnv)
    then return ""
    else withVulnDB $ \conn -> do
      let pname1 = packageName updateEnv
      let pname2 = T.replace "-" "_" pname1
      oldCVEs1 <- getCVEs conn pname1 (oldVersion updateEnv)
      oldCVEs2 <- getCVEs conn pname2 (oldVersion updateEnv)
      let oldCVEs = S.fromList (oldCVEs1 ++ oldCVEs2)
      newCVEs1 <- getCVEs conn pname1 (newVersion updateEnv)
      newCVEs2 <- getCVEs conn pname2 (newVersion updateEnv)
      let newCVEs = S.fromList (newCVEs1 ++ newCVEs2)
      let inOldButNotNew = S.difference oldCVEs newCVEs
          inNewButNotOld = S.difference newCVEs oldCVEs
          inBoth = S.intersection oldCVEs newCVEs
          ifEmptyNone t =
            if t == T.empty
              then "none"
              else t
      inOldButNotNew' <- addPatched (packageName updateEnv) inOldButNotNew
      inNewButNotOld' <- addPatched (packageName updateEnv) inNewButNotOld
      inBoth' <- addPatched (packageName updateEnv) inBoth
      let toMkdownList = fmap (uncurry cveLI) >>> T.unlines >>> ifEmptyNone
          fixedList = toMkdownList inOldButNotNew'
          newList = toMkdownList inNewButNotOld'
          unresolvedList = toMkdownList inBoth'
      if fixedList == "none" && unresolvedList == "none" && newList == "none"
        then return ""
        else
          return
            [interpolate|
      ###### Security vulnerability report

      <details>
      <summary>
      Security report (click to expand)
      </summary>

      CVEs resolved by this update:
      $fixedList

      CVEs introduced by this update:
      $newList

      CVEs present in both versions:
      $unresolvedList


       </details>
       <br/>
      |]

doCachix :: MonadIO m => (Text -> m ()) -> UpdateEnv -> Text -> ExceptT Text m Text
doCachix log updateEnv resultPath =
  let o = options updateEnv
  in
    if batchUpdate o && "r-ryantm" == (GH.untagName $ githubUser o)
    then do
      lift $ log ("cachix " <> (T.pack . show) resultPath)
      Nix.cachix resultPath
      return
        [interpolate|
       Either **download from Cachix**:
       ```
       nix-store -r $resultPath \
         --option binary-caches 'https://cache.nixos.org/ https://nix-community.cachix.org/' \
         --option trusted-public-keys '
         nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=
         cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
         '
       ```
       (The Cachix cache is only trusted for this store-path realization.)
       For the Cachix download to work, your user must be in the `trusted-users` list or you can use `sudo` since root is effectively trusted.

       Or, **build yourself**:
       |]
    else do
      lift $ log "skipping cachix"
      return "Build yourself:"

updatePackage ::
  Options ->
  Text ->
  IO ()
updatePackage o updateInfo = do
  let (p, oldV, newV, url) = head (rights (parseUpdates updateInfo))
  let updateInfoLine = (p <> " " <> oldV <> " -> " <> newV <> fromMaybe "" (fmap (" " <>) url))
  let updateEnv = UpdateEnv p oldV newV url o
  let log = T.putStrLn
  liftIO $ notifyOptions log o
  updated <- updatePackageBatch log updateInfoLine updateEnv
  case updated of
    UpdatePackageFailure -> do
      log $ "Failed to update"
    UpdatePackageSuccess -> do
      log $ "Success updating "


withWorktree :: Text -> Text -> UpdateEnv -> IO a -> IO a
withWorktree branch attrpath updateEnv action = do
  bracket
    (do
        dir <- U.worktreeDir
        let path = dir <> "/" <> T.unpack (T.replace ".lock" "_lock" attrpath)
        Git.worktreeRemove path
        Git.delete1 (branchName updateEnv)
        Git.worktreeAdd path branch updateEnv
        pure path)
    (\ path -> do
        Git.worktreeRemove path
        Git.delete1 (branchName updateEnv))
    (\ path -> withCurrentDirectory path action)
