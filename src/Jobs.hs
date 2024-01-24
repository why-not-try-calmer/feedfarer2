{-# LANGUAGE FlexibleContexts #-}

module Jobs (procNotif, postProcJobs) where

import Backend (withChat)
import Cache (HasCache (withCache))
import Control.Concurrent (
  readChan,
  threadDelay,
  writeChan,
 )
import Control.Concurrent.Async (async, forConcurrently, forConcurrently_)
import Control.Exception (Exception, SomeException (SomeException), catch)
import Control.Monad (forever, unless, void)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Reader (MonadReader, ask)
import qualified Data.HashMap.Strict as HMS
import Data.IORef (modifyIORef', readIORef)
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Time (addUTCTime, getCurrentTime)
import Mongo (evalDb, saveToLog)
import Notifications (markNotified)
import Replies (
  mkDigestUrl,
  mkReply,
 )
import Requests (reply, runSend_)
import TgActions (isChatOfType)
import TgramInJson (ChatType (Channel))
import TgramOutJson (Outbound (DeleteMessage, PinMessage))
import Types (AppConfig (..), Batch (Digests, Follows), CacheAction (CacheRefresh, CacheSetPages), DbAction (..), DbRes (..), Digest (Digest), Feed (f_items, f_link, f_title), FromCache (CacheDigests), Job (..), Replies (..), Reply (ServiceReply), ServerConfig (..), SubChat (..), UserAction (Purge), runApp)
import Utils (renderDbError)

{- Background tasks -}

runForever_ :: (Exception e) => IO () -> (e -> IO ()) -> IO ()
{- Utility to fork a runtime thread that will run forever (i.e. absorbing all exceptions -}
runForever_ action handler = void . async . forever $ catch action handler

procNotif :: (MonadReader AppConfig m, MonadIO m) => m ()
{- Forks a thread and tasks it with checking every minute
if any chat need a digest or follow -}
procNotif =
  ask >>= \env ->
    let tok = bot_token . tg_config $ env
        interval = worker_interval env
        onError (SomeException err) = do
          let report = "notifier: exception met : " `T.append` (T.pack . show $ err)
          writeChan (postjobs env) . JobTgAlertAdmin $ report
        -- sending digests + follows
        send_tg_notif hmap now = forConcurrently (HMS.toList hmap) $
          \(cid, (c, batch)) ->
            let sets = sub_settings c
             in case batch of
                  Follows fs -> do
                    reply tok cid (mkReply (FromFollow fs sets)) (postjobs env)
                    pure (cid, map f_link fs)
                  Digests ds -> do
                    let (ftitles, flinks, fitems) =
                          foldr
                            ( \f (one, two, three) ->
                                (f_title f : one, f_link f : two, three ++ f_items f)
                            )
                            ([], [], [])
                            ds
                        ftitles' = S.toList . S.fromList $ ftitles
                        flinks' = S.toList . S.fromList $ flinks
                        digest = Digest Nothing now fitems flinks' ftitles'
                    res <- evalDb env $ WriteDigest digest
                    let mb_digest_link r = case r of
                          DbDigestId _id -> Just $ mkDigestUrl (base_url env) _id
                          _ -> Nothing
                    reply tok cid (mkReply (FromDigest ds (mb_digest_link res) sets)) (postjobs env)
                    pure (cid, map f_link ds)
        notify = do
          -- rebuilding feeds and collecting notifications
          from_cache_payload <- runApp env $ withCache CacheRefresh
          case from_cache_payload of
            Right (CacheDigests notif_hmap) -> do
              -- skipping sending on a firt run
              my_last_run <- readIORef $ last_worker_run env
              now <- getCurrentTime
              case my_last_run of
                Nothing -> do
                  -- mark chats as notified on first run
                  -- but do not send digests to avoid double-sending
                  let notified_chats = HMS.keys notif_hmap
                  markNotified env notified_chats now
                  modifyIORef' (last_worker_run env) $ \_ -> Just now
                Just _ -> do
                  -- this time sending digests, follows & search notifications
                  notified_chats <- map fst <$> send_tg_notif notif_hmap now
                  markNotified env notified_chats now
                  modifyIORef' (last_worker_run env) $ \_ -> Just now
            Left err ->
              writeChan (postjobs env) $
                JobTgAlertAdmin $
                  "notifier: \
                  \ failed to acquire notification package and got this error: "
                    `T.append` err
            -- to avoid an incomplete pattern
            _ -> pure ()
        wait_action = threadDelay interval >> notify
        handler e = onError e >> notify
     in liftIO $ runForever_ wait_action handler

postProcJobs :: (MonadReader AppConfig m, MonadIO m) => m ()
{- Forks a runtime thread and tasks it with handling as they come all post-processing jobs -}
postProcJobs =
  ask >>= \env ->
    let action = readChan (postjobs env) >>= execute env
        handler (SomeException e) = writeChan (postjobs env) . JobTgAlertAdmin $ reportOn e
     in liftIO $ runForever_ action handler
 where
  fork = void . async
  reportOn e = "postProcJobs: Exception met : " `T.append` (T.pack . show $ e)
  check_delay delay
    | delay < 10 = ("10 secs", 10000000)
    | delay > 30 = ("30 secs", 30000000)
    | otherwise = (show delay, delay)
  with_cid_txt before cid after = before `T.append` (T.pack . show $ cid) `T.append` after
  execute env (JobArchive feeds now) = fork $ do
    -- archiving items
    evalDb env (ArchiveItems feeds) >>= \case
      DbErr err -> writeChan (postjobs env) . JobTgAlertAdmin $ "Unable to archive items. Reason: " `T.append` renderDbError err
      _ -> pure ()
    -- cleaning more than 1 month old archives
    void $ evalDb env (PruneOld $ addUTCTime (-2592000) now)
  execute env (JobLog item) = fork $ saveToLog env item
  execute env (JobPin cid mid) = fork $ do
    runSend_ (bot_token . tg_config $ env) "pinChatMessage" (PinMessage cid mid) >>= \case
      Left _ ->
        writeChan (postjobs env)
          . JobTgAlertAdmin
          . with_cid_txt "Tried to pin a message in (chat_id) " cid
          $ " but failed. Either the message was removed already, or perhaps the chat is a channel and I am not allowed to delete edit messages in it?"
      _ -> pure ()
  execute env (JobPurge cid) = fork . runApp env $ withChat Purge cid
  execute env (JobRemoveMsg cid mid delay) = do
    let (msg, checked_delay) = check_delay delay
    putStrLn ("Removing message in " ++ msg)
    fork $ do
      threadDelay checked_delay
      runSend_ (bot_token . tg_config $ env) "deleteMessage" (DeleteMessage cid mid) >>= \case
        Left _ ->
          writeChan (postjobs env)
            . JobTgAlertAdmin
            . with_cid_txt "Tried to delete a message in (chat_id) " cid
            $ " but failed. Either the message was removed already, or perhaps  is a channel and I am not allowed to delete edit messages in it?"
        _ -> pure ()
  execute env (JobSetPagination cid mid pages mb_link) =
    fork $
      let to_db = evalDb env $ InsertPages cid mid pages mb_link
          to_cache = withCache $ CacheSetPages cid mid pages mb_link
       in runApp env (to_db >> to_cache) >>= \case
            Right _ -> pure ()
            _ ->
              let report = "Failed to update Redis on this key: " `T.append` T.append (T.pack . show $ cid) (T.pack . show $ mid)
               in writeChan (postjobs env) (JobTgAlertAdmin report)
  execute env (JobTgAlertAdmin contents) = fork $ do
    let msg = ServiceReply $ "Feedo is sending an alert: " `T.append` contents
    reply (bot_token . tg_config $ env) (alert_chat . tg_config $ env) msg (postjobs env)
  execute env (JobTgAlertChats chat_ids contents) =
    let msg = ServiceReply contents
        tok = bot_token . tg_config $ env
        jobs = postjobs env
     in forConcurrently_ chat_ids $ \cid -> do
          verdict <- isChatOfType tok cid Channel
          unless (verdict == Right True) $ reply tok cid msg jobs
