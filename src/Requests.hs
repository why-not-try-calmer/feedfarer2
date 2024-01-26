{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Requests (mkPagination, setWebhook, fetchFeed, runSend, runSend_, answer, mkKeyboard, reply, TgReqM) where

import Control.Concurrent (Chan, writeChan)
import Control.Exception (SomeException (SomeException), throwIO, try)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.Aeson.Types
import qualified Data.ByteString.Lazy as LB
import Data.Foldable (for_)
import Data.Maybe (fromJust, isJust)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Network.HTTP.Client as HTTP
import Network.HTTP.Req
import TgramInJson (Message (message_id), TgGetMessageResponse (resp_msg_result))
import TgramOutJson (AnswerCallbackQuery, ChatId, InlineKeyboardButton (InlineKeyboardButton), InlineKeyboardMarkup (InlineKeyboardMarkup), Outbound (EditMessage, OutboundMessage, out_chat_id, out_disable_web_page_preview, out_parse_mode, out_reply_markup, out_text))
import Types
import Utils (sliceIfAboveTelegramMax)

{- Interface -}

class (MonadIO m) => TgReqM m where
  runSend :: (FromJSON a) => BotToken -> T.Text -> Outbound -> m (Either T.Text (JsonResponse a))
  runSend_ :: BotToken -> T.Text -> Outbound -> m (Either T.Text ())

instance (MonadIO m) => TgReqM (App m) where
  runSend = reqSend
  runSend_ = reqSend_

instance TgReqM IO where
  runSend = reqSend
  runSend_ = reqSend_

{- Telegram -}

setWebhook :: BotToken -> T.Text -> IO ()
setWebhook tok webhook = do
  resp <- withReqManager $ runReq defaultHttpConfig . pure request
  let code = responseStatusCode (resp :: JsonResponse Value) :: Int
      message = responseStatusMessage resp
  when (code /= 200) $ liftIO . throwIO . userError $ "Failed to set webhook, error message reads: " ++ show message
 where
  request =
    req GET (https "api.telegram.org" /: tok /: "setWebhook") NoReqBody jsonResponse $
      "url"
        =: (webhook `T.append` "/webhook/" `T.append` tok)

reqSend :: (TgReqM m, FromJSON a) => BotToken -> T.Text -> Outbound -> m (Either T.Text (JsonResponse a))
reqSend tok postMeth encodedMsg =
  liftIO (try action) >>= \case
    Left (SomeException err) ->
      let msg = "Tried to send a request, but failed for this reason: " `T.append` (T.pack . show $ err)
       in pure . Left $ msg
    Right resps -> pure . Right . head $ resps
 where
  action =
    mapM
      ( \outbound -> withReqManager $
          \manager ->
            runReq defaultHttpConfig $
              pure request manager outbound
      )
      outbounds
  outbounds = case encodedMsg of
    OutboundMessage{..} -> map (\part -> encodedMsg{out_text = part}) (sliceIfAboveTelegramMax out_text)
    EditMessage{..} -> map (\part -> encodedMsg{out_text = part}) (sliceIfAboveTelegramMax out_text)
    _ -> pure encodedMsg
  -- request :: (TgReqM m, FromJSON a) => Outbound -> m (JsonResponse a)
  request outbound =
    let reqUrl = https "api.telegram.org" /: tok /: postMeth
     in req Network.HTTP.Req.POST reqUrl (ReqBodyJson outbound) jsonResponse mempty

reqSend_ :: (TgReqM m) => BotToken -> T.Text -> Outbound -> m (Either T.Text ())
reqSend_ a b c =
  reqSend a b c >>= \case
    Left txt -> pure $ Left txt
    Right (_ :: JsonResponse Value) -> pure $ Right ()

answer :: (TgReqM m) => BotToken -> AnswerCallbackQuery -> m (Either T.Text ())
answer tok query =
  liftIO (try action) >>= \case
    Left (SomeException err) -> pure . Left . T.pack . show $ err
    Right (_ :: JsonResponse Value) -> pure $ Right ()
 where
  action = withReqManager $ runReq defaultHttpConfig . pure request
  request =
    let reqUrl = https "api.telegram.org" /: tok /: "answerCallbackQuery"
     in req Network.HTTP.Req.POST reqUrl (ReqBodyJson query) jsonResponse mempty

mkPermaLinkBtn :: T.Text -> InlineKeyboardButton
mkPermaLinkBtn url = InlineKeyboardButton "Show in full" (Just url) Nothing

mkPermLinkKeyboard :: T.Text -> InlineKeyboardMarkup
mkPermLinkKeyboard txt = InlineKeyboardMarkup [[mkPermaLinkBtn txt]]

mkKeyboard :: Int -> Int -> Maybe T.Text -> Maybe InlineKeyboardMarkup
mkKeyboard tgt tot mb_url
  | tot < 1 || tgt > tot = Nothing
  | tot == 1 =
      case mb_url of
        Nothing -> Nothing
        Just url -> Just $ InlineKeyboardMarkup [[mkPermaLinkBtn url]]
  | tgt == 1 = Just $
      InlineKeyboardMarkup $
        case mb_url of
          Nothing -> [[curr, next]]
          Just url -> [[curr, next], [mkPermaLinkBtn url]]
  | tgt == tot = Just $
      InlineKeyboardMarkup $
        case mb_url of
          Nothing -> [[prev, curr], [reset]]
          Just url -> [[prev, curr], [reset, mkPermaLinkBtn url]]
  | otherwise = Just $
      InlineKeyboardMarkup $
        case mb_url of
          Nothing -> [[prev, curr, next], [reset]]
          Just url -> [[prev, curr, next], [reset, mkPermaLinkBtn url]]
 where
  out_of = (T.pack . show $ tgt) `T.append` "/" `T.append` (T.pack . show $ tot)
  curr = InlineKeyboardButton out_of Nothing (Just "*")
  prev = InlineKeyboardButton "Prev." Nothing (Just . T.pack . show $ tgt - 1)
  next = InlineKeyboardButton "Next" Nothing (Just . T.pack . show $ tgt + 1)
  reset = InlineKeyboardButton "Page 1" Nothing (Just "1")

mkPagination :: T.Text -> Maybe T.Text -> Maybe ([T.Text], InlineKeyboardMarkup)
mkPagination orig_txt mb_url =
  if pages_nb < 2
    then Nothing
    else mkKeyboard 1 pages_nb mb_url >>= Just . (,) cuts
 where
  pages_nb = length cuts
  cuts = go [] $ T.lines orig_txt
  go acc [] = acc
  go [] (l : ls) = go [l] ls
  go (p : ps) (l : ls) =
    let pl = T.intercalate "\n" [p, l]
     in case T.compareLength pl 1290 of
          GT -> go (l : p : ps) ls
          _ -> go (pl : ps) ls

{-
mkDigestLinkButton :: T.Text -> Maybe InlineKeyboardButton
mkDigestLinkButton link
    | T.null link = Nothing
    | otherwise = Just $ InlineKeyboardButton label (Just link) Nothing
  where
    label = "Permalink"
-}

reply ::
  (TgReqM m) =>
  BotToken ->
  ChatId ->
  Reply ->
  Chan Job ->
  m ()
reply tok cid rep chan =
  let mid_from resp =
        let b = responseBody resp :: TgGetMessageResponse
         in message_id . resp_msg_result $ b
      fromReply ChatReply{..} =
        let base =
              OutboundMessage
                { out_chat_id = cid
                , out_text = non_empty reply_contents
                , out_parse_mode = if reply_markdown then Just "Markdown" else Nothing
                , out_disable_web_page_preview = pure reply_disable_webview
                , out_reply_markup = Nothing
                }
         in if reply_pagination && isJust (mkPagination reply_contents reply_permalink)
              then
                let (pages, keyboard) = fromJust $ mkPagination reply_contents reply_permalink
                 in base{out_text = non_empty $ last pages, out_reply_markup = Just keyboard}
              else base{out_reply_markup = mkPermLinkKeyboard <$> reply_permalink}
      fromReply (ServiceReply contents) = OutboundMessage cid (non_empty contents) Nothing (Just True) Nothing
      fromReply (EditReply mid contents markdown keyboard) = EditMessage cid mid contents has_markdown no_webview keyboard
       where
        no_webview = pure True
        has_markdown = if markdown then Just "Markdown" else Nothing
      report err =
        let err_msg = "Chat " `T.append` (T.pack . show $ cid) `T.append` " ran into this error: " `T.append` err
         in liftIO . writeChan chan $ JobTgAlertAdmin err_msg
      non_empty txt = if T.null txt then "No result for this command." else txt
      outbound msg@ChatReply{..} =
        let jobs mid =
              [ if reply_pin_on_send then Just $ JobPin cid mid else Nothing
              , if reply_pagination && isJust (mkPagination reply_contents reply_permalink)
                  then
                    let (pages, _) = fromJust $ mkPagination reply_contents reply_permalink
                     in Just $ JobSetPagination cid mid pages reply_permalink
                  else Nothing
              ]
         in runSend tok "sendMessage" (fromReply msg) >>= \case
              Left err ->
                let forbidden = any (`T.isInfixOf` err) ["blocked", "kicked"]
                 in if not forbidden
                      then report err
                      else do
                        liftIO $ writeChan chan . JobPurge $ cid
                        report $
                          "Bot blocked in private chat "
                            `T.append` (T.pack . show $ cid)
                            `T.append` "Chat purged."
              Right resp ->
                let mid = mid_from resp
                 in for_ (jobs mid) $ \case
                      Just j -> liftIO $ writeChan chan j
                      Nothing -> pure ()
      outbound msg@EditReply{} =
        runSend_ tok "editMessageText" (fromReply msg) >>= \case
          Left err -> report err
          Right _ -> pure ()
      outbound msg@ServiceReply{} =
        runSend_ tok "sendMessage" (fromReply msg) >>= \case
          Left err -> report err
          Right _ -> pure ()
   in if T.null $ reply_contents rep
        then
          let alert_msg = "Cancelled an empty reply that was heading to this chat: " `T.append` (T.pack . show $ cid)
           in liftIO $ writeChan chan $ JobTgAlertAdmin alert_msg
        else outbound rep

{- Feeds -}

fetchFeed :: (MonadIO m) => Url scheme -> m (Either FeedError LB.ByteString)
fetchFeed url =
  liftIO (try action :: IO (Either HttpException LbsResponse)) >>= \case
    Left (VanillaHttpException exc) -> case exc of
      HTTP.HttpExceptionRequest _ content -> pure . Left $ FeedError (renderUrl url) Nothing (T.pack . show $ content) "Invalid request."
      HTTP.InvalidUrlException url' reason -> pure . Left $ FeedError (T.pack url') Nothing (T.pack reason) "Invalid URL."
    Left (JsonHttpException msg) -> pure . Left $ FeedError (renderUrl url) Nothing (T.pack msg) "Invalid JSON."
    Right resp ->
      let code = responseStatusCode resp :: Int
          status_message = T.decodeUtf8 $ responseStatusMessage resp
          contents = responseBody resp
       in if code == 200
            then pure . Right $ contents
            else pure . Left $ FeedError (renderUrl url) (Just code) status_message "Response received but non-200 status code."
 where
  action = withReqManager $ runReq defaultHttpConfig . pure request
  request = req GET url NoReqBody lbsResponse mempty
