{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE TypeApplications #-}

module System.UnionMount
  ( -- * Mount endpoints
    mount,
    unionMount,
    unionMount',

    -- * Types
    FileAction (..),
    RefreshAction (..),
    Change,
    Logger,

    -- * For tests
    chainM,
  )
where

import Colog.Core (LogAction, Severity (..), WithSeverity (..), (<&))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Concurrent.STM
  ( TMVar,
    atomically,
    newEmptyTMVarIO,
    newTVarIO,
    putTMVar,
    readTMVar,
    readTVar,
    tryTakeTMVar,
    writeTVar,
  )
import Control.Exception.Base (finally)
import Control.Monad (forM, forM_, guard)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Strict (StateT, evalStateT, get, gets, modify, put, runStateT)
import Data.Bifunctor (second)
import Data.Functor (void, (<&>))
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty, nonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import System.Directory (canonicalizePath)
import System.FSNotify
  ( Event (..),
    EventIsDirectory (IsDirectory),
    eventIsDirectory,
    eventPath,
    watchTree,
    withManager,
  )
import System.FilePath (isRelative, makeRelative, (</>))
import System.FilePattern (FilePattern, (?==))
import System.FilePattern.Directory (getDirectoryFilesIgnore)

type Logger = LogAction IO (WithSeverity String)

-- | Simplified version of `unionMount` with exactly one layer.
mount ::
  forall model b.
  (Show b, Ord b) =>
  -- | The directory to mount.
  FilePath ->
  -- | Only include these files (exclude everything else)
  [(b, FilePattern)] ->
  -- | Ignore these patterns
  [FilePattern] ->
  -- | Initial value of model, onto which to apply updates.
  model ->
  -- | Logger
  Logger ->
  -- | How to update the model given a file action.
  --
  -- `b` is the tag associated with the `FilePattern` that selected this
  -- `FilePath`. `FileAction` is the operation performed on this path. This
  -- should return a function (in monadic context) that will update the model,
  -- to reflect the given `FileAction`.
  --
  -- If the action throws an exception, it will be logged and ignored.
  (b -> FilePath -> FileAction () -> IO (model -> model)) ->
  IO (model, (model -> IO ()) -> IO ())
mount folder pats ignore var0 logger toAction' =
  let tag0 = ()
      sources = Set.singleton (tag0, (folder, Nothing))
   in unionMount sources pats ignore var0 logger $ \ch -> do
        let fsSet = (fmap . fmap . fmap . fmap) void $ fmap Map.toList <$> Map.toList ch
        (\(tag, xs) -> uncurry (toAction' tag) `chainM` xs) `chainM` fsSet

-- Monadic version of `chain`
chainM :: (Monad m) => (x -> m (a -> a)) -> [x] -> m (a -> a)
chainM f =
  fmap chain . mapM f
 where
  -- Apply the list of actions in the given order to an initial argument.
  --
  -- chain [f1, f2, ...] a = ... (f2 (f1 x))
  chain :: [a -> a] -> a -> a
  chain = flip $ foldl' $ flip ($)

-- | Union mount a set of sources (directories) into a model.
unionMount ::
  forall source tag model.
  (Ord source, Ord tag) =>
  Set (source, (FilePath, Maybe FilePath)) ->
  [(tag, FilePattern)] ->
  [FilePattern] ->
  model ->
  Logger ->
  (Change source tag -> IO (model -> model)) ->
  IO (model, (model -> IO ()) -> IO ())
unionMount sources pats ignore model0 logger handleAction = do
  (x0, xf) <- unionMount' sources pats ignore logger
  x0' <- handleAction x0
  let initial = x0' model0
  var <- newTVarIO initial
  let sender send = do
        Cmd_Remount <- xf $ \change -> do
          change' <- handleAction change
          x <- atomically $ do
            i <- readTVar var
            let o = change' i
            writeTVar var o
            return o
          send x
        logger <& WithSeverity "Remounting..." Info
        (a, b) <- unionMount sources pats ignore model0 logger handleAction
        send a
        b send
  pure (x0' model0, sender)

-------------------------------------
-- Candidate for moving to a library
-------------------------------------

data Evt source tag
  = Evt_Change (Change source tag)
  | Evt_Unhandled
  deriving (Eq, Show)

data Cmd
  = Cmd_Remount
  deriving (Eq, Show)

-- | Like `unionMount` but without exception interrupting or re-mounting.
unionMount' ::
  forall source tag.
  (Ord source, Ord tag) =>
  Set (source, (FilePath, Maybe FilePath)) ->
  [(tag, FilePattern)] ->
  [FilePattern] ->
  Logger ->
  IO
    ( Change source tag,
      (Change source tag -> IO ()) ->
      IO Cmd
    )
unionMount' sources pats ignore logger = do
  flip evalStateT (emptyOverlayFs @source) $ do
    -- Initial traversal of sources
    changes0 :: Change source tag <-
      fmap snd . flip runStateT Map.empty $ do
        forM_ sources $ \(src, (folder, mountPoint)) -> do
          taggedFiles <- lift $ lift $ filesMatchingWithTag folder pats ignore logger
          forM_ taggedFiles $ \(tag, fs) -> do
            forM_ fs $ \fp -> do
              put =<< lift . changeInsert src tag mountPoint fp (Refresh Existing ()) =<< get
    ofs <- get
    pure
      ( changes0,
        \reportChange -> do
          -- Run fsnotify on sources
          q :: TMVar (x, Maybe FilePath, FilePath, Either (FolderAction ()) (FileAction ())) <- newEmptyTMVarIO
          fmap (either id id) $
            race (onChange q (Set.toList sources) logger) $
              let readDebounced = do
                    -- Wait for some initial action in the queue.
                    _ <- atomically $ readTMVar q
                    -- 100ms is a reasonable wait period to gather (possibly related) events.
                    threadDelay 100000
                    -- If after this period the queue is empty again, retry.
                    -- (this can happen if a file is created and deleted in this short span)
                    maybe readDebounced pure =<< atomically (tryTakeTMVar q)
                  loop :: StateT (OverlayFs source) IO Cmd
                  loop = do
                    (src, mountPoint, fp, actE) <- lift readDebounced
                    let shouldIgnore = any (?== fp) ignore
                    case actE of
                      Left _ -> do
                        let reason = "Unhandled folder event on '" <> fp <> "'"
                        if shouldIgnore
                          then do
                            lift $ logger <& WithSeverity (reason <> " on an ignored path") Warning
                            loop
                          else do
                            -- We don't know yet how to deal with folder events. Just reboot the mount.
                            lift $ logger <& WithSeverity (reason <> "; suggesting a re-mount") Warning
                            pure Cmd_Remount -- Exit, asking user to remokunt
                      Right act -> do
                        case guard (not shouldIgnore) >> getTag pats fp of
                          Nothing -> loop
                          Just tag -> do
                            changes <- fmap snd . flip runStateT Map.empty $ do
                              put =<< lift . changeInsert src tag mountPoint fp act =<< get
                            lift $ reportChange changes
                            loop
               in evalStateT loop ofs
      )

filesMatching :: FilePath -> [FilePattern] -> [FilePattern] -> Logger -> IO [FilePath]
filesMatching parent' pats ignore logger = do
  parent <- canonicalizePath parent'
  logger
    <& WithSeverity
      ( "Traversing "
          <> parent
          <> " for files matching "
          <> show pats
          <> ", ignoring "
          <> show ignore
      )
      Info
  getDirectoryFilesIgnore parent pats ignore

-- | Like `filesMatching` but with a tag associated with a pattern so as to be
-- able to tell which pattern a resulting filepath is associated with.
filesMatchingWithTag ::
  (Ord b) =>
  FilePath ->
  [(b, FilePattern)] ->
  [FilePattern] ->
  Logger ->
  IO [(b, [FilePath])]
filesMatchingWithTag parent' pats ignore logger = do
  fs <- filesMatching parent' (snd <$> pats) ignore logger
  let m = Map.fromListWith (<>) $
        flip mapMaybe fs $ \fp -> do
          tag <- getTag pats fp
          pure (tag, [fp])
  pure $ Map.toList m

getTag :: [(b, FilePattern)] -> FilePath -> Maybe b
getTag pats fp =
  let pull patterns =
        listToMaybe $
          flip mapMaybe patterns $ \(tag, pat) -> do
            guard $ pat ?== fp
            pure tag
   in if isRelative fp
        then pull pats
        else -- `fp` is an absolute path (because of use of symlinks), so let's
        -- be more lenient in matching it. Note that this does meat we might
        -- match files the user may not have originally intended. This is
        -- the trade offs with using symlinks.
          pull $ second ("**/" <>) <$> pats

data RefreshAction
  = -- | No recent change. Just notifying of file's existance
    Existing
  | -- | New file got created
    New
  | -- | The already existing file was updated.
    Update
  deriving (Eq, Show)

data FileAction a
  = -- | A new file, or updated file, is available
    Refresh RefreshAction a
  | -- | The file just got deleted.
    Delete
  deriving (Eq, Show, Functor)

-- | This is not an action on file, rather an action on a directory (which
-- may contain files, which would be outside the scope of this fsnotify event,
-- and so the user must manually deal with them.)
newtype FolderAction a = FolderAction a
  deriving (Eq, Show, Functor)

refreshAction :: FileAction a -> Maybe RefreshAction
refreshAction = \case
  Refresh act _ -> Just act
  _ -> Nothing

onChange ::
  forall x.
  (Eq x) =>
  TMVar (x, Maybe FilePath, FilePath, Either (FolderAction ()) (FileAction ())) ->
  [(x, (FilePath, Maybe FilePath))] ->
  -- | The filepath is relative to the folder being monitored, unless if its
  -- ancestor is a symlink.
  -- | Logger
  Logger ->
  IO Cmd
onChange q roots logger = do
  withManager $ \mgr -> do
    stops <- forM roots $ \(x, (rootRel, mountPoint)) -> do
      -- NOTE: It is important to use canonical path, because this will allow us to
      -- transform fsnotify event's (absolute) path into one that is relative to
      -- @parent'@ (as passed by user), which is what @f@ will expect.
      root <- canonicalizePath rootRel
      logger <& WithSeverity ("Monitoring " <> root <> " for changes") Info
      watchTree mgr root (const True) $ \event -> do
        logger <& WithSeverity (show event) Debug
        atomically $ do
          lastQ <- tryTakeTMVar q
          let fp = makeRelative root $ eventPath event
              f act = putTMVar q (x, mountPoint, fp, act)
              -- Re-add last item to the queue
              reAddQ = forM_ lastQ (putTMVar q)
          if eventIsDirectory event == IsDirectory
            then f $ Left $ FolderAction ()
            else do
              let newAction = case event of
                    Added {} -> Just $ Refresh New ()
                    Modified {} -> Just $ Refresh Update ()
                    ModifiedAttributes {} -> Just $ Refresh Update ()
                    Removed {} -> Just Delete
                    _ -> Nothing
              -- Merge with the last action when it makes sense to do so.
              case (lastQ, newAction) of
                (_, Nothing) -> reAddQ
                (Just (lastTag, _lastMountPoint, lastFp, Right lastAction), Just a)
                  | lastTag == x && lastFp == fp ->
                      case (lastAction, a) of
                        (Delete, Refresh New ()) -> f $ Right $ Refresh Update ()
                        (Refresh New (), Refresh Update ()) -> f $ Right $ Refresh New ()
                        (Refresh New (), Delete) -> pure ()
                        _ -> f $ Right a
                (_, Just a) -> reAddQ >> f (Right a)
    threadDelay maxBound
      `finally` do
        logger <& WithSeverity "Stopping fsnotify monitor." Info
        forM_ stops id
    -- Unreachable
    pure Cmd_Remount

-- TODO: Abstract in module with StateT / MonadState
newtype OverlayFs source = OverlayFs (Map FilePath (Set (source, FilePath)))

-- TODO: Replace this with a function taking `NonEmpty source`
emptyOverlayFs :: (Ord source) => OverlayFs source
emptyOverlayFs = OverlayFs mempty

overlayFsModify :: FilePath -> (Set (src, FilePath) -> Set (src, FilePath)) -> OverlayFs src -> OverlayFs src
overlayFsModify k f (OverlayFs m) =
  OverlayFs $
    Map.insert k (f $ fromMaybe Set.empty $ Map.lookup k m) m

overlayFsAdd :: (Ord src) => FilePath -> (src, FilePath) -> OverlayFs src -> OverlayFs src
overlayFsAdd fp src =
  overlayFsModify fp $ Set.insert src

overlayFsRemove :: (Ord src) => FilePath -> (src, FilePath) -> OverlayFs src -> OverlayFs src
overlayFsRemove fp src =
  overlayFsModify fp $ Set.delete src

overlayFsLookup :: FilePath -> OverlayFs source -> Maybe (NonEmpty ((source, FilePath), FilePath))
overlayFsLookup fp (OverlayFs m) = do
  sources <- nonEmpty . Set.toList =<< Map.lookup fp m
  pure $ (,fp) <$> sources

-- Files matched by each tag pattern, each represented by their corresponding
-- file (absolute path) in the individual sources. It is up to the user to union
-- them (for now).
type Change source tag = Map tag (Map FilePath (FileAction (NonEmpty (source, FilePath))))

-- | Report a change to overlay fs
changeInsert ::
  (Ord source, Ord tag, Monad m) =>
  source ->
  tag ->
  Maybe FilePath ->
  FilePath ->
  FileAction () ->
  Change source tag ->
  StateT (OverlayFs source) m (Change source tag)
changeInsert src tag mountPoint fp act ch = do
  let fpMounted = maybe fp (</> fp) mountPoint
  fmap snd . flip runStateT ch $ do
    -- First, register this change in the overlayFs
    lift $
      modify $
        (if act == Delete then overlayFsRemove else overlayFsAdd)
          fpMounted
          (src, fp)
    overlays :: FileAction (NonEmpty (source, FilePath)) <-
      lift (gets $ overlayFsLookup fpMounted) <&> \case
        Nothing -> Delete
        Just fs ->
          -- We don't track per-source action (not ideal), so use 'Existing'
          -- only if the current action is 'Deleted'. In every other scenario,
          -- re-use the current action for all overlay files.
          let combinedAction = fromMaybe Existing $ refreshAction act
           in Refresh combinedAction $ fs <&> \((src', fp'), _) -> (src', fp')
    gets (Map.lookup tag) >>= \case
      Nothing ->
        modify $ Map.insert tag $ Map.singleton fpMounted overlays
      Just files ->
        modify $ Map.insert tag $ Map.insert fpMounted overlays files
