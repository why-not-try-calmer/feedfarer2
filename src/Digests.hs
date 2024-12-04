{-# LANGUAGE FlexibleContexts #-}

module Digests (getPrebatch, fillBatch, makeDigests) where

import Control.Concurrent.Async
import Control.Monad
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.RWS (MonadReader (..))
import Data.Foldable (foldl')
import qualified Data.HashMap.Strict as HMS
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import Database.MongoDB (find, rest, select, (=:))
import Feeds (rebuildFeed)
import Mongo (HasMongo (evalDb), MongoDoc (readDoc), saveToLog, withDb)
import Replies (render)
import Requests (alertAdmin)
import TgramOutJson
import Types (App, AppConfig (..), DbAction (..), Feed (..), FeedError, FeedLink, FromCache (..), Item (i_desc, i_pubdate, i_title), LogItem (LogFailed), Settings (settings_word_matches), SubChat (..), WordMatches (match_blacklist), match_only_search_results, match_searchset)
import Utils (partitionEither)
import Data.Functor ((<&>))

getPrebatch :: (HasMongo m, MonadIO m) => m (Either T.Text (S.Set FeedLink, [SubChat]))
getPrebatch = do
  now <- liftIO getCurrentTime
  docs <- withDb ((getExpiredChats now >>= rest) <&> take 2)
  case docs of
    Left err -> pure . Left $ T.pack . show $ err
    Right bson_chats ->
      let (chats, feedlinks) =
            foldl'
              ( \(cs, fs) doc ->
                  let c = readDoc doc :: SubChat
                   in (c : cs, fs `S.union` sub_feeds_links c)
              )
              ([], S.empty)
              bson_chats
       in liftIO $ do
            putStrLn ("getPreBatch: " ++ (show . length $ chats) ++ " chats ready.")
            print ("The following links need a rebuild: " `T.append` T.intercalate ", " (S.toList feedlinks))
            pure $ Right (feedlinks, chats)
 where
  getExpiredChats now = find (select ["sub_next_digest" =: ["$lt" =: now]] "chats")

fillBatch :: (MonadIO m) => (S.Set FeedLink, [SubChat]) -> m ([FeedError], HMS.HashMap ChatId (SubChat, [Feed]))
{- Return only feeds with more than 0 items, along with failure messages -}
fillBatch (links, chats) = do
  (failed, feeds) <- liftIO $ partitionEither <$> mapConcurrently rebuildFeed (S.toList links)
  let filter_feeds_items c = filter (\f -> f_link f `S.member` sub_feeds_links c) feeds
      fresh_feeds c = case sub_last_digest c of
        Nothing -> filter_feeds_items c
        Just last_time ->
          let step' !fs !f =
                let fresh_relevant = without_irrelevant c (fresh_only last_time f) $ f_link f
                    f' = f{f_items = fresh_relevant}
                 in if null fresh_relevant then fs else fs ++ [f']
           in foldl' step' [] $ filter_feeds_items c
      step acc !c =
        let feeds' = without_blacklisted c (fresh_feeds c)
         in if null feeds' then acc else HMS.insert (sub_chatid c) (c, fresh_feeds c) acc
      results = foldl' step HMS.empty chats
  liftIO . print $ "fillBatch: Done. " ++ show (length failed) ++ " errors."
  pure (failed, results)
 where
  fresh_only last_time f = filter (\i -> i_pubdate i > last_time) $ f_items f
  without_irrelevant c items flink =
    let search_set = match_searchset . settings_word_matches . sub_settings $ c
        only_search_results = match_only_search_results . settings_word_matches . sub_settings $ c
     in if flink `S.notMember` only_search_results
          then items
          else
            let heystack i = T.words (T.intercalate " " [i_desc i, i_title i])
             in filter (\i -> any (\needle -> T.toCaseFold needle `elem` heystack i) search_set) items
  without_blacklisted c fs =
    let bl = match_blacklist . settings_word_matches . sub_settings $ c
     in filter (\f -> f_link f `S.notMember` bl) fs

makeDigests :: (MonadIO m) => App m (Either T.Text FromCache)
makeDigests = do
  env <- ask
  prebatch <- getPrebatch
  case prebatch of
    Left err -> pure . Left $ err
    Right (links, chats) ->
      if null links
        then pure $ Right CacheOk
        else do
          (fetch_errors, batches) <- fillBatch (links, chats)
          let feeds = foldMap snd $ HMS.elems batches
          feeds_updated <- evalDb $ UpsertFeeds feeds
          feeds_archived <- evalDb $ ArchiveItems feeds
          let (archive_errors, _) = partitionEither [feeds_archived, feeds_updated]
              n_fs = length feeds
          do
            unless (null fetch_errors) $ (mapM_ $ saveToLog . LogFailed) fetch_errors
            unless (null archive_errors) $
              let error_text_db = T.intercalate "," $ map render archive_errors
                  make_msg start end = "Error while " `T.append` start `T.append` (T.pack . show $ n_fs) `T.append` " feeds: " `T.append` end
                  m = make_msg " archiving " error_text_db
               in alertAdmin (postjobs env) m
          pure . Right $ CacheDigests batches
